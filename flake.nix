{
  description = "A demo of sqlite-web and multiple postgres services";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    services-flake.url = "github:juspay/services-flake";
  };
  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [
        inputs.process-compose-flake.flakeModule
      ];
      perSystem =
        {
          self',
          pkgs,
          config,
          lib,
          ...
        }:
        {
          # `process-compose.foo` will add a flake package output called "foo".
          # Therefore, this will add a default package that you can build using
          # `nix build` and run using `nix run`.
          process-compose."default" =
            { config, ... }:
            {
              imports = [
                inputs.services-flake.processComposeModules.default
              ];

              services.postgres."pg1" = {
                enable = true;
                initialScript.before = ''
                  CREATE ROLE postgres WITH LOGIN PASSWORD 'postgres' SUPERUSER;
                '';
                initialDatabases = [ { name = "hello_dev"; } ];
              };

              settings.processes.phoenix-init = {
                command = pkgs.writeShellApplication {
                  name = "phoenix-init";
                  runtimeInputs = [ pkgs.elixir ];
                  text = ''
                    mix local.hex --force
                    mix local.rebar --force
                    mix archive.install --force hex phx_new

                    if [ ! -d "hello" ]; then
                      echo y | mix phx.new --install hello
                    fi

                    pushd hello
                    mix deps.get
                    mix ecto.create
                    popd
                  '';
                };
              };
              settings.processes.phoenix = {
                command = pkgs.writeShellApplication {
                  name = "phoenix";
                  runtimeInputs = [ pkgs.elixir ];
                  text = ''cd hello && mix phx.server --open '';
                };
                depends_on."pg1".condition = "process_healthy";
                depends_on."phoenix-init".condition = "process_completed_successfully";
              };
            };

          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.process-compose."default".services.outputs.devShell
            ];
            packages = [
              pkgs.git
              pkgs.elixir
            ] ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ];
          };
        };
    };
}
