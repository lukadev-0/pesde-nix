--!strict

local DateTime = require("@lune/datetime")
local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local BLUE = stdio.color("blue")
local RED = stdio.color("red")
local BOLD = stdio.style("bold")
local DIM = stdio.style("dim")
local RESET = stdio.style("reset")

local exit = process.exit

local PACKAGE_VARIANTS = {
	["pesde"] = { "full", "fhs" },
	["pesde-registry"] = { "static", "docker" },
}
local PACKAGE_ARTIFACTS = {
	["pesde"] = { "bin/pesde" },
	["pesde-full"] = { "bin/pesde" },
	["pesde-fhs"] = { "bin/pesde" },
	["pesde-registry"] = { "bin/pesde-registry" },
	["pesde-registry-static"] = { "bin/pesde-registry" },
}
local PACKAGES_ONLY_LINUX = {
	["pesde-fhs"] = true,
}
local PACKAGES_ONLY_LINUX_X64 = {
	["pesde-registry-static"] = true,
	["pesde-registry-docker"] = true,
}

assert(process.os == "linux" or process.os == "macos", "unsupported os")

local function eprint(msg: string)
	stdio.ewrite(msg .. "\n")
end

local VERBOSE = table.find(process.args, "--verbose") ~= nil
local FETCH_RELEASES = table.find(process.args, "--fetch-releases") ~= nil
local RELEASES_STDIN = table.find(process.args, "--releases-stdin")
local SKIP_COMMIT = table.find(process.args, "--skip-commit") ~= nil
local DO_BUILD = table.find(process.args, "--build") ~= nil
local PUSH_TO_CACHIX = table.find(process.args, "--push-to-cachix") ~= nil
local CACHIX_CACHE = if PUSH_TO_CACHIX then assert(process.env.CACHIX_CACHE, "'CACHIX_CACHE' is not set") else nil

local PROJECT_ROOT = process.cwd:gsub("/$", "")
if not fs.isFile(PROJECT_ROOT .. "/flake.nix") then
	eprint("script must be run from the project root")
	exit(1)
end
local VERSIONS_DIR = PROJECT_ROOT .. "/versions"
local VERSION_MANIFEST_PATH = VERSIONS_DIR .. "/manifest.nix"

local USER_AGENT = "pesde-nix"
local GITHUB_API = "https://api.github.com/"
local GITHUB_API_VERSION = "2022-11-28"
local GITHUB_TOKEN = process.env.GITHUB_TOKEN
if GITHUB_TOKEN ~= nil then
	eprint("using GITHUB_TOKEN")
else
	local ok, result = pcall(process.exec, "gh", { "auth", "token" })
	if ok and result.ok then
		GITHUB_TOKEN = result.stdout:gsub("\n", "")
		eprint("using token from gh")
	end
end

type VersionManifest = {
	owner: string,
	repo: string,
	latestTag: string,
	packages: { [string]: VersionManifestPackage },
}

type VersionManifestPackage = {
	[string]: string,
}

local function reverseTable<T>(t: { T })
	local n = #t
	for i = 1, math.floor(n / 2) do
		t[i], t[n - i + 1] = t[n - i + 1], t[i]
	end
end

local function versionIsPrerelease(version: string): boolean
	local bareVersion = version:split("+")[1]
	return bareVersion:find("-") ~= nil
end

local function exec(name: string, args: { string }, quiet: boolean?, options: process.CreateOptions?): string
	-- A whole bunch of code to make the output look pretty.
	-- Is it needed? No, but it's pretty.

	if VERBOSE then
		quiet = false
	end

	local argStrings = { name }
	for _, arg in args do
		table.insert(argStrings, serde.encode("json", arg, false))
	end
	local argsString = table.concat(argStrings, " ")

	if not quiet then
		eprint(`{BLUE}{BOLD}$ running {argsString}{RESET}`)
	end

	local child = process.create(name, args, options)
	local mainThread = coroutine.running()
	local yielding = false
	local needsWaking = {}

	local function readStream(stream: typeof(child.stdout))
		while true do
			local chunk = stream:read()
			while not yielding do
				needsWaking[coroutine.running()] = true
				coroutine.yield()
			end
			assert(coroutine.resume(mainThread, stream, chunk))
			if chunk == nil then
				break
			end
		end
	end

	local function printOutputLine(line: string)
		stdio.ewrite(`{DIM}  {line}{RESET}`)
	end

	child.stdin:close()

	local stdout = child.stdout
	local stderr = child.stderr

	task.defer(readStream, stdout)
	task.defer(readStream, stderr)
	local tasksRunning = 2

	local combinedChunks = {}
	local stdoutChunks = {}
	local line = ""

	while tasksRunning > 0 do
		for t in needsWaking do
			task.defer(t)
		end
		table.clear(needsWaking)

		yielding = true
		local stream, chunk = coroutine.yield()
		yielding = false

		if chunk == nil then
			tasksRunning -= 1
			continue
		end

		if stream == stdout then
			table.insert(stdoutChunks, chunk)
		end
		if quiet then
			table.insert(combinedChunks, chunk)
		end

		if not quiet then
			while chunk ~= "" do
				local lineEnd = string.find(chunk, "\n")
				if lineEnd == nil then
					line ..= chunk
					break
				else
					printOutputLine(line .. string.sub(chunk, 1, lineEnd))
					line = ""
					chunk = string.sub(chunk, lineEnd + 1)
				end
			end
		end
	end
	if not quiet and line ~= "" then
		printOutputLine(line .. "\n")
	end

	local status = child:status()
	if not status.ok then
		if quiet then
			eprint(`{RED}{BOLD}$ running {argsString}{RESET}`)
			local lines = table.concat(combinedChunks, ""):split("\n")
			for i, l in lines do
				if l == "" and i == #lines then
					break
				end
				eprint(RED .. "  " .. l .. RESET)
			end
		end
		eprint(`{RED}{BOLD}> failed with code {status.code}{RESET}`)
		exit(1)
	elseif not quiet then
		eprint(`{DIM}{BOLD}{BLUE}> finished with code {status.code}{RESET}`)
	end

	return table.concat(stdoutChunks, "")
end

local function evalNixFile(path: string)
	local result = exec("nix", { "eval", "--json", "--file", path }, true)
	return serde.decode("json", result)
end

local function formatNixFile(contents: string)
	local result = process.exec("nixfmt", {}, {
		stdio = {
			stdin = contents,
		},
	})
	if not result.ok then
		eprint(`{RED}nixfmt failed with code {result.code}{RESET}`)
		eprint(`{RED}{result.stdout}{result.stderr}{RESET}`)
		exit(1)
	end

	return result.stdout
end

local function writeNixFile(path: string, contents: string): string
	local formatted = formatNixFile(contents)
	fs.writeFile(path, formatted)
	return formatted
end

local versionManifest: VersionManifest = evalNixFile(VERSION_MANIFEST_PATH)

local function requestGithub(resource: string, options: net.FetchParams?)
	local opts = options or {} :: net.FetchParams
	local headers = table.clone(opts.headers or {})
	headers["user-agent"] = USER_AGENT
	headers["x-github-api-version"] = GITHUB_API_VERSION
	if GITHUB_TOKEN ~= nil then
		headers["authorization"] = `Bearer {GITHUB_TOKEN}`
	end

	local response = net.request({
		url = GITHUB_API .. resource,
		method = opts.method,
		body = opts.body,
		query = opts.query,
		options = opts.options,
		headers = headers,
	})

	return response
end

type GithubRelease = {
	created_at: string,
	tag_name: string,
}

local function fetchNewReleases(): { GithubRelease }
	local response = requestGithub(`repos/{versionManifest.owner}/{versionManifest.repo}/releases`)
	if not response.ok then
		error(`response failed {response.statusCode}: {response.body}`)
	end

	local releases: { GithubRelease } = serde.decode("json", response.body)
	table.sort(releases, function(a, b)
		return DateTime.fromRfc3339(a.created_at).unixTimestamp > DateTime.fromRfc3339(b.created_at).unixTimestamp
	end)

	eprint(`current tag is {versionManifest.latestTag}`)

	local newReleases = nil
	for i, release in releases do
		if release.tag_name == versionManifest.latestTag then
			newReleases = {}
			table.move(releases, 1, i - 1, 1, newReleases)
			reverseTable(newReleases)
			break
		end
	end

	if newReleases == nil then
		error("did not find current release in releases")
	end

	return newReleases
end

type FetchRevision = {
	rev: string,
	hash: string,
	path: string,
}

local function fetchRevision(rev: string): FetchRevision
	local result = exec(
		"nix-prefetch-git",
		{ "--rev", rev, `https://github.com/{versionManifest.owner}/{versionManifest.repo}.git` }
	)
	return serde.decode("json", result)
end

local function startSection(name: string)
	eprint(`\n{BOLD}-- {name} --{RESET}`)
end

local gitStatus = exec("git", { "status", "--porcelain" }, true)

local isTreeDirty = gitStatus ~= ""
if isTreeDirty then
	eprint(`{RED}git tree dirty; aborting{RESET}`)
	exit(1)
end

startSection("fetch new releases")

local newReleases: { GithubRelease } = {}
if RELEASES_STDIN then
	newReleases = serde.decode("json", stdio.readToEnd())
else
	local newReleasesResponse = fetchNewReleases()
	for _, release in newReleasesResponse do
		table.insert(newReleases, {
			created_at = release.created_at,
			tag_name = release.tag_name,
		})
	end
end

if #newReleases == 0 then
	eprint("up to date")
	exit(0)
end

eprint(`there are {#newReleases} new releases`)
for _, release in newReleases do
	eprint(` - {release.tag_name}`)
end

startSection("fetch releases")

local fetchedReleases = {}
for i, release in newReleases do
	eprint(`\n-> release {BOLD}{release.tag_name}{RESET} {DIM}({i}/{#newReleases}){RESET}`)
	fetchedReleases[release.tag_name] = fetchRevision(release.tag_name)
end

startSection("create versions")

local pesdeReleases = {}
local registryReleases = {}

for _, release in newReleases do
	local bareVersion = release.tag_name:gsub("^v", "")
	local pesdeVersion, registryVersion = unpack(string.split(bareVersion, "+"))
	registryVersion = registryVersion:gsub("^registry%.", "")

	if #pesdeReleases == 0 or pesdeVersion ~= pesdeReleases[#pesdeReleases].version then
		table.insert(pesdeReleases, {
			version = pesdeVersion,
			release = release,
		})
	end
	if #registryReleases == 0 or registryVersion ~= registryReleases[#registryReleases].version then
		table.insert(registryReleases, {
			version = registryVersion,
			release = release,
		})
	end
end

local releasesByPackage: { [string]: { { version: string, release: GithubRelease } } } = {
	["pesde"] = pesdeReleases,
	["pesde-registry"] = registryReleases,
}

local releaseChannelsByPackage: { [string]: { [string]: string } } = {}
for packageName, versions in releasesByPackage do
	local channels = versionManifest.packages[packageName]
	assert(channels ~= nil, "package not in manifest")
	channels = table.clone(channels)

	for _, versionEntry in versions do
		local version = versionEntry.version
		local isPrelease = versionIsPrerelease(version)
		if not isPrelease then
			channels.latest = version
		end
		channels.unstable = version
	end

	releaseChannelsByPackage[packageName] = channels
end

local versionSummary = {}

for packageName, versions in releasesByPackage do
	table.insert(versionSummary, packageName)

	for _, versionEntry in versions do
		local version = versionEntry.version
		local release = versionEntry.release
		local fetchedRelease = fetchedReleases[release.tag_name]

		local versionFilePath = VERSIONS_DIR .. `/{packageName}/{version}.nix`
		if not RELEASES_STDIN then
			eprint("")
			eprint(`-> {packageName} {version}`)

			local generatedDir = VERSIONS_DIR .. `/{packageName}/_tmp_{version}`
			fs.writeDir(generatedDir)
			fs.writeDir(generatedDir .. "/crate")

			exec("ln", { "-s", fetchedRelease.path, generatedDir .. "/source" })
			exec(
				"crate2nix",
				{
					"generate",
					"--cargo-toml",
					"source/Cargo.toml",
					"--output",
					"crate/Cargo.nix",
					"--crate-hashes",
					"crate/crate-hashes.json",
				},
				false,
				{
					cwd = generatedDir,
				}
			)

			local cargoNixHash =
				exec("nix-hash", { "--type", "sha256", "--sri", generatedDir .. "/crate" }):gsub("%s$", "")
			fs.removeDir(generatedDir)

			local versionFile =
				`\{ rev = "{fetchedRelease.rev}"; hash = "{fetchedRelease.hash}"; cargoNixHash = "{cargoNixHash}"; \}`
			writeNixFile(versionFilePath, versionFile)
		end

		local channels = {}
		for chan, ver in releaseChannelsByPackage[packageName] do
			if ver == version then
				table.insert(channels, chan)
			end
		end

		table.insert(
			versionSummary,
			` - {version}{if #channels ~= 0 then ` {BLUE}<- {table.concat(channels, ", ")}{RESET}` else ""} {DIM}({versionFilePath}){RESET}`
		)
	end
end

eprint("")
for _, line in versionSummary do
	eprint(line)
end

if not RELEASES_STDIN then
	startSection("update manifest")

	local manifestFile = ""
	manifestFile ..= "{"
	manifestFile ..= `owner = "{versionManifest.owner}";`
	manifestFile ..= `repo = "{versionManifest.repo}";`
	manifestFile ..= `latestTag = "{newReleases[#newReleases].tag_name}";`
	manifestFile ..= "packages = {"
	for packageName, channels in releaseChannelsByPackage do
		manifestFile ..= `{packageName} = \{`
		for channel, version in channels do
			manifestFile ..= `{channel} = "{version}";`
		end
		manifestFile ..= "};"
	end
	manifestFile ..= "};"
	manifestFile ..= "}"

	manifestFile = writeNixFile(VERSION_MANIFEST_PATH, manifestFile)

	eprint("")
	eprint(`written to {VERSION_MANIFEST_PATH}`)
	eprint(manifestFile)

	startSection("commit changes")

	if SKIP_COMMIT then
		eprint(`{DIM}skipped{RESET}`)
	else
		exec("git", { "add", "." })
		exec("git", { "commit", "-m", "chore: update versions" })
	end

	if FETCH_RELEASES then
		print(serde.encode("json", newReleases))
		exit(0)
	end
end

if not DO_BUILD then
	exit(0)
end

startSection("check flake")

exec("nix", { "flake", "check", "--print-build-logs" })

startSection("build new packages")

local buildArgs = { "build", "--json", "--print-build-logs", "--no-link" }
local buildDrvsInfo = {}

local function shouldBuildPackage(name: string)
	if process.os == "linux" then
		return process.arch == "x86_64" or not PACKAGES_ONLY_LINUX_X64[name]
	end
	return not PACKAGES_ONLY_LINUX[name]
end

for packageName, versions in releasesByPackage do
	for _, versionEntry in versions do
		local version = versionEntry.version
		local versionName = version:gsub("%.", "_")

		if shouldBuildPackage(packageName) then
			table.insert(buildArgs, `.#{packageName}_{versionName}`)
			table.insert(buildDrvsInfo, {
				name = packageName,
				version = version,
			})
		end

		for _, variant in PACKAGE_VARIANTS[packageName] do
			local packageNameWithVariant = `{packageName}-{variant}`
			if shouldBuildPackage(packageNameWithVariant) then
				table.insert(buildArgs, `.#{packageNameWithVariant}_{versionName}`)
				table.insert(buildDrvsInfo, {
					name = packageNameWithVariant,
					version = version,
				})
			end
		end
	end
end

local buildResult = serde.decode("json", exec("nix", buildArgs))

eprint("")

local paths = {}
for i, entry in buildResult do
	local drvInfo = buildDrvsInfo[i]
	if drvInfo == nil then
		error("too many entries")
	end

	local outPath = entry.outputs.out
	if outPath == nil then
		error(`derivation '{entry.drvPath}' has no 'out' output`)
	end

	eprint(`{drvInfo.name}@{drvInfo.version} -> {outPath}`)
	table.insert(paths, outPath)
end

if not PUSH_TO_CACHIX then
	exit(0)
end

startSection("push to cachix")

local pushArgs = { "push", CACHIX_CACHE }
for _, path in paths do
	table.insert(pushArgs, path)
end

exec("cachix", pushArgs)

for i, path in paths do
	local pathInfo = buildDrvsInfo[i]
	local pinName = `{pathInfo.name}-{pathInfo.version}-{process.os}-{process.arch}`

	local pinArgs = { "pin", CACHIX_CACHE, pinName, path, "--keep-revisions", "1" }
	for _, artifact in PACKAGE_ARTIFACTS[pathInfo.name] or {} do
		table.insert(pinArgs, "--artifact")
		table.insert(pinArgs, artifact)
	end

	exec("cachix", pinArgs)
end
