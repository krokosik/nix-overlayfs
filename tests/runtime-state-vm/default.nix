# End-to-end checks of the persistent writable layer: a real launcher, mounted
# with fuse-overlayfs as an unprivileged user, without Wine.
{
  pkgs,
  overlayfsLib,
}:
if !pkgs.stdenv.hostPlatform.isx86_64 then
  pkgs.runCommand "runtime-state-vm-skipped" { } ''
    touch "$out"
  ''
else
  let
    basePackage =
      pkgs.runCommand "runtime-state-vm-base"
        {
          pname = "runtime-state-vm-base";
          version = "1.0.0";
        }
        ''
          mkdir -p "$out/drive_c/windows/system32"
          touch "$out/probe"
          # Like a base environment: Wine's timestamp of its wine.inf.
          printf '1\n' > "$out/.update-timestamp"
          # Like DXVK in an application layer.
          printf 'native layer dll\n' > "$out/drive_c/windows/system32/d3d11.dll"
        '';

    # What a runtime prefix update leaves in the writable layer.
    wineBuiltinCopy = pkgs.runCommand "runtime-state-vm-builtin" { } ''
      { printf 'MZ'; head -c 62 /dev/zero; printf 'Wine builtin DLL'; } > "$out"
    '';

    # Records what the application sees in the mounted prefix.
    launchProbe = pkgs.writeShellScript "runtime-state-vm-launch" ''
      root="$(${pkgs.coreutils}/bin/dirname "$1")"
      ${pkgs.coreutils}/bin/cat "$root/.update-timestamp" > "$NIX_OVERLAYFS_TEST_OUT.timestamp"
      ${pkgs.coreutils}/bin/cat "$root/drive_c/windows/system32/d3d11.dll" > "$NIX_OVERLAYFS_TEST_OUT.d3d11"
    '';

    package = overlayfsLib.mkOverlayfsPackage {
      inherit basePackage;
      executableName = "runtime-state-vm";
      executablePath = "/probe";
      launchProgram = launchProbe;
      hostIntegration = false;
    };
  in
  pkgs.testers.nixosTest {
    name = "runtime-state-vm";

    nodes.machine = {
      users.users.alice = {
        isNormalUser = true;
        home = "/home/alice";
      };
      boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")

      def launch(name, env=""):
          machine.succeed(
              "su - alice -c '"
              f"HOME=/home/alice {env} NIX_OVERLAYFS_TEST_OUT=/tmp/{name} "
              "${package}/bin/runtime-state-vm' "
              f"> /tmp/{name}.log 2>&1"
          )

      upper = "/home/alice/.local/share/runtime-state-vm-base"

      with subtest("Wine prefix updates are disabled in the writable layer"):
          for run in ["first", "second"]:
              launch(run)
              machine.succeed(f"grep -Fx disable /tmp/{run}.timestamp")
          machine.succeed(f"grep -Fx disable {upper}/.update-timestamp")

      with subtest("the opt-out exposes the Nix layers' timestamp again"):
          launch("optout", "NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1")
          machine.succeed("grep -Fx 1 /tmp/optout.timestamp")
          machine.succeed(f"test ! -e {upper}/.update-timestamp")

      with subtest("Wine builtin copies stop hiding the Nix layers when they change"):
          state = f"{upper}/.nix-overlayfs"
          builtin = f"{upper}/drive_c/windows/system32/d3d11.dll"
          machine.succeed(f"su - alice -c 'cp ${wineBuiltinCopy} {builtin}'")
          # Unchanged layers: the writable layer is not scanned again.
          launch("unchanged")
          machine.succeed("grep -Fq 'Wine builtin DLL' /tmp/unchanged.d3d11")
          # Changed layers (simulated): the builtin copy is moved aside.
          machine.succeed(f"rm {state}/shadow-check-sources")
          launch("changed")
          machine.succeed("grep -Fx 'native layer dll' /tmp/changed.d3d11")
          machine.succeed(f"test ! -e {builtin}")
          machine.succeed(f"grep -Fq 'Wine builtin DLL' {state}/shadowed/*/drive_c/windows/system32/d3d11.dll")
          machine.succeed("grep -F 'moved 1 file(s)' /tmp/changed.log")
          machine.succeed(f"test -s {state}/shadow-check-sources")

      with subtest("directories of killed sessions are removed on the next launch"):
          tmpbase = "/home/alice/.cache/nix-overlayfs/tmp"
          machine.succeed(
              f"su - alice -c 'mkdir -p {tmpbase}/tmp.killedsession/overlay {tmpbase}/tmp.legacy/overlay "
              f"{tmpbase}/tmp.othernamespace/overlay && touch {tmpbase}/tmp.killedsession/session.lock "
              f"{tmpbase}/tmp.othernamespace/session.lock'"
          )
          # A session that lives on in its own user and mount namespace, with
          # its cwd outside the directory, holds its inherited lock.
          machine.succeed(
              "su - alice -c '"
              "nohup unshare --map-root-user --mount sh -c "
              f"\"mount --bind /tmp {tmpbase}/tmp.othernamespace/overlay; cd /; "
              f"exec flock {tmpbase}/tmp.othernamespace/session.lock sleep 300\" "
              "> /dev/null 2>&1 &'"
          )
          machine.wait_until_fails(
              f"su - alice -c 'flock --nonblock {tmpbase}/tmp.othernamespace/session.lock true'"
          )
          launch("sweep")
          machine.succeed(f"test ! -e {tmpbase}/tmp.killedsession")
          machine.succeed(f"test -d {tmpbase}/tmp.othernamespace")
          # Without session.lock nothing proves the session is over.
          machine.succeed(f"test -d {tmpbase}/tmp.legacy")
          machine.succeed(f"test \"$(ls {tmpbase})\" = \"$(printf 'tmp.legacy\\ntmp.othernamespace')\"")
    '';
  }
