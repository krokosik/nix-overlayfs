# The whole life of an installed application, end to end without Wine: a
# fake Windows application is launched (its URL handler is registered), the
# package is replaced by one whose Nix layer changed, and finally the host
# takes the handler over (registerHostUrlHandlers = false, as a NixOS or
# home-manager module that declares it would set), which must leave nothing
# of the application in ~/.local/share/applications.
{
  pkgs,
  overlayfsLib,
}:
if !pkgs.stdenv.hostPlatform.isx86_64 then
  pkgs.runCommand "lifecycle-vm-skipped" { } ''
    touch "$out"
  ''
else
  let
    # Both versions share the writable layer ~/.local/share/lifecycle-vm-base.
    mkBase =
      version: extraCommands:
      pkgs.runCommand "lifecycle-vm-base-${version}"
        {
          pname = "lifecycle-vm-base";
          inherit version;
        }
        ''
          mkdir -p "$out/drive_c/app" "$out/drive_c/windows/system32" "$out/drive_c/users/Public"
          printf 'app %s\n' ${version} > "$out/drive_c/app/app.exe"
          printf 'kept layer dll\n' > "$out/drive_c/windows/system32/kept.dll"
          ${extraCommands}
        '';

    v1 = mkBase "1" "";
    # The new version ships a DLL that the first one's prefix got from Wine.
    v2 = mkBase "2" ''
      printf 'new layer dll\n' > "$out/drive_c/windows/system32/new.dll"
    '';

    # What a Wine prefix update leaves in the writable layer.
    wineBuiltinCopy = pkgs.runCommand "lifecycle-vm-builtin" { } ''
      { printf 'MZ'; head -c 62 /dev/zero; printf 'Wine builtin DLL'; } > "$out"
    '';

    # The "application": with "install" it writes into the prefix as Wine and
    # the user would; it always records what it sees there.
    launchProbe = pkgs.writeShellScript "lifecycle-vm-app" ''
      root="''${1%/drive_c/app/app.exe}"
      if [ "''${2:-}" = install ]; then
        ${pkgs.coreutils}/bin/cp ${wineBuiltinCopy} "$root/drive_c/windows/system32/new.dll"
        ${pkgs.coreutils}/bin/mkdir -p "$root/drive_c/users/alice"
        printf 'user settings\n' > "$root/drive_c/users/alice/settings.txt"
      fi
      ${pkgs.coreutils}/bin/cat "$root/drive_c/app/app.exe" > "$NIX_OVERLAYFS_TEST_OUT.app"
      ${pkgs.coreutils}/bin/cat "$root/drive_c/windows/system32/new.dll" > "$NIX_OVERLAYFS_TEST_OUT.new" 2>/dev/null || true
    '';

    mkPackage =
      basePackage: registerHostUrlHandlers:
      overlayfsLib.mkOverlayfsPackage {
        inherit basePackage registerHostUrlHandlers;
        executableName = "lifecycle-app";
        executablePath = "/drive_c/app/app.exe";
        launchProgram = launchProbe;
        urlSchemes = [ "lifecycle" ];
      };

    first = mkPackage v1 true;
    updated = mkPackage v2 true;
    hostDeclared = mkPackage v2 false;
  in
  pkgs.testers.nixosTest {
    name = "lifecycle-vm";

    nodes.machine =
      { pkgs, ... }:
      {
        programs.fuse.enable = true;
        users.users.alice = {
          isNormalUser = true;
          home = "/home/alice";
        };
        boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;
        environment.systemPackages = [ pkgs.xdg-utils ];
      };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")

      home = "/home/alice"
      xdg = f"export XDG_DATA_HOME={home}/.local/share XDG_CONFIG_HOME={home}/.config XDG_CACHE_HOME={home}/.cache"
      apps = f"{home}/.local/share/applications"
      upper = f"{home}/.local/share/lifecycle-vm-base"
      state = f"{upper}/.nix-overlayfs"
      desktop = f"{apps}/lifecycle-app-nix-overlayfs-url-handler.desktop"

      def alice(command):
          return machine.succeed(f"su - alice -c '{xdg}; {command}'")

      def launch(package, name, args=""):
          machine.succeed(
              f"su - alice -c '{xdg}; NIX_OVERLAYFS_TEST_OUT=/tmp/{name} "
              f"timeout 120 {package}/bin/lifecycle-app {args}' > /tmp/{name}.log 2>&1"
              f" || {{ cat /tmp/{name}.log; false; }}"
          )
          machine.succeed("! findmnt -rn -t fuse.fuse-overlayfs")

      machine.succeed(f"install -d -m 0755 -o alice -g users {home}/.local {home}/.local/share {apps} {home}/.config {home}/.cache")

      with subtest("the first launch registers the URL handler"):
          launch("${first}", "first", "install")
          machine.succeed("grep -Fx 'app 1' /tmp/first.app")
          machine.succeed(f"grep -Fx 'Exec={state}/open-url %u' {desktop}")
          machine.succeed(f"grep -Fx 'MimeType=x-scheme-handler/lifecycle;' {desktop}")
          default = alice("xdg-mime query default x-scheme-handler/lifecycle").strip()
          assert default == "lifecycle-app-nix-overlayfs-url-handler.desktop", default
          machine.succeed(f"test -x {state}/open-url")
          machine.succeed(f"grep -Fq 'Wine builtin DLL' {upper}/drive_c/windows/system32/new.dll")
          # The start.exe shim is gone from the writable layer after the session.
          machine.succeed(f"test ! -e {upper}/drive_c/windows/system32/start.exe")

      with subtest("after the lower layer changed, nothing in the writable layer hides it"):
          launch("${updated}", "updated")
          machine.succeed("grep -Fx 'app 2' /tmp/updated.app")
          machine.succeed("grep -Fx 'new layer dll' /tmp/updated.new")
          machine.succeed("grep -F 'moved 1 file(s)' /tmp/updated.log")
          machine.succeed(f"test ! -e {upper}/drive_c/windows/system32/new.dll")
          machine.succeed(f"grep -Fq 'Wine builtin DLL' {state}/shadowed/*/drive_c/windows/system32/new.dll")
          # What belongs to the user stays.
          machine.succeed(f"grep -Fx 'user settings' {upper}/drive_c/users/alice/settings.txt")
          # No file of the writable layer has a counterpart in the new layer.
          machine.succeed(
              f"cd {upper} && find . -path ./.nix-overlayfs -prune -o ! -type d -print "
              "| while IFS= read -r file; do "
              "if [ -e \"${v2}/$file\" ] || [ -L \"${v2}/$file\" ]; then echo \"hides $file\"; exit 1; fi; "
              "done"
          )
          machine.succeed(f"test -e {desktop}")

      with subtest("when the host declares the handler, the application leaves no entries"):
          launch("${hostDeclared}", "host-declared")
          machine.succeed("grep -Fx 'app 2' /tmp/host-declared.app")
          machine.succeed(f"test ! -e {state}/open-url")
          machine.succeed(f"! ls -A {apps} | grep -F lifecycle")
          machine.succeed(f"! grep -rF lifecycle {apps}")
          machine.succeed(f"! grep -F lifecycle-app-nix-overlayfs {home}/.config/mimeapps.list")
    '';
  }
