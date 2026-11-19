# One session per writable layer, and nothing of a session outlives it, in
# both namespace modes: a real launcher whose pre-launch commands start a
# background "service" (as a consumer's licensing service would), without
# Wine.
{
  pkgs,
  overlayfsLib,
}:
if !pkgs.stdenv.hostPlatform.isx86_64 then
  pkgs.runCommand "session-isolation-vm-skipped" { } ''
    touch "$out"
  ''
else
  let
    basePackage =
      pkgs.runCommand "session-isolation-vm-base"
        {
          pname = "session-isolation-vm-base";
          version = "1.0.0";
        }
        ''
          mkdir -p "$out"
          touch "$out/probe"
        '';

    # The descriptors its caller has open (and passed on), as paths.
    listFds = pkgs.writeShellScript "session-isolation-vm-list-fds" ''
      for fd in /proc/self/fd/*; do
        ${pkgs.coreutils}/bin/readlink "$fd" || true
      done
    '';

    # Ignores SIGTERM, so only the end of the session's processes stops it.
    service = pkgs.writeShellScript "session-isolation-vm-service" ''
      ${listFds} > "$NIX_OVERLAYFS_TEST_OUT.service-fds"
      trap "" TERM
      while :; do ${pkgs.coreutils}/bin/sleep 1; done
    '';

    app = pkgs.writeShellScript "session-isolation-vm-app" ''
      printf '%s\n' "''${2:-}" >> "$NIX_OVERLAYFS_TEST_OUT.args"
      ${listFds} > "$NIX_OVERLAYFS_TEST_OUT.app-fds"
      ${pkgs.coreutils}/bin/readlink /proc/self/ns/pid > "$NIX_OVERLAYFS_TEST_OUT.pidns"
      touch "$NIX_OVERLAYFS_TEST_OUT.started"
      while [ ! -e "$NIX_OVERLAYFS_TEST_OUT.release" ]; do ${pkgs.coreutils}/bin/sleep 0.2; done
    '';

    sessions = "${overlayfsLib.runtimeScripts.sessions}/bin/nix-overlayfs-sessions";

    package = overlayfsLib.mkOverlayfsPackage {
      inherit basePackage;
      executableName = "session-isolation-vm";
      executablePath = "/probe";
      launchProgram = app;
      processTerminationTimeout = 1;
      extraPreLaunchCommands = ''
        ${pkgs.util-linux}/bin/setsid ${service} &
        while [ ! -s "$NIX_OVERLAYFS_TEST_OUT.service-fds" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done
      '';
    };
  in
  pkgs.testers.nixosTest {
    name = "session-isolation-vm";

    nodes.machine = {
      programs.fuse.enable = true;
      users.users.alice = {
        isNormalUser = true;
        home = "/home/alice";
      };
      boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("install -d -m 0755 -o alice -g users /home/alice/.cache /home/alice/.local /home/alice/.local/share")

      init_pidns = machine.succeed("readlink /proc/1/ns/pid").strip()
      state = "/home/alice/.local/share/session-isolation-vm-base/.nix-overlayfs"
      launcher = "${package}/bin/session-isolation-vm"

      def start(mode, name):
          machine.succeed(
              f"su - alice -c 'NIX_OVERLAYFS_NAMESPACE_MODE={mode} NIX_OVERLAYFS_TEST_OUT=/tmp/{name} "
              f"nohup {launcher} > /tmp/{name}.log 2>&1 &'"
          )
          machine.wait_for_file(f"/tmp/{name}.started")

      def session_processes():
          return "pgrep -u alice -f 'session-isolation-vm-(service|app)|session-isolation-vm-unwrapped'"

      for mode in ["required", "direct"]:
          with subtest(f"{mode}: the session holds the state lock; its processes do not"):
              start(mode, mode)
              for kind in ["app", "service"]:
                  machine.succeed(f"test -s /tmp/{mode}.{kind}-fds")
                  machine.succeed(f"! grep -F '/.nix-overlayfs/session.lock' /tmp/{mode}.{kind}-fds")
              machine.fail(f"su - alice -c 'flock --nonblock {state}/session.lock true'")

          with subtest(f"{mode}: a second launch stops and names the session"):
              holder = machine.succeed(f"head -n 1 {state}/session.lock").strip()
              status, _ = machine.execute(
                  f"su - alice -c 'NIX_OVERLAYFS_NAMESPACE_MODE={mode} NIX_OVERLAYFS_TEST_OUT=/tmp/{mode}-second "
                  f"{launcher} > /tmp/{mode}-second.log 2>&1'"
              )
              print(machine.succeed(f"cat /tmp/{mode}-second.log"))
              assert status == 75, status
              machine.succeed(f"grep -F 'already runs from /home/alice/.local/share/session-isolation-vm-base' /tmp/{mode}-second.log")
              machine.succeed(f"grep -E 'process {holder} \\(.*session-isolation-vm-unwrapped' /tmp/{mode}-second.log")
              machine.succeed(f"test ! -e /tmp/{mode}-second.started")

          with subtest(f"{mode}: other launchers find the running session"):
              machine.succeed(f"su - alice -c '${sessions} active {state} /probe'")
              machine.succeed(f"sed -n 2p {state}/session-state | grep -Fx ready")
              # A URL forwarded to it is taken: the session opens it (here, by
              # starting the probe application with it).
              machine.succeed(f"su - alice -c '{launcher} --nix-overlayfs-forward-url session-isolation:forwarded'")
              machine.wait_until_succeeds(f"grep -Fx session-isolation:forwarded /tmp/{mode}.args")
              # The layer got the launcher's state generation.
              machine.succeed(f"test \"$(head -n 1 {state}/state-generation)\" = ${toString overlayfsLib.stateGeneration}")
              machine.succeed(f"sed -n 2p {state}/state-generation | grep -Fx ${package}")
              pidns = machine.succeed(f"cat /tmp/{mode}.pidns").strip()
              if mode == "direct":
                  assert pidns == init_pidns, pidns
              else:
                  assert pidns != init_pidns, pidns

          with subtest(f"{mode}: nothing of the session is left when it ends"):
              machine.succeed(f"touch /tmp/{mode}.release")
              machine.wait_until_fails(session_processes(), timeout=60)
              machine.succeed(f"su - alice -c 'flock --nonblock {state}/session.lock true'")
              machine.succeed("! findmnt -rn -t fuse.fuse-overlayfs")
              machine.fail(f"su - alice -c '${sessions} active {state} /probe'")

          with subtest(f"{mode}: nothing of the session is left when its launcher is killed"):
              start(mode, f"{mode}-launcher-killed")
              broker = "pgrep -u alice -f 'nix-overlayfs-host-browser-broker .*session-isolation-vm-base'"
              machine.succeed(broker)
              # The launcher alone: the supervisor gets SIGTERM and ends the
              # session; the host browser broker, which the launcher can no
              # longer stop, ends with the supervisor.
              machine.succeed("pkill -KILL -o -u alice -f session-isolation-vm-unwrapped")
              machine.wait_until_fails(session_processes(), timeout=60)
              machine.wait_until_fails(broker, timeout=30)
              machine.wait_until_fails("pgrep -u alice -f nix-overlayfs-runtime-supervisor", timeout=30)
              machine.succeed(f"su - alice -c 'flock --nonblock {state}/session.lock true'")
              machine.succeed("! findmnt -rn -t fuse.fuse-overlayfs")

          with subtest(f"{mode}: nothing of the session is left when its supervisor is killed"):
              start(mode, f"{mode}-killed")
              # The outermost supervisor (in namespace mode there is a second
              # one, the init of the session's PID namespace).
              machine.succeed("pkill -KILL -o -u alice -f nix-overlayfs-runtime-supervisor")
              machine.wait_until_fails(session_processes(), timeout=60)
              machine.succeed(f"su - alice -c 'flock --nonblock {state}/session.lock true'")
              machine.succeed("! findmnt -rn -t fuse.fuse-overlayfs")
    '';
  }
