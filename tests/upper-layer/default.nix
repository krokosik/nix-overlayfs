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

  # The start.exe shim goes into both system directories of the writable
  # layer, replacing what is there.
  mkdir -p shim/bin/x86_64 shim/bin/i686 upper/drive_c/windows/system32
  printf 'shim64\n' > shim/bin/x86_64/start.exe
  printf 'shim32\n' > shim/bin/i686/start.exe
  printf 'old\n' > upper/drive_c/windows/system32/start.exe
  ${upperLayer} install-start-shim upper "$PWD/shim"
  cmp shim/bin/x86_64/start.exe upper/drive_c/windows/system32/start.exe
  cmp shim/bin/i686/start.exe upper/drive_c/windows/syswow64/start.exe

  # Removal: from the writable layer, and from the mounted prefix only where
  # it is still the shim's file.
  mkdir -p overlay/drive_c/windows/system32 overlay/drive_c/windows/syswow64
  cp shim/bin/x86_64/start.exe overlay/drive_c/windows/system32/start.exe
  printf 'wine start\n' > overlay/drive_c/windows/syswow64/start.exe
  ${upperLayer} remove-start-shim upper "$PWD/overlay" "$PWD/shim"
  test ! -e upper/drive_c/windows/system32/start.exe
  test ! -e upper/drive_c/windows/syswow64/start.exe
  test ! -e overlay/drive_c/windows/system32/start.exe
  grep -Fx 'wine start' overlay/drive_c/windows/syswow64/start.exe
  # Nothing to remove is fine.
  ${upperLayer} remove-start-shim upper "$PWD/overlay" "$PWD/shim"

  ! ${upperLayer} 2>/dev/null
  ! ${upperLayer} skeleton 2>/dev/null
  ! ${upperLayer} install-start-shim upper 2>/dev/null

  touch "$out"
''
