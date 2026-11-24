# A native (Linux) application made runnable on NixOS from its install layer
# (mkNativeInstallLayer). The package mirrors the layer with symlinks and
# copies only the files it changes (see mirror.py): ELF files patched for
# `libraries`, scripts, files naming the install root, and `copyFiles`
# (reflinks where the file system can). Changing a library rebuilds this
# derivation only, never the install layer.
#
#   overlayfsLib.mkNativePackage {
#     pname = "foo";
#     version = "1.0";
#     installLayer = fooInstall;
#     libraries = [ libGL libx11 ];
#     # Where the application's launcher points LD_LIBRARY_PATH.
#     libraryDirs = [ "opt/foo/lib" ];
#     postBuild = ''
#       wrapProgram $out/bin/foo --set FOO_HOME $out/opt/foo
#     '';
#   }
#
# Libraries the layer ships keep being found the way the application finds
# them elsewhere ($ORIGIN, `libraryDirs`); only other dependencies are looked
# up in `libraries`, then in the rest of the layer, and added to RUNPATH. A
# dependency found nowhere fails the build unless it matches
# `ignoreMissingDeps`.
{
  lib,
  stdenvNoCC,
  stdenv,
  python3,
  patchelf,
  makeWrapper,
  overlayfsLib,
}:
{
  pname,
  version,
  installLayer,
  # Searched, in order, for dependencies the layer does not provide.
  libraries ? [ ],
  # Added to the RUNPATH of every executable (for libraries loaded with dlopen).
  runtimeDependencies ? [ ],
  # Directories of the layer (relative to its root) where the application
  # finds its own libraries without RPATH, usually its LD_LIBRARY_PATH.
  libraryDirs ? [ ],
  # Missing dependencies (glob patterns) that do not fail the build.
  ignoreMissingDeps ? [ ],
  # Files (glob patterns relative to the layer root) to copy instead of
  # symlink: those whose resolved path a program uses to find the rest of
  # its installation, which must be the package, not the unpatched layer.
  copyFiles ? [ ],
  nativeBuildInputs ? [ ],
  # Runs after patching; makeWrapper is available.
  postBuild ? "",
  passthru ? { },
  meta ? { },
}:
let
  python = python3.withPackages (ps: [ ps.pyelftools ]);
  libDirs = map (dep: "${lib.getLib dep}/lib") libraries;
  runtimeDirs = map (dep: "${lib.getLib dep}/lib") runtimeDependencies;
in
stdenvNoCC.mkDerivation {
  inherit pname version meta;
  dontUnpack = true;
  dontConfigure = true;
  dontPatchELF = true;
  dontStrip = true;
  # Both hooks start a process for every symlink, which takes minutes for a
  # large layer. They are not needed here: every link that the mirror makes
  # points at a file that it found in the layer, and none points into $out.
  dontCheckForBrokenSymlinks = true;
  dontRewriteSymlinks = true;
  preferLocalBuild = true;
  allowSubstitutes = false;

  nativeBuildInputs = [
    python
    patchelf
    makeWrapper
  ]
  ++ nativeBuildInputs;

  buildPhase = ''
    runHook preBuild
    python3 -I ${./mirror.py} \
      --install ${installLayer} \
      --out "$out" \
      --placeholder ${lib.escapeShellArg overlayfsLib.nativeInstallRootPlaceholder} \
      --interpreter ${stdenv.cc.bintools.dynamicLinker} \
      --libc-dir ${lib.getLib stdenv.cc.libc}/lib \
      --libs ${lib.escapeShellArgs libDirs} \
      --runtime-dirs ${lib.escapeShellArgs runtimeDirs} \
      --library-dirs ${lib.escapeShellArgs libraryDirs} \
      --ignore-missing ${lib.escapeShellArgs ignoreMissingDeps} \
      --copy ${lib.escapeShellArgs copyFiles}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    ${postBuild}
    runHook postInstall
  '';

  passthru = {
    inherit installLayer libraries;
  }
  // passthru;
}
