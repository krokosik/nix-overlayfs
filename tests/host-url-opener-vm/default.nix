{
  pkgs,
  overlayfsLib,
}:
let
  browser = pkgs.writeShellScript "host-url-opener-test-browser" ''
    set -eu
    test "$#" -eq 1
    printf '%s\n' "$$" > /tmp/browser.pid
    touch /tmp/browser.ready
    while [ ! -e /tmp/browser.release ]; do
      sleep 0.05
    done
    printf '%s\n' "$1" > /tmp/browser.url
  '';
  xdgUtils = pkgs.writeShellScriptBin "xdg-open" ''
    set -eu
    ${browser} "$@" &
    while [ ! -e /tmp/browser.ready ]; do
      sleep 0.05
    done
    basename "$(cut -d: -f3 /proc/$$/cgroup)" > /tmp/browser.unit
  '';
  opener = overlayfsLib.hostUrlOpener.override { xdg-utils = xdgUtils; };
in
pkgs.testers.nixosTest {
  name = "host-url-opener-vm";

  nodes.machine = {
    users.users.alice = {
      isNormalUser = true;
      home = "/home/alice";
    };
  };

  testScript = ''
    import shlex

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("loginctl enable-linger alice")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_file("/run/user/1000/bus")

    def as_user(command):
        environment = "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; "
        return "su - alice -c " + shlex.quote(environment + command)

    url = "https://example.invalid/login?state=async&redirect_uri=https%3A%2F%2Fexample.invalid%2Freturn"
    machine.succeed(as_user("${opener}/bin/nix-overlayfs-open-url --direct " + shlex.quote(url)))
    machine.wait_for_file("/tmp/browser.unit")
    unit = machine.succeed("cat /tmp/browser.unit").strip()

    # The opener has exited, but its child must still be able to finish the handoff.
    machine.wait_until_succeeds(as_user(f"test $(systemctl --user show {unit} -p MainPID --value) -eq 0"))
    machine.succeed("kill -0 $(cat /tmp/browser.pid)")
    machine.succeed("touch /tmp/browser.release")
    machine.wait_for_file("/tmp/browser.url", timeout=10)
    assert machine.succeed("cat /tmp/browser.url").strip() == url
    machine.wait_until_succeeds(as_user(f"! systemctl --user is-active --quiet {unit}"))
  '';
}
