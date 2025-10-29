{
  dockerTools,
  writeTextDir,
  pesde-registry,
}:

let
  user = "999:999";
in
dockerTools.streamLayeredImage {
  name = "pesde-registry";
  tag = pesde-registry.version;

  contents = [
    pesde-registry
    dockerTools.caCertificates
  ];

  fakeRootCommands = ''
    mkdir data
    chown ${user} data
  '';

  config = {
    Cmd = [ "/bin/pesde-registry" ];
    User = user;
  };
}
