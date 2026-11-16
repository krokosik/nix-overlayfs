{
  pkgs,
  overlayfsLib,
}:
let
  handlers = "${overlayfsLib.runtimeScripts.urlHandlers}/bin/nix-overlayfs-url-handlers";

  mkPackage =
    registerHostUrlHandlers:
    overlayfsLib.mkOverlayfsPackage {
      basePackage = pkgs.runCommand "url-handlers-base" {
        pname = "url-handlers-base";
        version = "1.0.0";
      } "mkdir -p $out";
      executableName = "url-handlers";
      executablePath = "/drive_c/windows/system32/notepad.exe";
      launchProgram = "${pkgs.coreutils}/bin/false";
      urlSchemes = [ "alpha" ];
      inherit registerHostUrlHandlers;
    };
in
pkgs.runCommand "url-handlers-test"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.xdg-utils
    ];
  }
  ''
    set -euo pipefail
    export HOME="$PWD/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CONFIG_HOME="$HOME/.config"
    apps="$XDG_DATA_HOME/applications"
    state="$XDG_DATA_HOME/app/.nix-overlayfs"
    mkdir -p "$apps" "$XDG_CONFIG_HOME" "$state"

    # Scheme names: valid ones once each, in lower case, without the web's own.
    printf '%s\n' Alpha alpha http HTTPS ftp mailto 1bad 'with space' web+app.x-y \
      | ${handlers} filter-schemes > schemes
    printf '%s\n' alpha web+app.x-y | diff -u - schemes

    # An entry this state directory wrote under an older executable name, one
    # another package wrote, a default that names the old entry and one that
    # names another application (which the package's entry replaces).
    printf '%s\n' '[Desktop Entry]' "Exec=$state/open-url %u" > "$apps/old-nix-overlayfs-url-handler.desktop"
    printf '%s\n' '[Desktop Entry]' "Exec=$HOME/other/open-url %u" > "$apps/other-nix-overlayfs-url-handler.desktop"
    printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Someone' 'Exec=true %u' \
      'MimeType=x-scheme-handler/web+app.x-y;' > "$apps/someone-else.desktop"
    printf '%s\n' '[Default Applications]' \
      'x-scheme-handler/old=old-nix-overlayfs-url-handler.desktop' \
      'x-scheme-handler/web+app.x-y=someone-else.desktop' \
      > "$XDG_CONFIG_HOME/mimeapps.list"

    printf '#!/bin/sh\necho "launched $*"\n' > launcher
    chmod +x launcher
    ${handlers} register "$state" schemes app "$PWD/launcher" app-base 2> register.log

    test ! -e "$apps/old-nix-overlayfs-url-handler.desktop"
    test -e "$apps/other-nix-overlayfs-url-handler.desktop"
    ! grep -F old-nix-overlayfs "$XDG_CONFIG_HOME/mimeapps.list"
    printf '%s\n' \
      '[Desktop Entry]' \
      'Type=Application' \
      'Name=app URL Handler' \
      'NoDisplay=true' \
      "Exec=$state/open-url %u" \
      'MimeType=x-scheme-handler/alpha;x-scheme-handler/web+app.x-y;' \
      | diff -u - "$apps/app-nix-overlayfs-url-handler.desktop"
    test "$(xdg-mime query default x-scheme-handler/alpha)" = app-nix-overlayfs-url-handler.desktop
    test "$(xdg-mime query default x-scheme-handler/web+app.x-y)" = app-nix-overlayfs-url-handler.desktop
    ! grep -F error register.log

    # The handler runs the package's launcher, or the installed one once the
    # package is gone.
    test "$("$state/open-url" alpha://x)" = 'launched --nix-overlayfs-open-url alpha://x'
    mkdir bin
    printf '#!/bin/sh\necho "installed $*"\n' > bin/app
    chmod +x bin/app launcher
    rm launcher
    test "$(PATH="$PWD/bin:$PATH" "$state/open-url" alpha://y)" = 'installed --nix-overlayfs-open-url alpha://y'

    # Registering again keeps the entry.
    ${handlers} register "$state" schemes app "$PWD/launcher" app-base
    test -e "$apps/app-nix-overlayfs-url-handler.desktop"

    # Without schemes nothing is written, but old entries still go.
    : > none
    ${handlers} register "$state" none renamed "$PWD/launcher" app-base
    test ! -e "$apps/app-nix-overlayfs-url-handler.desktop"
    test ! -e "$apps/renamed-nix-overlayfs-url-handler.desktop"
    ! grep -F app-nix-overlayfs "$XDG_CONFIG_HOME/mimeapps.list"
    grep -F alpha "$XDG_CONFIG_HOME/mimeapps.list" && exit 1

    # When the host declares the handler, everything this state wrote goes.
    ${handlers} register "$state" schemes app "$PWD/launcher" app-base
    ${handlers} unregister "$state"
    test ! -e "$apps/app-nix-overlayfs-url-handler.desktop"
    test ! -e "$state/open-url"
    test -e "$apps/other-nix-overlayfs-url-handler.desktop"
    ! grep -F app-nix-overlayfs "$XDG_CONFIG_HOME/mimeapps.list"

    ! ${handlers} 2>/dev/null
    ! ${handlers} register "$state" schemes 2>/dev/null
    ! ${handlers} unregister 2>/dev/null

    # The launcher registers at every launch, or unregisters when the host
    # declares the handler.
    grep -F 'nix-overlayfs-url-handlers register "$state_dir" "$nix_overlayfs_url_schemes_file"' \
      "${mkPackage true}/libexec/url-handlers-setupEnv.sh"
    grep -F 'nix-overlayfs-url-handlers unregister "$state_dir"' \
      "${mkPackage false}/libexec/url-handlers-setupEnv.sh"
    ! grep -F 'nix-overlayfs-url-handlers register' "${mkPackage false}/libexec/url-handlers-setupEnv.sh"

    touch "$out"
  ''
