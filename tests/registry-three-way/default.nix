{
  pkgs,
  overlayfsLib,
}:
let
  registry = "${overlayfsLib.runtimeScripts.registry}/bin/nix-overlayfs-registry";
in
pkgs.runCommand "registry-three-way-test"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.gnugrep
    ];
  }
  ''
set -euo pipefail

# hive DIR NAME LOCATION < KEYS writes DIR/NAME.reg.
hive() {
  mkdir -p "$1"
  { printf 'WINE REGISTRY Version 2\n;; All keys relative to REGISTRY\\\\%s\n\n#arch=win64\n\n' "$3"; cat; } > "$1/$2.reg"
}
# layer DIR < USER_KEYS: a Nix layer with all three hives.
layer() {
  hive "$1" user 'User\\S-1-5-21-0-0-0-1000'
  printf '[Software\\\\Machine]\n"m"="1"\n' | hive "$1" system Machine
  printf '[Control Panel]\n"d"="1"\n' | hive "$1" userdef 'User\\.Default'
}
merge() {
  ${registry} merge "$PWD/$1" "$1-state/registry-sources" tmp/registry-sources "''${@:2}" "$PWD/$1"
}
has() { grep -Fx -- "$2" "$1/user.reg"; }
lacks() { ! grep -Fx -- "$2" "$1/user.reg"; }
mkdir tmp

layer layer1 <<'EOF'
[Software\\Pkg]
"Untouched"="1"
"Changed"="1"
"Deleted"="1"
"Dropped"="1"
"Type"="1"
"UserType"=dword:00000001
"Hex"=hex:01,02,03,04

[Software\\Pkg\\EmptyKey]

[Software\\Pkg\\DroppedKey]
EOF

layer layer2 <<'EOF'
[Software\\Pkg]
"Untouched"="2"
"Changed"="2"
"Deleted"="2"
"Type"=dword:00000001
"UserType"=dword:00000002
"Hex"=hex:ff
"New"="2"

[Software\\Pkg\\EmptyKey]
EOF

# First launch: the layers' registry, recorded as the base.
merge app "$PWD/layer1"
has app '"Untouched"="1"'
grep -Fx '"Untouched"="1"' app-state/registry-base/user.reg
test -f app-state/registry-base/system.reg -a -f app-state/registry-base/userdef.reg
test -s app-state/registry-sources

# Wine saves the whole registry (with timestamps, and long hex values broken
# over lines); the user changes, deletes, adds and retypes values, deletes a
# key and adds one.
hive app user 'User\\S-1-5-21-0-0-0-1000' <<'EOF'
[Software\\Mine] 1700000000
#time=1da0000000000000
#class="mine"
"Added"="user"

[Software\\Pkg] 1700000000
#time=1da0000000000000
"Untouched"="1"
"Changed"="user"
"Dropped"="1"
"Type"="1"
"UserType"="1"
"Hex"=hex:01,02,\
  03,04

[Software\\Pkg\\DroppedKey] 1700000000
#time=1da0000000000000
EOF

# The Nix layers change.
merge app "$PWD/layer2"
cat app/user.reg
# A value the user never touched follows the layers: changed, added,
# removed, retyped (REG_SZ to REG_DWORD), also when Wine wrapped it.
has app '"Untouched"="2"'
has app '"New"="2"'
lacks app '"Dropped"="1"'
has app '"Type"=dword:00000001'
has app '"Hex"=hex:ff'
# What the user changed, added or deleted stays so.
has app '"Changed"="user"'
has app '"Added"="user"'
has app '#class="mine"'
lacks app '"Deleted"="2"'
lacks app '"Deleted"="1"'
# The user's REG_SZ is a change of the layers' REG_DWORD, even with the
# same digits.
has app '"UserType"="1"'
# Keys: one the user deleted stays deleted, one the layers dropped is
# removed, one the user added stays.
! grep -F '[Software\\Pkg\\EmptyKey]' app/user.reg
! grep -F '[Software\\Pkg\\DroppedKey]' app/user.reg
grep -F '[Software\\Mine]' app/user.reg
# The base is what the layers give now.
grep -Fx '"Untouched"="2"' app-state/registry-base/user.reg
! grep -F '"Changed"="user"' app-state/registry-base/user.reg
printf '%s\n' "$PWD/layer2" | diff -u - app-state/registry-sources

# Same layers: no merge.
cp app/user.reg before.reg
sed -i 's/"Untouched"="2"/"Untouched"="mine now"/' app/user.reg
merge app "$PWD/layer2"
has app '"Untouched"="mine now"'

# A missing writable hive gets the layers' hive, not the deletions the base
# would imply.
rm app/userdef.reg
merge app "$PWD/layer2"
grep -Fx '"d"="1"' app/userdef.reg

# The user now owns "Untouched": a layer change does not override it.
layer layer3 <<'EOF'
[Software\\Pkg]
"Untouched"="3"
"Changed"="3"
EOF
merge app "$PWD/layer3"
has app '"Untouched"="mine now"'
has app '"Changed"="user"'
lacks app '"New"="2"'
lacks app '"Hex"=hex:ff'

# An existing state from before the base record: the writable hive wins
# (as before), the base is recorded, and the next layer change propagates
# what the writable hive shares with the layers.
hive old user 'User\\S-1-5-21-0-0-0-1000' <<'EOF'
[Software\\Pkg] 1700000000
"Untouched"="1"
"Changed"="old user"
"Deleted"="1"
EOF
merge old "$PWD/layer1"
test ! -e old-state/registry-base/.user.reg.nix-overlayfs-new
has old '"Untouched"="1"'
has old '"Changed"="old user"'
has old '"Dropped"="1"'
grep -Fx '"Changed"="1"' old-state/registry-base/user.reg
merge old "$PWD/layer2"
has old '"Untouched"="2"'
has old '"Changed"="old user"'
has old '"Deleted"="2"'
lacks old '"Dropped"="1"'
has old '"New"="2"'

# Failures: an unreadable writable hive, a writable hive that is not a file,
# or a base that cannot be written fail the merge before anything is
# written; the base and the signature stay unrecorded, and the launch goes
# on.
merge fail "$PWD/layer1"
cp -r fail-state/registry-base base-before
cp fail/user.reg user-before.reg
printf 'this line is not a value\n' >> fail/user.reg
cp fail/user.reg bad-user.reg
merge fail "$PWD/layer2" 2> fail.log
grep -F 'failed to parse registry' fail.log
grep -F 'merged again on the next launch' fail.log
cmp bad-user.reg fail/user.reg
diff -r base-before fail-state/registry-base
test ! -e fail-state/registry-sources
test -z "$(find fail fail-state -name '.*.nix-overlayfs-new')"

cp user-before.reg fail/user.reg
mv fail-state/registry-base base-saved
touch fail-state/registry-base
merge fail "$PWD/layer2" 2> fail.log
grep -F 'cannot create' fail.log
grep -F 'merged again on the next launch' fail.log
cmp user-before.reg fail/user.reg
test ! -e fail-state/registry-sources
rm fail-state/registry-base
mv base-saved fail-state/registry-base

mv fail/user.reg user-saved.reg
mkdir fail/user.reg
merge fail "$PWD/layer2" 2> fail.log
grep -F 'not a regular file' fail.log
diff -r base-before fail-state/registry-base
test ! -e fail-state/registry-sources
rmdir fail/user.reg
mv user-saved.reg fail/user.reg

# Retried on the next launch, three-way against the base that was kept.
merge fail "$PWD/layer2"
has fail '"Untouched"="2"'
grep -Fx '"Untouched"="2"' fail-state/registry-base/user.reg
test -s fail-state/registry-sources

# A base hive that cannot be read is ignored (the writable hive wins) and
# recorded anew.
printf 'garbage\n' > fail-state/registry-base/user.reg
sed -i 's/"Untouched"="2"/"Untouched"="kept"/' fail/user.reg
merge fail "$PWD/layer1" 2> base.log
grep -F 'ignoring the registry base record' base.log
has fail '"Untouched"="kept"'
grep -Fx '"Untouched"="1"' fail-state/registry-base/user.reg

touch "$out"
''
