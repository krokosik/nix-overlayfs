# mkNativeInstallLayer and mkNativePackage on a fake vendor build made like
# a binary for other distributions: FHS interpreter, $ORIGIN RUNPATH, a
# bundled library that needs a system library (zlib) and one that does not,
# and a launcher script that finds its installation through readlink -e "$0".
{
  pkgs,
  overlayfsLib,
}:
let
  vendor = pkgs.stdenv.mkDerivation {
    name = "native-vendor-build";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.patchelf ];
    buildInputs = [ pkgs.zlib ];
    # No store paths in the binaries, as in a vendor build.
    env.NIX_DONT_SET_RPATH = "1";
    env.NIX_NO_SELF_RPATH = "1";
    buildPhase = ''
      mkdir -p lib libexec
      echo 'int plain(void) { return 42; }' > plain.c
      printf '%s\n' '#include <zlib.h>' 'const char *zver(void) { return zlibVersion(); }' > zver.c
      printf '%s\n' '#include <stdio.h>' 'int plain(void); const char *zver(void);' \
        'int main(void) { printf("plain=%d zlib=%s\n", plain(), zver()); return 0; }' > app.c
      $CC -shared -fPIC -o lib/libplain.so plain.c
      $CC -shared -fPIC -o lib/libzver.so zver.c -lz
      $CC -o libexec/app app.c -Llib -lplain -lzver -Wl,-rpath,'$ORIGIN/../lib' \
        -Wl,-rpath-link,${pkgs.lib.getLib pkgs.zlib}/lib
      # As shipped for other distributions.
      patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 libexec/app
    '';
    installPhase = ''
      mkdir -p $out
      cp -r lib libexec $out/
      cat > $out/launch <<'EOF'
      #!/bin/sh
      top=$(dirname "$(readlink -e "$0")")
      echo "top=$top"
      exec "$top/libexec/app" "$@"
      EOF
      chmod +x $out/launch
      echo data > $out/data.txt
    '';
    dontFixup = true;
  };

  installLayer = overlayfsLib.mkNativeInstallLayer {
    pname = "native-test";
    version = "1.0";
    src = vendor;
    installPhase = ''
      mkdir -p $out/opt/vendor $out/bin $out/share/applications
      cp -r $src/. $out/opt/vendor/
      chmod -R u+w $out/opt/vendor
      # A library of the same name elsewhere, not where libzver looks: zlib
      # must still come from `libraries`.
      mkdir $out/opt/vendor/unrelated
      cp $out/opt/vendor/lib/libplain.so $out/opt/vendor/unrelated/libz.so.1
      ln -s $out/opt/vendor/launch $out/bin/app
      printf '[Desktop Entry]\nExec=%s\n' "$out/bin/app" > $out/share/applications/app.desktop
    '';
  };

  package = overlayfsLib.mkNativePackage {
    pname = "native-test";
    version = "1.0";
    inherit installLayer;
    libraries = [ pkgs.zlib ];
  };
  copied = overlayfsLib.mkNativePackage {
    pname = "native-test-copied";
    version = "1.0";
    inherit installLayer;
    libraries = [ pkgs.zlib ];
    copyFiles = [ "opt/vendor/*.txt" ];
  };
  placeholder = overlayfsLib.nativeInstallRootPlaceholder;
in
pkgs.runCommand "native-package-test" { } ''
  set -euo pipefail
  layer=${installLayer}
  pkg=${package}

  # The install layer refers to nothing in the store, not even itself.
  if grep -rlF /nix/store "$layer"; then exit 1; fi
  grep -qxF 'Exec=${placeholder}/bin/app' "$layer/share/applications/app.desktop"
  [ "$(readlink "$layer/bin/app")" = ../opt/vendor/launch ]

  # Only what changes is copied.
  [ -L "$pkg/opt/vendor/data.txt" ]
  [ -L "$pkg/opt/vendor/lib/libplain.so" ]
  [ ! -L "$pkg/opt/vendor/lib/libzver.so" ]
  [ ! -L "$pkg/opt/vendor/libexec/app" ]
  [ ! -L "$pkg/opt/vendor/launch" ]
  grep -qxF "Exec=$pkg/bin/app" "$pkg/share/applications/app.desktop"

  # The launcher resolves itself into the package and runs the patched app.
  "$pkg/bin/app" > output
  cat output
  grep -qxF "top=$pkg/opt/vendor" output
  grep -qxF "plain=42 zlib=${pkgs.zlib.version}" output

  # copyFiles: copies instead of symlinks, for files found by canonical path.
  [ -f ${copied}/opt/vendor/data.txt ] && [ ! -L ${copied}/opt/vendor/data.txt ]
  grep -qx data ${copied}/opt/vendor/data.txt
  [ -L ${copied}/opt/vendor/lib/libplain.so ]
  touch $out
''
