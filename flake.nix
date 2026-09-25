{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    summercart64.url = "github:Polprzewodnikowy/SummerCart64";
    summercart64.flake = false;

    # Negronio Kart 64 (mk64 decomp fork), built via its own flake.
    # Submodules (tools/torch et al.) are required to build the ROM.
    nk64.url = "git+https://github.com/knedlsepp/nk64?submodules=1";

    llm-agents.url = "github:numtide/llm-agents.nix";
  };
  outputs = { self, nixpkgs, nixos-hardware, llm-agents, summercart64, nk64 }: {
    nixosConfigurations = {
      dranglpak64 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ({ pkgs, ... }: {
            nixpkgs.overlays = [
              (import ./overlays/sc64deployer.nix { inherit summercart64; summercart64-src = summercart64; })
              (import ./overlays/nk64-rom.nix { inherit nk64; })
            ];
          })
          nixos-hardware.nixosModules.raspberry-pi-4
          ./configuration.nix
          ./base.nix
        ];
      };
    };

    images = {
      dranglpak64 = (self.nixosConfigurations.dranglpak64.extendModules {
        modules = [ "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64-new-kernel-no-zfs-installer.nix" ];
      }).config.system.build.sdImage;
    };

    devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
      default =
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.mkShell {
          packages = with pkgs; [
            (llm-agents.packages.${system}.mistral-vibe)
          ];
        };
    });
  };
}

