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
        '';

    # Records what the application sees in the mounted prefix.
    launchProbe = pkgs.writeShellScript "runtime-state-vm-launch" ''
      root="$(${pkgs.coreutils}/bin/dirname "$1")"
      ${pkgs.coreutils}/bin/cat "$root/.update-timestamp" > "$NIX_OVERLAYFS_TEST_OUT.timestamp"
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
    '';
  }
