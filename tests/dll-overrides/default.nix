{
  pkgs,
  overlayfsLib,
}:
let
  inherit (pkgs) lib;
  dll = overlayfsLib.dllOverrides;

  fakeLayer =
    name: passthru:
    pkgs.runCommand name
      {
        pname = name;
        version = "1.0.0";
        passthru = {
          runtimeEnvVars = { };
        }
        // passthru;
      }
      ''
        mkdir -p "$out/basePackage"
      '';

  baseEnvLayer = fakeLayer "dll-overrides-base-env" { };

  # Enough of a runtime for composeWindowsLayers, without Wine.
  runtime = {
    toolsPackage = pkgs.coreutils;
    programFilesPath = "/drive_c/Program Files";
    selectBaseEnvLayer = _: baseEnvLayer;
    mkSession = _: {
      buildInputs = [ ];
      env = { };
      preCommands = "";
      postCommands = "";
      commands = {
        wine = "${pkgs.coreutils}/bin/true";
        wineserver = "${pkgs.coreutils}/bin/true";
      };
    };
  };

  dxvkLayer = fakeLayer "dll-overrides-dxvk" {
    dllOverrides = {
      d3d11 = "n";
      DXGI = "native";
    };
  };
  # A layer that still uses runtimeEnvVars.WINEDLLOVERRIDES.
  legacyLayer = fakeLayer "dll-overrides-legacy" {
    runtimeEnvVars.WINEDLLOVERRIDES = "msquic=;D3DCompiler_47.dll=native,builtin";
  };
  conflictingLayer = fakeLayer "dll-overrides-conflicting" {
    dllOverrides.d3d11 = "b";
  };

  compose =
    overlayDependencies: args:
    overlayfsLib.composeWindowsLayers (
      {
        inherit runtime overlayDependencies;
        packageName = "dll-overrides";
        baseLayer = {
          basePackage = fakeLayer "dll-overrides-app" { };
          overlayDependencies = [ ];
          runtimeEnvVars = { };
        };
        executableName = "dll-overrides";
        executablePath = "/drive_c/app.exe";
        hostIntegration = false;
      }
      // args
    );

  package = compose [ dxvkLayer legacyLayer ] {
    runtimeEnvVars = {
      WINEDLLOVERRIDES = "winemenubuilder.exe=d";
      DLL_OVERRIDES_TEST = "kept";
    };
    # The package settles what its layers chose.
    dllOverrides.dxgi = "b";
  };

  expected = "d3d11=n;d3dcompiler_47=n,b;dxgi=b;msquic=;winemenubuilder.exe=";

  conflict = builtins.tryEval (
    builtins.deepSeq (compose [ dxvkLayer conflictingLayer ] { }).drvPath null
  );
  settled = compose [ dxvkLayer conflictingLayer ] { dllOverrides.d3d11 = "n,b"; };

  evalChecks =
    assert dll.parse "d3d11,dxgi=n;msquic=" == {
      d3d11 = "n";
      dxgi = "n";
      msquic = "";
    };
    # Wine semantics: later entries win, separators may be spaces, entries
    # without "=" are ignored, only the first letter of an order counts.
    assert dll.parse "a=n; a=b ;b c=Builtin,Native;bogus;d=disabled" == {
      a = "b";
      b = "b,n";
      c = "b,n";
      d = "";
    };
    # Tabs separate names and order entries too.
    assert dll.parse "foo\tbar=n" == {
      foo = "n";
      bar = "n";
    };
    assert dll.parse "foo=n\tb" == { foo = "n,b"; };
    assert dll.render (dll.normalize { "Foo.DLL" = "native,builtin"; }) == "foo=n,b";
    assert dll.exportCommand { } == "";
    assert !conflict.success;
    true;
in
assert evalChecks;
pkgs.runCommand "dll-overrides-test" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -euo pipefail
  script="${package}/bin/dll-overrides-unwrapped"

  # One merged export instead of a single layer's value.
  test "$(grep -c '^export WINEDLLOVERRIDES=' "$script")" -eq 1
  grep -Fx "export DLL_OVERRIDES_TEST='kept'" "$script"

  line="$(grep '^export WINEDLLOVERRIDES=' "$script")"
  test "$(env -u WINEDLLOVERRIDES bash -c "$line"'; printf %s "$WINEDLLOVERRIDES"')" = '${expected}'
  # The user's own overrides come last, so Wine lets them win.
  test "$(WINEDLLOVERRIDES='d3d11=b' bash -c "$line"'; printf %s "$WINEDLLOVERRIDES"')" = '${expected};d3d11=b'

  grep -F "d3d11=n,b" "${settled}/bin/dll-overrides-unwrapped"

  touch "$out"
''
