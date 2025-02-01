{
  description = "A demo of sqlite-web and multiple postgres services";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    systems.url = "github:nix-systems/default";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    services-flake.url = "github:juspay/services-flake";
  };
  outputs =
    { self, ... }@inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [
        inputs.process-compose-flake.flakeModule
        inputs.treefmt-nix.flakeModule
      ];
      perSystem =
        {
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
            { ... }:
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
          packages.hello =
            let
              mixExs = builtins.readFile ./hello/mix.exs;
              pname = builtins.head (builtins.match ".*app:[[:space:]]*:([a-zA-Z0-9_]+).*" mixExs);
              version = builtins.head (
                builtins.match ".*version:[[:space:]]*\"([0-9]+\\.[0-9]+\\.[0-9]+)\".*" mixExs
              );
              src = ./hello;
            in
            pkgs.beamPackages.mixRelease {
              inherit pname version src;
              MIX_ENV = "prod";
              mixFodDeps = pkgs.beamPackages.fetchMixDeps {
                inherit version src pname;
                sha256 = "sha256-bEaxsw3OdRoiGoi1Vv2k0QxNT/PdGDGsOf5UDho3L1o=";
                buildInputs = [ ];
                propagatedBuildInputs = [ ];
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
          treefmt = {
            projectRootFile = ".git/config";

            programs = {
              deadnix.enable = true;
              nixfmt.enable = true;
              nixfmt.package = pkgs.nixfmt-rfc-style;
              shellcheck.enable = true;
              shfmt.enable = true;
              mix-format.enable = true;
            };
          };
        };
      # NixOS module for the Phoenix application
      flake.nixosModules.default =
        {
          lib,
          config,
          pkgs,
          ...
        }:
        with lib;
        let
          cfg = config.services.hello;
        in
        {
          options.services.hello = {
            enable = mkEnableOption "Phoenix application service";
            port = mkOption {
              type = types.port;
              default = 4000;
              description = "Port to run the Phoenix application on";
            };
            user = mkOption {
              type = types.str;
              default = "hello";
              description = "User to run the Phoenix application as";
            };
            group = mkOption {
              type = types.str;
              default = "hello";
              description = "Group to run the Phoenix application as";
            };
          };

          config = mkIf cfg.enable {
            systemd.services.hello = {
              description = "Phoenix Application Service";
              wantedBy = [ "multi-user.target" ];
              after = [
                "network.target"
                "postgresql.service"
              ];
              environment = {
                PORT = toString cfg.port;
                RELEASE_NAME = "hello";
                RELEASE_COOKIE = "$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 20)";
              };
              serviceConfig = {
                Type = "simple";
                User = cfg.user;
                Group = cfg.group;
                ExecStart = "${self.packages.${pkgs.system}.hello}/bin/hello start";
                Restart = "on-failure";
              };
            };

            users.users.${cfg.user} = {
              isSystemUser = true;
              group = cfg.group;
            };
            users.groups.${cfg.group} = { };

            # PostgreSQL configuration
            services.postgresql = {
              enable = true;
              ensureDatabases = [ "hello_dev" ];
            };
          };
        };
      flake.nixosModules.vmTest =
        { pkgs, ... }:
        {
          imports = [
            self.nixosModules.default
          ];

          # Enable both services
          services.hello.enable = true;
          services.hello.port = 4000;

          # VM test-specific configuration
          virtualisation = {
            cores = 2;
            memorySize = 2048;
            graphics = false;
          };

          # Ensure we have testing tools available
          environment.systemPackages = with pkgs; [
            curl
            postgresql
            jq
          ];

          networking = {
            firewall.allowedTCPPorts = [
              4000
              5432
            ];
          };
        };
      # Add a convenient way to run the test VM interactively
      flake.packages.aarch64-linux.test-vm =
        let
          pkgs = inputs.nixpkgs.legacyPackages.aarch64-linux;
          system = pkgs.nixos {
            imports = [
              self.nixosModules.vmTest
            ];
          };
        in
        system.config.system.build.vm;

      flake.nixosConfigurations.vm = inputs.nixpkgs.lib.nixosSystem {
        system = "aarch64-linux"; # or your target system architecture
        modules = [
          "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          self.nixosModules.default
          (
            { ... }:
            {
              system.stateVersion = "25.05";
              # VM-specific settings
              virtualisation = {
                cores = 2;
                memorySize = 2048; # MB
                graphics = false; # Headless mode
              };

              # Enable the Phoenix service
              services.hello.enable = true;
              services.hello.port = 4000;

              # Network configuration
              networking = {
                useDHCP = true;
                firewall.allowedTCPPorts = [ 4000 ]; # Allow access to Phoenix port
              };

              # Enable SSH for easy access
              services.openssh = {
                enable = true;
                settings.PermitRootLogin = "yes";
                settings.PasswordAuthentication = true;
              };

              users.users.root.initialPassword = "nixos";
            }
          )
        ];
      };

      flake.checks.aarch64-linux.vm-test =
        let
          pkgs = inputs.nixpkgs.legacyPackages.aarch64-linux;
        in
        pkgs.testers.nixosTest {
          name = "hello-phoenix-test";

          nodes.machine =
            { ... }:
            {
              imports = [ self.nixosModules.vmTest ];
            };

          testScript = # python
            ''
              import json
              import time

              start_all()

              # Wait for the system to be ready
              machine.wait_for_unit("multi-user.target")

              # Check PostgreSQL
              machine.wait_for_unit("postgresql")
              machine.succeed("sudo -u postgres psql -c '\\l' | grep hello_dev")

              # Wait for Phoenix service
              machine.wait_for_unit("hello")

              # Give the Phoenix application time to fully start
              time.sleep(10)

              # Test Phoenix endpoint
              machine.succeed("curl --fail -v http://localhost:4000/")

              # Additional health checks
              with machine.nested("Checking service statuses"):
                  machine.succeed("systemctl is-active postgresql")
                  machine.succeed("systemctl is-active hello")

              # Check PostgreSQL connection from Phoenix
              machine.succeed("sudo -u hello psql -d hello_dev -h localhost -c '\\dt'")

              # Check logs for any errors
              machine.fail("journalctl -u hello | grep -i error")
              machine.fail("journalctl -u postgresql | grep -i error")
            '';
        };
    };
}
