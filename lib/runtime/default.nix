# Small runtime helpers called by the generated launcher scripts. Each one is a
# standalone, shellchecked program so it can be tested without mounting a
# prefix.
{
  writeShellApplication,
  attr,
  coreutils,
  diffutils,
  findutils,
}:
{
  guardPrefixUpdates = writeShellApplication {
    name = "nix-overlayfs-guard-prefix-updates";
    runtimeInputs = [ coreutils ];
    text = builtins.readFile ./guard-prefix-updates.sh;
  };

  checkShadowed = writeShellApplication {
    name = "nix-overlayfs-check-shadowed";
    runtimeInputs = [
      attr
      coreutils
      diffutils
      findutils
    ];
    text = builtins.readFile ./check-shadowed.sh;
  };
}
