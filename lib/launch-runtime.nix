# A package can be installed with one Wine (`runtime`) and launched with
# another (`launchRuntime`): the layers are built once, and patched Wine
# builds are tried without rebuilding them.
#
# What makes this work, and its limits:
# - Wine loads a builtin module from its own installation when the prefix
#   holds a file with the builtin marker (load_builtin() in
#   dlls/ntdll/unix/loader.c); the prefix copy is only a fallback. A module
#   the launch Wine no longer has falls back to the old copy (or fails, for
#   fake DLLs), and a module it newly has is not in the prefix at all.
# - The launcher keeps wineboot from updating the prefix automatically
#   (.update-timestamp = disable), so prefix contents that only wine.inf
#   creates - registry keys, files, new modules - stay as the install Wine
#   left them.
# So both Wines must produce the same prefix. That is not something this
# library can determine; it compares `prefixCompatibility`, which runtimes take
# from the Wine package (passthru.prefixCompatibility) or, failing that, the
# upstream release, and the Windows architecture. Whoever declares the value
# vouches that builds sharing it differ only in code, not in prefix contents.
{ lib }:
let
  compatibility =
    runtime: runtime.prefixCompatibility or (runtime.upstreamVersion or (runtime.version or null));
  arch = runtime: runtime.windowsArch or null;
in
{
  check =
    {
      runtime,
      launchRuntime,
      packageName,
    }:
    if arch launchRuntime != arch runtime then
      throw "${packageName}: launchRuntime is ${toString (arch launchRuntime)}, the installation ${toString (arch runtime)}"
    else if compatibility launchRuntime != compatibility runtime then
      throw "${packageName}: installed with a Wine for prefixes \"${toString (compatibility runtime)}\" but launched with one for \"${toString (compatibility launchRuntime)}\"; rebuild the installation with that Wine (runtime) instead"
    else
      true;
}
