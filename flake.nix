{
  description = "NSL - NixOS Subsystem for Linux: foreign distributions in systemd-nspawn, declared in your NixOS configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/5dfba6236110080a54247d6460bc2ff5dda939cc";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      exampleVm =
        system: example:
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
            self.nixosModules.nsl
            example
          ];
        }).config.system.build.vm;
    in
    {
      nixosModules.nsl = ./nix/module.nix;
      nixosModules.default = self.nixosModules.nsl;

      packages = forAllSystems (pkgs: rec {
        nsl = pkgs.callPackage ./pkgs/nsl/package.nix { };
        default = nsl;

        # The module's options rendered as one HTML page, published to
        # https://kmein.github.io/nsl/ by .github/workflows/docs.yml.
        docs =
          let
            eval = pkgs.lib.evalModules {
              # Only the option declarations are wanted; the module's config
              # half defines NixOS options this bare evaluation does not have.
              modules = [
                self.nixosModules.nsl
                { _module.check = false; }
              ];
              specialArgs = { inherit pkgs; };
            };
            doc = pkgs.nixosOptionsDoc {
              options = builtins.removeAttrs eval.options [ "_module" ];
              transformOptions =
                o:
                o
                // {
                  declarations = map (_: {
                    name = "nix/module.nix";
                    url = "https://github.com/kmein/nsl/blob/master/nix/module.nix";
                  }) o.declarations;
                };
            };
          in
          pkgs.runCommand "nsl-docs" { nativeBuildInputs = [ pkgs.cmark ]; } ''
            mkdir -p $out
            {
              cat ${./docs/head.html}
              cmark --unsafe ${doc.optionsCommonMark}
              cat ${./docs/foot.html}
            } > $out/index.html
          '';
      });

      checks = forAllSystems (pkgs: {
        vm = pkgs.callPackage ./tests/vm.nix { nslModule = self.nixosModules.nsl; };
        docs = self.packages.${pkgs.stdenv.hostPlatform.system}.docs;
      });

      apps = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          demo-vm = {
            type = "app";
            program = "${exampleVm system ./examples/demo-vm.nix}/bin/run-nsl-demo-vm";
            meta.description = "A VM with five distributions declared, to try NSL by hand";
          };
          smoke-vm = {
            type = "app";
            program = "${exampleVm system ./examples/smoke-vm.nix}/bin/run-nsl-smoke-vm";
            meta.description = "Install and check five real distributions, print a report, power off";
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
