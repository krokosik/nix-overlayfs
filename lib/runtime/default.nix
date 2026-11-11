# Small runtime helpers called by the generated launcher scripts. Each one is a
# standalone, shellchecked program so it can be tested without mounting a
# prefix.
{
  writeShellApplication,
  coreutils,
}:
{
  guardPrefixUpdates = writeShellApplication {
    name = "nix-overlayfs-guard-prefix-updates";
    runtimeInputs = [ coreutils ];
    text = builtins.readFile ./guard-prefix-updates.sh;
  };
}
