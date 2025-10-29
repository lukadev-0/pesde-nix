{
  lib,
  runCommandLocal,
}:

package: extraBins:
runCommandLocal "${package.name}-with-bins"
  {
    version = package.version;
  }
  (
    lib.concatLines (
      [ "mkdir -p $out/bin" ]
      ++ lib.map (name: "ln -s ${lib.getExe package} $out/bin/${name}") (
        [ package.meta.mainProgram ] ++ extraBins
      )
    )
  )
