# The install layer of a native (Linux) application: the files that its
# vendor's installer writes, without patches. It is built with nothing but the
# installer and stdenvNoCC, so an update of a library that the application
# needs at run time (a JDK, Qt, X11) never runs the installer again.
# mkNativePackage patches the layer for those libraries in a separate, much
# cheaper derivation.
#
#   overlayfsLib.mkNativeInstallLayer {
#     pname = "foo";
#     version = "1.0";
#     src = ./foo-installer.sh;
#     unpackPhase = "sh $src --extract";
#     installPhase = "./install --prefix=$out";
#     # Optional: makes the layer fixed-output, so not even a new stdenvNoCC
#     # reinstalls it. Nix then also ignores changes to this recipe until the
#     # hash changes.
#     outputHash = "sha256-...";
#   }
#
# The layer must not refer to the Nix store. Installers write the layer's own
# path into scripts and .desktop files; in text files it is replaced by
# overlayfsLib.nativeInstallRootPlaceholder, and mkNativePackage later puts
# the package's path there. Absolute symlinks into the layer are made
# relative. If a binary file contains the path, the build fails.
{
  lib,
  stdenvNoCC,
  overlayfsLib,
}:
{
  pname,
  version,
  src,
  installPhase,
  unpackPhase ? null,
  nativeBuildInputs ? [ ],
  outputHash ? null,
  stdenv ? stdenvNoCC,
  passthru ? { },
  meta ? { },
}:
let
  placeholder = overlayfsLib.nativeInstallRootPlaceholder;
in
stdenv.mkDerivation (
  {
    pname = "${pname}-install";
    inherit
      version
      src
      nativeBuildInputs
      meta
      ;
    dontConfigure = true;
    dontBuild = true;
    # No patchShebangs, stripping or patchelf: those would bring store paths in.
    dontFixup = true;
    # IO bound; nothing to gain from a remote builder.
    preferLocalBuild = true;
    allowSubstitutes = false;

    installPhase = ''
      runHook preInstall
      ${installPhase}
      runHook postInstall

      echo "normalizing references to $out"
      # Absolute symlinks into the layer become relative.
      while IFS= read -r -d "" link; do
        target="$(readlink "$link")"
        ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$target")" "$link"
      done < <(find "$out" -type l -lname "$out/*" -print0)

      # Text files name the layer by a placeholder.
      grep -rlIZF -- "$out" "$out" | xargs -0r sed -i "s|$out|${placeholder}|g"

      binaries="$(grep -rlF -- "$out" "$out" || true)"
      if [ -n "$binaries" ]; then
        echo "error: binary files in the install layer refer to its path:" >&2
        printf '%s\n' "$binaries" >&2
        exit 1
      fi
      others="$(grep -rlF -- "$NIX_STORE/" "$out" | head -20 || true)"
      if [ -n "$others" ]; then
        echo "${
          if outputHash == null then "warning" else "error"
        }: the install layer refers to the Nix store; such references reinstall it when they change:" >&2
        printf '%s\n' "$others" >&2
        ${lib.optionalString (outputHash != null) "exit 1"}
      fi
    '';

    passthru = {
      inherit placeholder;
    }
    // passthru;
  }
  // lib.optionalAttrs (unpackPhase != null) { inherit unpackPhase; }
  // lib.optionalAttrs (outputHash != null) {
    inherit outputHash;
    outputHashMode = "recursive";
  }
)
