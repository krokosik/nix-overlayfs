{
  pkgs,
  overlayfsLib,
}:
let
  registry = "${overlayfsLib.runtimeScripts.registry}/bin/nix-overlayfs-registry";

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "registry-helpers-base" {
      pname = "registry-helpers-base";
      version = "1.0.0";
    } "mkdir -p $out";
    executableName = "registry-helpers";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
  };
in
pkgs.runCommand "registry-helpers-test" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -euo pipefail

  # Registry strings escape backslashes and quotes.
  test "$(${registry} string 'C:\dir\"x".exe')" = '"C:\\dir\\\"x\".exe"'
  test "$(${registry} string "")" = '""'

  # A new user.reg gets the header and the key.
  mkdir tmp
  printf '"Browsers"="opener"\n' | ${registry} upsert-section new/user.reg 'Software\\Wine\\WineBrowser' "$PWD/tmp"
  head -n 1 new/user.reg | grep -Fx 'WINE REGISTRY Version 2'
  grep -Ex '\[Software\\\\Wine\\\\WineBrowser\] [0-9]+' new/user.reg
  grep -Fx '"Browsers"="opener"' new/user.reg
  test -z "$(ls -A tmp)"

  # An existing key is replaced; its subkeys and keys sharing its prefix stay.
  cat > user.reg <<'EOF'
  WINE REGISTRY Version 2

  [Software\\App] 1
  "old"="1"

  [Software\\App\\Sub] 2
  "sub"="2"

  [Software\\AppOther] 3
  "other"="3"
  EOF
  sed -i 's/^  //' user.reg
  printf '"new"="1"\n' | ${registry} upsert-section user.reg 'Software\\App' "$PWD/tmp"
  ! grep -F '"old"' user.reg
  grep -Fx '"new"="1"' user.reg
  grep -Fx '"sub"="2"' user.reg
  grep -Fx '"other"="3"' user.reg
  test "$(grep -c '^\[Software\\\\App\] ' user.reg)" -eq 1

  # The writable layer's registry is merged from the layers again only when
  # they change.
  mkdir low high app state
  for layer in low high; do
    for hive in system:Machine user:User\\\\S-1-5-21-0-0-0-1000 userdef:User\\\\.Default; do
      printf 'WINE REGISTRY Version 2\n;; All keys relative to REGISTRY\\\\%s\n\n#arch=win64\n\n[Software\\\\%s] 1\n"%s"="%s"\n' \
        "''${hive#*:}" "$layer" "''${hive%%:*}" "$layer" > "$layer/''${hive%%:*}.reg"
    done
  done
  ${registry} merge "$PWD/app" state/registry-sources tmp/registry-sources "$PWD/low" "$PWD/app"
  test -f app/system.reg -a -f app/user.reg -a -f app/userdef.reg
  grep -F 'Software\\low' app/system.reg
  # The signature lists the resolved Nix layers, without the writable layer.
  printf '%s\n' "$PWD/low" | diff -u - state/registry-sources
  cmp state/registry-sources tmp/registry-sources

  # Same layers: no merge, even though a layer's file differs now.
  sed -i 's/Software\\\\low/Software\\\\changed/' low/system.reg
  ${registry} merge "$PWD/app" state/registry-sources tmp/registry-sources "$PWD/low" "$PWD/app"
  ! grep -F 'Software\\changed' app/system.reg

  # Other layers, or a missing hive: merged again.
  ${registry} merge "$PWD/app" state/registry-sources tmp/registry-sources "$PWD/low" "$PWD/high" "$PWD/app"
  grep -F 'Software\\changed' app/system.reg
  grep -F 'Software\\high' app/system.reg
  printf '%s\n' "$PWD/low" "$PWD/high" | diff -u - state/registry-sources
  sed -i 's/Software\\\\changed/Software\\\\again/' low/system.reg
  rm app/userdef.reg
  ${registry} merge "$PWD/app" state/registry-sources tmp/registry-sources "$PWD/low" "$PWD/high" "$PWD/app"
  grep -F 'Software\\again' app/system.reg

  ! ${registry} 2>/dev/null
  ! ${registry} merge "$PWD/app" state/registry-sources 2>/dev/null
  ! ${registry} upsert-section user.reg 2>/dev/null

  # Hooks keep using the shell functions, which call the program.
  script="${package}/libexec/registry-helpers-setupEnv.sh"
  grep -F 'nix-overlayfs-registry upsert-section "$appdir/user.reg" "$1" "$tempdir"' "$script"
  grep -F 'nix-overlayfs-registry merge "$appdir" "$nix_overlayfs_registry_signature"' "$script"

  touch "$out"
''
