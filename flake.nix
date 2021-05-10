{
  description = "A very basic flake";

  outputs = { self, nixpkgs }:
  let image = import ./image.nix { inherit nixpkgs; }; in {
    packages.x86_64-linux.dockerImages."171940471906.dkr.ecr.us-west-1.amazonaws.com/euank-com" = image;
    defaultPackage.x86_64-linux = image;
  };
}
