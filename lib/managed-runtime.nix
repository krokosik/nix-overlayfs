# How a prefix gets .NET:
#   "auto"      Wine Mono, installed in the base environment;
#   "disabled"  none (mscoree and mshtml are turned off);
#   "external"  no Wine Mono; a layer provides .NET (for example
#               dotnet-framework-4-8, which says so with
#               passthru.requiredManagedRuntime = "external").
{ lib }:
let
  values = [
    "auto"
    "disabled"
    "external"
  ];
in
{
  inherit values;

  check =
    managedRuntime:
    if builtins.elem managedRuntime values then
      true
    else
      throw "managedRuntime must be one of: ${lib.concatStringsSep ", " values}";

  # A layer built for one kind of base environment does not fit another: the
  # .NET Framework layer removes Wine Mono's files, which only works if the
  # base environment never had them.
  checkLayers =
    {
      managedRuntime,
      layers,
      packageName,
    }:
    let
      mismatched = lib.filter (
        layer: (layer.requiredManagedRuntime or managedRuntime) != managedRuntime
      ) layers;
      describe = layer: "${layer.name or "a layer"} (needs \"${layer.requiredManagedRuntime}\")";
    in
    if mismatched == [ ] then
      true
    else
      throw "${packageName}: managedRuntime is \"${managedRuntime}\", but ${lib.concatMapStringsSep ", " describe mismatched}; set managedRuntime = \"${(builtins.head mismatched).requiredManagedRuntime}\"";
}
