{
 description = "Flake File";
 inputs =  {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  nixpkgs-wolfssl = {
    type = "github";
    owner = "nixos";
    repo = "nixpkgs";
    ref = "nixos-24.11";
  }; 
 };

 outputs = {self , nixpkgs , ...}@inputs :
  let
    lib = nixpkgs.lib;
  in {
    nixosConfigurations = {
        SunnyGo = lib.nixosSystem {
            system = "x86_64-linux";
			specialArgs = { inherit inputs; };
            modules = [./configuration.nix];
        };
   };
 };
}
