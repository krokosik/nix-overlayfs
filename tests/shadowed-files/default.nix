{
  pkgs,
  overlayfsLib,
}:
let
  check = "${overlayfsLib.runtimeScripts.checkShadowed}/bin/nix-overlayfs-check-shadowed";

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "shadowed-files-base" {
      pname = "shadowed-files-base";
      version = "1.0.0";
    } "mkdir -p $out";
    executableName = "shadowed-files";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
  };
in
pkgs.runCommand "shadowed-files-test"
  {
    nativeBuildInputs = [
      pkgs.gawk
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail

    # A PE file as winebuild writes it: the signature sits at offset 0x40.
    builtin() {
      mkdir -p "$(dirname "$1")"
      { printf 'MZ'; head -c 62 /dev/zero; printf 'Wine builtin DLL'; printf '%s' "$2"; } > "$1"
    }
    native() {
      mkdir -p "$(dirname "$1")"
      { printf 'MZ'; head -c 62 /dev/zero; printf 'native %s' "$2"; } > "$1"
    }

    setup() {
      rm -rf upper state high low
      sys=drive_c/windows/system32
      # Two read-only layers; "high" wins over "low".
      native high/$sys/d3d11.dll dxvk
      native low/$sys/d3d11.dll older
      native high/$sys/custom.dll layer
      native low/$sys/same.dll same
      native high/$sys/opq/hidden.dll layer
      # The writable layer.
      builtin upper/$sys/d3d11.dll wine
      native upper/$sys/custom.dll user-modified
      native upper/$sys/same.dll same
      native upper/$sys/only-upper.dll mine
      builtin upper/$sys/opq/hidden.dll wine
      touch upper/$sys/opq/.wh..wh..opq
    }

    # Default: Wine builtin copies are moved aside, identical copies removed,
    # other hiding files kept with a warning.
    setup
    ${check} upper state high low 2> log
    test ! -e upper/$sys/d3d11.dll
    test ! -e upper/$sys/same.dll
    grep -q 'user-modified' upper/$sys/custom.dll
    grep -q mine upper/$sys/only-upper.dll
    grep -q wine upper/$sys/opq/hidden.dll
    backup=$(echo state/shadowed/*)
    grep -q 'Wine builtin DLL' "$backup/$sys/d3d11.dll"
    grep -P "^moved\twine-builtin\t$sys/d3d11.dll\thigh$" state/shadowed-files
    grep -P "^hides\tother\t$sys/custom.dll\thigh$" state/shadowed-files
    test "$(wc -l < state/shadowed-files)" -eq 2
    grep -F 'moved 1 file(s)' log
    grep -F 'removed 1 file(s)' log
    grep -F 'warning: nix-overlayfs: 1 file(s)' log

    # warn: report only.
    setup
    NIX_OVERLAYFS_SHADOWED_FILES=warn ${check} upper state high low 2> log
    test -e upper/$sys/d3d11.dll
    test -e upper/$sys/same.dll
    test ! -e state/shadowed
    grep -P "^hides\twine-builtin\t$sys/d3d11.dll\thigh$" state/shadowed-files

    # prune: every hiding file is moved aside.
    setup
    NIX_OVERLAYFS_SHADOWED_FILES=prune ${check} upper state high low 2> log
    test ! -e upper/$sys/d3d11.dll
    test ! -e upper/$sys/custom.dll
    grep -q mine upper/$sys/only-upper.dll
    grep -q 'user-modified' state/shadowed/*/$sys/custom.dll

    # ignore: nothing happens.
    setup
    NIX_OVERLAYFS_SHADOWED_FILES=ignore ${check} upper state high low
    test -e upper/$sys/d3d11.dll
    test ! -e state

    # A writable layer without drive_c/windows is fine.
    mkdir empty
    ${check} empty state high low

    ! NIX_OVERLAYFS_SHADOWED_FILES=bogus ${check} upper state high 2>/dev/null
    ! ${check} upper 2>/dev/null

    # The launcher checks only when the layers changed, and before mounting.
    script="${package}/libexec/shadowed-files-setupEnv.sh"
    grep -F 'cmp -s "$nix_overlayfs_shadow_signature" "$nix_overlayfs_registry_signature_next"' "$script"
    awk '
      /nix-overlayfs-check-shadowed/ && !check { check = NR }
      /\/bin\/fuse-overlayfs( |$)/ && !mount { mount = NR }
      END {
        if (!check || !mount || check >= mount) {
          print "the hidden-file check must run before fuse-overlayfs mounts" > "/dev/stderr"
          exit 1
        }
      }
    ' "$script"

    touch "$out"
  ''
