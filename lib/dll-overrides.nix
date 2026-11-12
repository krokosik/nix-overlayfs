# Wine DLL load-order overrides as data, so that layers can each contribute
# overrides without replacing each other's WINEDLLOVERRIDES.
#
# An override set maps a module name to a load order, for example
#   { d3d11 = "n"; dxgi = "n"; msquic = ""; "winemenubuilder.exe" = ""; }
# Names and orders are normalized as Wine reads them
# (dlls/ntdll/unix/loadorder.c): names case-insensitively and without ".dll";
# orders by the first letter of each comma-separated entry, so "native,builtin"
# becomes "n,b" and "d", "disabled" or "" become "" (disabled).
{ lib }:
let
  normalizeName = name: lib.removeSuffix ".dll" (lib.toLower (lib.trim name));

  # Wine separates module names and load-order entries by commas, spaces and
  # tabs (separatorsW in dlls/ntdll/unix/loadorder.c).
  splitEntries =
    value: lib.filter (entry: entry != "") (lib.splitString "," (lib.replaceStrings [ " " "\t" ] [ "," "," ] value));

  normalizeOrder =
    order:
    let
      entries = splitEntries order;
      letters = lib.filter (letter: letter == "n" || letter == "b") (
        map (entry: lib.toLower (builtins.substring 0 1 entry)) entries
      );
    in
    lib.concatStringsSep "," (lib.unique letters);

  normalize =
    overrides:
    lib.mapAttrs' (name: order: lib.nameValuePair (normalizeName name) (normalizeOrder order)) overrides;

  # "d3d11,dxgi=n;msquic=" -> { d3d11 = "n"; dxgi = "n"; msquic = ""; }
  # As in Wine, a later entry for the same module replaces an earlier one and
  # entries without "=" are ignored.
  parse =
    value:
    lib.foldl' (
      result: entry:
      let
        parts = lib.splitString "=" entry;
        names = splitEntries (builtins.head parts);
        order = lib.concatStringsSep "=" (builtins.tail parts);
      in
      if builtins.length parts < 2 then
        result
      else
        result // normalize (lib.genAttrs names (_: order))
    ) { } (lib.splitString ";" value);

  # The overrides a layer or package declares: dllOverrides, plus a
  # WINEDLLOVERRIDES in runtimeEnvVars (the older way to declare them).
  fromLayer =
    layer:
    parse ((layer.runtimeEnvVars or { }).WINEDLLOVERRIDES or "") // normalize (layer.dllOverrides or { });

  layerName =
    layer: layer.name or (layer.basePackage.name or (layer.pname or "an unnamed layer"));

  # Merges the overrides of several layers. Two layers that disagree about a
  # module are an error rather than a silent order-dependent choice, unless
  # the module is in `settled`: the package decides it with its own
  # dllOverrides (see `combine`).
  mergeLayers =
    {
      layers,
      settled ? [ ],
    }:
    (lib.foldl' (
      merged: layer:
      let
        name = layerName layer;
        overrides = fromLayer layer;
      in
      lib.foldl' (
        merged: module:
        let
          order = overrides.${module};
        in
        if
          merged.orders ? ${module}
          && merged.orders.${module} != order
          && !(builtins.elem module settled)
        then
          throw ''
            nix-overlayfs: ${merged.sources.${module}} and ${name} set conflicting DLL overrides for ${module}: "${
              merged.orders.${module}
            }" and "${order}". Set dllOverrides.${module} on the package to choose one.''
        else
          {
            orders = merged.orders // {
              ${module} = order;
            };
            sources = merged.sources // {
              ${module} = merged.sources.${module} or name;
            };
          }
      ) merged (builtins.attrNames overrides)
    ) {
      orders = { };
      sources = { };
    } layers).orders;

  # Overrides of the layers below a package, with the package's own winning.
  combine =
    { layers, package }:
    let
      own = fromLayer package;
    in
    mergeLayers {
      inherit layers;
      settled = builtins.attrNames own;
    }
    // own;

  render =
    overrides:
    lib.concatStringsSep ";" (lib.mapAttrsToList (module: order: "${module}=${order}") overrides);

  # Exports the overrides, keeping a WINEDLLOVERRIDES the user set: Wine lets a
  # later entry for the same module win, so the user's entries come last.
  exportCommand =
    overrides:
    lib.optionalString (overrides != { }) ''
      export WINEDLLOVERRIDES=${lib.escapeShellArg (render overrides)}"''${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
    '';

  # runtimeEnvVars without the WINEDLLOVERRIDES now carried by the overrides.
  withoutOverrides = envVars: removeAttrs envVars [ "WINEDLLOVERRIDES" ];
in
{
  inherit
    normalize
    parse
    fromLayer
    mergeLayers
    combine
    render
    exportCommand
    withoutOverrides
    ;
}
