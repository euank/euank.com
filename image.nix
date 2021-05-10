{ nixpkgs }:

with nixpkgs.legacyPackages.x86_64-linux;

let
  gems = bundlerEnv {
    name = "gem-env";
    inherit ruby;
    gemdir  = ./.;
  };
  staticSiteFiles = stdenv.mkDerivation {
    name = "euank-com";
    src = ./.;
    nativeBuildInputs = [ rsync ];
    buildInputs = [ gems ];
    buildPhase = ''
      make
    '';
    installPhase = ''
      mkdir -p $out/var/www
      rsync -av ./_site/ $out/var/www/
    '';
  };
  rootfs = stdenv.mkDerivation {
    name = "base-rootfs";
    src = ./rootfs;
    nativeBuildInputs = [ rsync ];
    buildPhase = "true";
    installPhase = ''
      mkdir -p $out/etc/nginx
      cp ${pkgs.nginx}/conf/* $out/etc/nginx
      rm -f $out/etc/nginx/nginx.conf
      rsync -av . $out
    '';
  };
in
dockerTools.buildImage {
  name = "171940471906.dkr.ecr.us-west-2.amazonaws.com/euank-com";
  config = {
    Cmd = [ "/bin/nginx" "-c" "/etc/nginx/nginx.conf" "-g" "daemon off;" ];
  };
  contents = [
    rootfs
    nixpkgs.legacyPackages.x86_64-linux.nginx
    staticSiteFiles
    coreutils
    bashInteractive
  ];
}
