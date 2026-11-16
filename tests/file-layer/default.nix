{
  pkgs,
  overlayfsLib,
}:
let
  dll = name: pkgs.writeText "${name}.dll" "fake ${name}";
  layer = overlayfsLib.mkFileLayer {
    pname = "file-layer-test";
    version = "1.0";
    files = {
      "drive_c/windows/system32/d3d11.dll" = dll "d3d11-64";
      "drive_c/windows/syswow64/d3d11.dll" = dll "d3d11-32";
    };
    registryDllOverrides = {
      D3D11 = "native";
      "dxgi.dll" = "n,b";
      msquic = "";
    };
  };
  empty = overlayfsLib.mkFileLayer {
    pname = "file-layer-empty";
    version = "1.0";
    files."drive_c/x.txt" = pkgs.writeText "x" "x";
  };
  rejected = builtins.tryEval (
    overlayfsLib.mkFileLayer {
      pname = "file-layer-bad";
      version = "1.0";
      files."/etc/passwd" = dll "x";
    }
  ).drvPath;
in
# Registry overrides stay out of WINEDLLOVERRIDES.
assert overlayfsLib.dllOverrides.fromLayer layer == { };
assert !rejected.success;
pkgs.runCommand "file-layer-test"
  {
    nativeBuildInputs = [
      overlayfsLib.scripts.mergeWineRegistries
      overlayfsLib.scripts.reg2json
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail
    b=${layer}/basePackage
    grep -qx 'fake d3d11-64' $b/drive_c/windows/system32/d3d11.dll
    grep -qx 'fake d3d11-32' $b/drive_c/windows/syswow64/d3d11.dll
    jq -e '.keys["Software\\\\Wine\\\\DllOverrides"] == {
      "\"d3d11\"": "\"native\"",
      "\"dxgi\"": "\"native,builtin\"",
      "\"msquic\"": "\"\""
    }' $b/user.json
    test ! -e ${empty}/basePackage/user.reg

    # Merged under an application layer that keeps a per-program exception:
    # the global override is added, the exception stays.
    mkdir base out
    cat > base/user.reg <<'EOF'
    WINE REGISTRY Version 2
    ;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

    #arch=win64

    [Software\\Wine\\AppDefaults\\msedgewebview2.exe\\DllOverrides]
    "d3d11"="builtin"
    EOF
    merge-wine-registries out $b base
    reg2json out/user.reg > user.json
    jq -e '
      .keys["Software\\\\Wine\\\\DllOverrides"]["\"d3d11\""] == "\"native\"" and
      .keys["Software\\\\Wine\\\\AppDefaults\\\\msedgewebview2.exe\\\\DllOverrides"]["\"d3d11\""] == "\"builtin\""
    ' user.json
    touch $out
  ''
