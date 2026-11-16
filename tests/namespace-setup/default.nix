{
  pkgs,
  overlayfsLib,
}:
let
  namespace = "${overlayfsLib.runtimeScripts.namespace}/bin/nix-overlayfs-namespace";

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "namespace-setup-base" {
      pname = "namespace-setup-base";
      version = "1.0.0";
    } "mkdir -p $out";
    executableName = "namespace-setup";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
    namespaceMode = "required";
  };
in
pkgs.runCommand "namespace-setup-test" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -euo pipefail

  # Explicit modes are kept, without a probe.
  test "$(${namespace} mode required probe.log)" = required
  test "$(${namespace} mode direct probe.log)" = direct
  test ! -e probe.log
  # auto probes; which way depends on the build sandbox.
  mode="$(${namespace} mode auto probe.log)"
  case "$mode" in
    required) test ! -s probe.log ;;
    direct) test -s probe.log ;;
    *) exit 1 ;;
  esac
  status=0
  ${namespace} mode bogus probe.log 2> invalid.log || status=$?
  test "$status" -eq 2
  grep -Fx 'error: NIX_OVERLAYFS_NAMESPACE_MODE must be one of: auto, required, direct' invalid.log

  # /etc/ld.so.preload is left alone in direct mode, when asked to, or when
  # there is none.
  mkdir session
  printf 'libhost.so\n' > preload
  export NIX_OVERLAYFS_LD_SO_PRELOAD_PATH="$PWD/preload"
  NIX_OVERLAYFS_DIRECT_MODE=1 ${namespace} hide-ld-so-preload session
  NIX_OVERLAYFS_PRESERVE_LD_SO_PRELOAD=1 ${namespace} hide-ld-so-preload session
  NIX_OVERLAYFS_LD_SO_PRELOAD_PATH="$PWD/none" ${namespace} hide-ld-so-preload session
  test ! -e session/empty-ld.so.preload
  # Otherwise an empty file is bound over it; where the sandbox does not allow
  # the mount, that is a warning and not an error.
  ${namespace} hide-ld-so-preload session 2> hide.log
  test -e session/empty-ld.so.preload
  test ! -s preload || grep -Fx 'warning: failed to hide /etc/ld.so.preload in Wine mount namespace' hide.log
  unset NIX_OVERLAYFS_LD_SO_PRELOAD_PATH

  # Nothing mounted: unmounting succeeds quietly.
  mkdir overlay
  ${namespace} unmount overlay 2> unmount.log
  ${namespace} unmount missing 2>> unmount.log
  test ! -s unmount.log

  ! ${namespace} 2>/dev/null
  ! ${namespace} mode auto 2>/dev/null
  ! ${namespace} unmount 2>/dev/null

  # The launcher resolves its mode, hides the file and unmounts with it.
  grep -F 'nix-overlayfs-namespace mode "''${NIX_OVERLAYFS_NAMESPACE_MODE:-required}"' \
    "${package}/bin/namespace-setup-unwrapped"
  grep -F 'nix-overlayfs-namespace unmount "$tempdir/overlay"' "${package}/bin/namespace-setup-unwrapped"
  grep -F 'nix-overlayfs-namespace hide-ld-so-preload "$tempdir"' "${package}/libexec/namespace-setup-setupEnv.sh"

  touch "$out"
''
