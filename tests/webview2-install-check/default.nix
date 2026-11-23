# The check the webview2 layer runs after the installer, against fake prefixes:
# only the requested version directory counts, and its msedgewebview2.exe must
# be a regular file with the PE machine of the requested architecture.
{ pkgs, ... }:
let
  modules = pkgs.nix-overlayfs.moduleScopes.makeNativeModules {
    wine = pkgs.wineWow64Packages.unstableFull;
    windowsArch = "wow64";
  };
  inherit (modules.webview2) checkInstall;
in
pkgs.runCommand "webview2-install-check" { } ''
  set -euo pipefail
  check=${pkgs.lib.getExe checkInstall}
  app() { echo "$1/drive_c/$2/Microsoft/EdgeWebView/Application/$3"; }
  # mkpe FILE MACHINE: a PE header stub, MACHINE as two little-endian bytes.
  mkpe() {
    mkdir -p "$(dirname "$1")"
    { printf 'MZ'; head -c 58 /dev/zero; printf '\x40\x00\x00\x00'
      printf 'PE\x00\x00'; printf "$2"; head -c 16 /dev/zero; } > "$1"
  }
  x64='\x64\x86' x86='\x4c\x01' arm64='\x64\xaa'
  pass() { "$check" "$@" || { echo "FAIL: expected success: $*"; exit 1; }; }
  fail() { if "$check" "$@"; then echo "FAIL: expected failure: $*"; exit 1; fi; }

  # The x64 runtime in Program Files (x86), as the real installer leaves it.
  p=$PWD/ok; mkpe "$(app $p 'Program Files (x86)' 2.0)/msedgewebview2.exe" "$x64"
  pass $p 2.0 x64
  fail $p 2.0 x86
  fail $p 1.0 x64

  # Another version directory, found first by name, does not matter.
  p=$PWD/two; mkpe "$(app $p 'Program Files (x86)' 1.0)/msedgewebview2.exe" "$x86"
  mkpe "$(app $p 'Program Files (x86)' 2.0)/msedgewebview2.exe" "$x64"
  pass $p 2.0 x64
  pass $p 1.0 x86
  fail $p 1.0 x64

  # Only another version installed.
  p=$PWD/other; mkpe "$(app $p 'Program Files (x86)' 1.0)/msedgewebview2.exe" "$x64"
  fail $p 2.0 x64

  # The wrong machine in the requested version directory.
  p=$PWD/wrong; mkpe "$(app $p 'Program Files' 2.0)/msedgewebview2.exe" "$arm64"
  fail $p 2.0 x64
  pass $p 2.0 arm64
  # ... but the right one in the other Program Files.
  mkpe "$(app $p 'Program Files (x86)' 2.0)/msedgewebview2.exe" "$x64"
  pass $p 2.0 x64

  # Not a PE file, a symlink, a directory.
  p=$PWD/text; mkdir -p "$(app $p 'Program Files (x86)' 2.0)"
  echo hello > "$(app $p 'Program Files (x86)' 2.0)/msedgewebview2.exe"
  fail $p 2.0 x64
  p=$PWD/link; mkpe $PWD/real.exe "$x64"; mkdir -p "$(app $p 'Program Files (x86)' 2.0)"
  ln -s $PWD/real.exe "$(app $p 'Program Files (x86)' 2.0)/msedgewebview2.exe"
  fail $p 2.0 x64
  p=$PWD/dir; mkdir -p "$(app $p 'Program Files (x86)' 2.0)/msedgewebview2.exe"
  fail $p 2.0 x64
  # An "MZ" file whose e_lfanew points past its end.
  p=$PWD/short; mkdir -p "$(app $p 'Program Files (x86)' 2.0)"
  { printf 'MZ'; head -c 58 /dev/zero; printf '\xff\x00\x00\x00'; } > "$(app $p 'Program Files (x86)' 2.0)/msedgewebview2.exe"
  fail $p 2.0 x64

  # An unknown architecture is a usage error.
  status=0; "$check" $PWD/ok 2.0 ia64 || status=$?
  [ "$status" = 2 ]

  touch $out
''
