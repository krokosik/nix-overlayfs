{
  pkgs,
  overlayfsLib,
}:
let
  forget = "${overlayfsLib.runtimeScripts.forgetDesktopEntry}/bin/nix-overlayfs-forget-desktop-entry";
in
pkgs.runCommand "forget-desktop-entry-test" { } ''
  set -euo pipefail
  id=app-nix-overlayfs-url-handler.desktop

  cat > mimeapps.list <<EOF
  # a comment mentioning $id stays
  [Default Applications]
  x-scheme-handler/app=$id
  x-scheme-handler/both=other.desktop;$id;
  x-scheme-handler/untouched=other.desktop
  text/plain=editor.desktop

  [Added Associations]
  x-scheme-handler/app=$id;fallback.desktop;
  EOF

  cat > expected <<EOF
  # a comment mentioning $id stays
  [Default Applications]
  x-scheme-handler/both=other.desktop;
  x-scheme-handler/untouched=other.desktop
  text/plain=editor.desktop

  [Added Associations]
  x-scheme-handler/app=fallback.desktop;
  EOF

  # A list managed elsewhere (home-manager links it into the store).
  cp mimeapps.list managed-target
  ln -s managed-target managed.list

  ${forget} "$id" mimeapps.list missing.list managed.list
  diff -u expected mimeapps.list
  test -L managed.list
  grep -qF "x-scheme-handler/app=$id" managed-target

  # A file without the entry is left as it is.
  printf 'x-scheme-handler/a=b.desktop\n' > clean.list
  cp clean.list clean.before
  ${forget} "$id" clean.list
  cmp clean.before clean.list

  ! ${forget} 2>/dev/null

  touch "$out"
''
