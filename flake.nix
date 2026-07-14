{
  description = "Flake File";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    antigravity-nix.url = "github:jacopone/antigravity-nix";

    nixpkgs-wolfssl = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
      ref = "nixos-24.11";
    };

    hyprland = {
      url = "github:hyprwm/Hyprland/v0.51.0?submodules=1";
      inputs.aquamarine.follows = "aquamarine";
    };
    
    aquamarine.url = "github:hyprwm/aquamarine/v0.9.1";
  };

  outputs = { self, nixpkgs, hyprland, ... }@inputs:
    let
      lib = nixpkgs.lib;
    in {
      nixosConfigurations = {
        SunnyGo = lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [ 
            ./configuration.nix 
            hyprland.nixosModules.default 
          ];
        };
      };
    };
}
