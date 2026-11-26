{
  pkgs,
  overlayfsLib,
}:
let
  upperLayer = "${overlayfsLib.runtimeScripts.upperLayer}/bin/nix-overlayfs-upper-layer";
in
pkgs.runCommand "upper-layer-test" { } ''
  set -euo pipefail

  # The skeleton: the layers' drive_c directories, five levels deep, writable.
  mkdir -p \
    high/drive_c/users/Public \
    "low/drive_c/Program Files (x86)/Vendor/App/controls/deeper/deepest" \
    nodrive/other
  touch high/drive_c/users/Public/file
  ${upperLayer} skeleton upper "$PWD/high" "$PWD/low" "$PWD/nodrive" "$PWD/missing"
  test -d upper/drive_c/users/Public
  test ! -e upper/drive_c/users/Public/file
  test -d "upper/drive_c/Program Files (x86)/Vendor/App/controls/deeper"
  test ! -e "upper/drive_c/Program Files (x86)/Vendor/App/controls/deeper/deepest"
  test ! -e upper/other
  test "$(stat -c %a "upper/drive_c/Program Files (x86)/Vendor")" = 777
  test "$(stat -c %a upper/drive_c)" = 777
  # Existing directories and their contents stay.
  touch upper/drive_c/users/Public/mine
  ${upperLayer} skeleton upper "$PWD/high"
  test -e upper/drive_c/users/Public/mine

  # Copies of the start.exe shim that earlier launchers left in the writable
  # layer are removed (they would hide the integration layer's); other
  # start.exe files stay.
  mkdir -p shim/bin/x86_64 shim/bin/i686 upper/drive_c/windows/system32 upper/drive_c/windows/syswow64
  printf 'shim64\n' > shim/bin/x86_64/start.exe
  printf 'shim32\n' > shim/bin/i686/start.exe
  cp shim/bin/x86_64/start.exe upper/drive_c/windows/system32/start.exe
  printf 'wine start\n' > upper/drive_c/windows/syswow64/start.exe
  ${upperLayer} clean-start-shim upper "$PWD/shim"
  test ! -e upper/drive_c/windows/system32/start.exe
  grep -Fx 'wine start' upper/drive_c/windows/syswow64/start.exe
  # Nothing to remove is fine.
  ${upperLayer} clean-start-shim upper "$PWD/shim"
  ${upperLayer} clean-start-shim nowhere "$PWD/shim"

  ! ${upperLayer} 2>/dev/null
  ! ${upperLayer} skeleton 2>/dev/null
  ! ${upperLayer} clean-start-shim upper 2>/dev/null

  touch "$out"
''
