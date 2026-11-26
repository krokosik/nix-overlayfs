# Maintainer: Conroy Cheers <conroy@corncheese.org>
# Based on original work by Libor Štěpánek 2025
# test cases for the json2reg script
{
  pkgs,
  overlayfsLib,
  ...
}:
pkgs.stdenv.mkDerivation {
  pname = "reg2json_test";
  version = "1.0.0";
  nativeBuildInputs =
    with pkgs;
    with overlayfsLib.scripts;
    [
      findutils
      diffutils
      json2reg
    ];
  src = ./.;
  buildPhase = ''
    for file in *.json; do
      filenoext=''${file%.json}
      case "$file" in
        *.deletions.json) json2reg --deletions "$file" "$filenoext.reg.new" ;;
        *) json2reg "$file" "$filenoext.reg.new" ;;
      esac
      diff $filenoext.reg $filenoext.reg.new
    done
  '';

  installPhase = "touch $out";
}
