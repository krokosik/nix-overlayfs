# A Windows layer made of files and registry DLL overrides, built without
# Wine: for prebuilt native DLLs such as DXVK or vkd3d-proton. Use it as an
# overlayDependency of composeWindowsLayers (runtime only: changing it
# rebuilds only the launcher) or of mkWindowsPackage (also present while
# installing).
#
#   overlayfsLib.mkFileLayer {
#     pname = "dxvk";
#     version = "2.7.1";
#     files."drive_c/windows/system32/d3d11.dll" = "${dxvk}/x64/d3d11.dll";
#     registryDllOverrides.d3d11 = "native";
#   }
#
# registryDllOverrides go into HKCU\Software\Wine\DllOverrides (the layer's
# user.reg), not into WINEDLLOVERRIDES: Wine gives the environment priority
# over the per-application keys (HKCU\Software\Wine\AppDefaults\<exe>\
# DllOverrides, get_load_order_value() in dlls/ntdll/unix/loadorder.c), so only
# the registry leaves room for per-program exceptions. Orders are normalized
# as in dllOverrides ("n", "native", "n,b", "" for disabled).
{
  lib,
  runCommand,
  overlayfsLib,
}:
{
  pname,
  version,
  # Paths below the prefix root -> source files.
  files ? { },
  registryDllOverrides ? { },
  passthru ? { },
  meta ? { },
}:
let
  overrides = overlayfsLib.dllOverrides.normalize registryDllOverrides;
  # The registry spells load orders out.
  registryOrder =
    order:
    lib.concatStringsSep "," (map (letter: if letter == "n" then "native" else "builtin") (
      lib.filter (letter: letter != "") (lib.splitString "," order)
    ));
  userReg = ''
    WINE REGISTRY Version 2
    ;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

    #arch=win64

    [Software\\Wine\\DllOverrides]
    ${lib.concatStrings (
      lib.mapAttrsToList (module: order: ''
        "${module}"="${registryOrder order}"
      '') overrides
    )}'';
  badPaths = lib.filter (path: lib.hasPrefix "/" path || lib.hasInfix ".." path) (lib.attrNames files);
in
assert lib.assertMsg (badPaths == [ ])
  "mkFileLayer ${pname}: file paths must be relative to the prefix root: ${toString badPaths}";
runCommand "${pname}-${version}"
  {
    inherit pname version meta;
    nativeBuildInputs = [ overlayfsLib.scripts.reg2json ];
    inherit userReg;
    passAsFile = [ "userReg" ];
    passthru = {
      runtimeEnvVars = { };
      overlayDependencies = [ ];
      inherit registryDllOverrides;
    }
    // passthru;
  }
  ''
    mkdir -p "$out/basePackage"
    ${lib.concatStrings (
      lib.mapAttrsToList (path: source: ''
        install -Dm444 ${lib.escapeShellArg source} "$out/basePackage/"${lib.escapeShellArg path}
      '') files
    )}
    ${lib.optionalString (overrides != { }) ''
      cp "$userRegPath" "$out/basePackage/user.reg"
      chmod 444 "$out/basePackage/user.reg"
      # Installations built on this layer merge the registry as JSON.
      reg2json "$out/basePackage/user.reg" > "$out/basePackage/user.json"
    ''}
  ''
