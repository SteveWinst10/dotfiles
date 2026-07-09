{
 description = "Flake File";
 inputs =  {
    nixpkgs.url = "nixpkgs/nixos-unstable";
	antigravity-nix.url = "github:jacopone/antigravity-nix";
  nixpkgs-wolfssl = {
    type = "github";
    owner = "nixos";
    repo = "nixpkgs";
    ref = "nixos-24.11";
	};


 hyprland = {
      url = "github:hyprwm/Hyprland/v0.51.0?submodules=1";
      # Correct way to override nested inputs within a flake input set
      inputs.aquamarine.follows = "aquamarine";
    };
    
    # Define aquamarine as a top-level input so we can pin it properly
    aquamarine.url = "github:hyprwm/aquamarine/v0.9.1";
    };
 outputs = {self , nixpkgs , hyprland, ...}@inputs :
  let
    lib = nixpkgs.lib;
  in {
   nixpkgs.hostPlatform = {
     system = "x86_64-linux";
     gcc.arch = "znver5"; # This belongs strictly in configuration.nix, NOT flake.nix
   };
    nixosConfigurations = {
        SunnyGo = lib.nixosSystem {
            system = "x86_64-linux";
			specialArgs = { inherit inputs; };
            modules = [./configuration.nix hyprland.nixosModules.default];
        };
   };
 };
}
