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
      pkgs.attr
      pkgs.gawk
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail
    sys=drive_c/windows/system32

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
      chmod -R u+w upper state high low 2>/dev/null || true
      rm -rf upper state high low
      # Two read-only layers; "high" wins over "low".
      native high/$sys/d3d11.dll dxvk
      native low/$sys/d3d11.dll older
      native high/$sys/custom.dll layer
      native low/$sys/same.dll same
      native high/$sys/opq/hidden.dll layer
      # Hidden in "low" by a whiteout or an opaque directory in "high".
      native low/$sys/whited.dll same
      touch high/$sys/.wh.whited.dll
      native low/$sys/opaquelow/x.dll same
      mkdir -p high/$sys/opaquelow
      touch high/$sys/opaquelow/.wh..wh..opq
      # Hidden in "low" by a file where "low" has a directory.
      native low/$sys/notadir/y.dll same
      native high/$sys/notadir layer
      # The writable layer.
      builtin upper/$sys/d3d11.dll wine
      native upper/$sys/custom.dll user-modified
      native upper/$sys/same.dll same
      native upper/$sys/only-upper.dll mine
      builtin upper/$sys/opq/hidden.dll wine
      touch upper/$sys/opq/.wh..wh..opq
      native upper/$sys/whited.dll same
      native upper/$sys/opaquelow/x.dll same
    }

    # Default: Wine builtin copies and identical copies are moved aside,
    # other hiding files kept with a warning; files hiding nothing stay.
    setup
    ${check} upper state high low 2> log
    test ! -e upper/$sys/d3d11.dll
    test ! -e upper/$sys/same.dll
    grep -q 'user-modified' upper/$sys/custom.dll
    grep -q mine upper/$sys/only-upper.dll
    grep -q wine upper/$sys/opq/hidden.dll
    grep -q same upper/$sys/whited.dll
    grep -q same upper/$sys/opaquelow/x.dll
    backup=$(echo state/shadowed/*)
    grep -q 'Wine builtin DLL' "$backup/$sys/d3d11.dll"
    grep -q same "$backup/$sys/same.dll"
    grep -P "^moved\twine-builtin\t$sys/d3d11.dll\thigh$" state/shadowed-files
    grep -P "^moved\tidentical\t$sys/same.dll\tlow$" state/shadowed-files
    grep -P "^hides\tother\t$sys/custom.dll\thigh$" state/shadowed-files
    test "$(wc -l < state/shadowed-files)" -eq 3
    grep -F 'moved 2 file(s)' log
    grep -F 'warning: nix-overlayfs: 1 file(s)' log

    # An opaque writable directory above drive_c/windows hides every layer.
    setup
    touch upper/drive_c/.wh..wh..opq
    ${check} upper state high low
    test -e upper/$sys/d3d11.dll
    test -e upper/$sys/same.dll
    test ! -s state/shadowed-files

    # The same with an opaque xattr on a directory whose name has a newline,
    # where the filesystem allows user xattrs.
    setup
    odd="upper/$sys/odd
    dir"
    native "$odd/same.dll" same
    native "low/$sys/odd
    dir/same.dll" same
    if setfattr -n user.fuseoverlayfs.opaque -v y "$odd" 2>/dev/null; then
      ${check} upper state high low
      test -e "$odd/same.dll"
    else
      echo "user xattrs not supported here; skipping the xattr case"
    fi

    # warn: report only.
    setup
    NIX_OVERLAYFS_SHADOWED_FILES=warn ${check} upper state high low 2> log
    test -e upper/$sys/d3d11.dll
    test -e upper/$sys/same.dll
    test ! -e state/shadowed
    grep -P "^hides\twine-builtin\t$sys/d3d11.dll\thigh$" state/shadowed-files

    # prune: every hiding file is moved aside, nothing else.
    setup
    NIX_OVERLAYFS_SHADOWED_FILES=prune ${check} upper state high low 2> log
    test ! -e upper/$sys/d3d11.dll
    test ! -e upper/$sys/custom.dll
    grep -q mine upper/$sys/only-upper.dll
    grep -q same upper/$sys/whited.dll
    grep -q 'user-modified' state/shadowed/*/$sys/custom.dll

    # ignore: nothing happens.
    setup
    NIX_OVERLAYFS_SHADOWED_FILES=ignore ${check} upper state high low
    test -e upper/$sys/d3d11.dll
    test ! -e state

    # A directory that cannot be read: the scan fails and nothing is moved.
    setup
    mkdir upper/$sys/locked
    chmod 000 upper/$sys/locked
    ! ${check} upper state high low 2> log
    chmod 755 upper/$sys/locked
    grep -F 'nothing was moved' log
    test -e upper/$sys/d3d11.dll
    test -e upper/$sys/same.dll
    test ! -e state/shadowed-files

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
