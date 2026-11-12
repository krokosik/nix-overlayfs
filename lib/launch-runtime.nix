# A package can be installed with one Wine (`runtime`) and launched with
# another (`launchRuntime`): the layers are built once with a released Wine,
# and patched Wine builds are tried without rebuilding them. Wine loads its
# builtin modules from its own installation, not from the copies in the
# prefix, and the launcher keeps Wine from updating the prefix at runtime
# (.update-timestamp = disable), so the layers stay as they were built. Both
# Wines must therefore be builds of the same Wine release for the same
# Windows architecture: a newer release may expect prefix contents (wine.inf)
# the layers do not have.
{ lib }:
let
  release = runtime: runtime.upstreamVersion or (runtime.version or null);
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
    else if release launchRuntime != release runtime then
      throw "${packageName}: installed with Wine ${toString (release runtime)} but launched with Wine ${toString (release launchRuntime)}; launchRuntime must be a build of the same Wine release"
    else
      true;
}
