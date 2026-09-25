{
  description = "Flake File";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

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

    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      hyprland,
      spicetify-nix, 
      ...
    }@inputs:
    let
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        Thousand-Sunny = lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            ./configuration.nix
            hyprland.nixosModules.default
            spicetify-nix.nixosModules.default
          ];
        };
      };
    };
}
