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
      demoVm =
        system:
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
            self.nixosModules.nsl
            ./examples/demo-vm.nix
          ];
        }).config.system.build.vm;
    in
    {
      nixosModules.nsl = ./nix/module.nix;
      nixosModules.default = self.nixosModules.nsl;

      packages = forAllSystems (pkgs: rec {
        nsl = pkgs.callPackage ./pkgs/nsl/package.nix { };
        default = nsl;
      });

      checks = forAllSystems (pkgs: {
        vm = pkgs.callPackage ./tests/vm.nix { nslModule = self.nixosModules.nsl; };
      });

      apps = forAllSystems (pkgs: {
        demo-vm = {
          type = "app";
          program = "${demoVm pkgs.stdenv.hostPlatform.system}/bin/run-nsl-demo-vm";
          meta.description = "NixOS VM with several NSL machines declared, for trying real images";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
