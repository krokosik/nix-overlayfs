{
  pkgs,
  overlayfsLib,
}:
let
  registry = "${overlayfsLib.runtimeScripts.registry}/bin/nix-overlayfs-registry";
  # The case mapping of a Wine the launchers run.
  caseTable = "${pkgs.nix-overlayfs.moduleScopes.nativeModules.runtime.toolsPackage}/share/wine/nls/l_intl.nls";
in
pkgs.runCommand "registry-three-way-test"
  {
    nativeBuildInputs = [
      overlayfsLib.scripts.mergeWineRegistries
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
  ${registry} merge --case-table ${caseTable} "$PWD/$1" "$1-state/registry-sources" tmp/registry-sources "''${@:2}" "$PWD/$1"
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
# Keys: a key that the user deleted stays deleted, a key that the layers
# dropped is removed, and a key that the user added stays.
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
test -z "$(find old old-state -name '.*.nix-overlayfs-*')"
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
mkdir fail-state/registry-base.new
touch fail-state/registry-base.new/blocker
chmod a-w fail-state/registry-base.new
merge fail "$PWD/layer2" 2> fail.log
cat fail.log
grep -F 'failed to write' fail.log
grep -F 'merged again on the next launch' fail.log
cmp user-before.reg fail/user.reg
diff -r base-before fail-state/registry-base
test ! -e fail-state/registry-sources
chmod u+w fail-state/registry-base.new
rm -r fail-state/registry-base.new

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

# A base record that does not match its manifest (truncated to its
# header, changed, without manifest) fails the merge: taking it for no base
# would make every value the user's. Removing it lets the writable values
# win once, and records the base anew.
sed -i 's/"Untouched"="2"/"Untouched"="kept"/' fail/user.reg
cp fail/user.reg user-before.reg
cp -r fail-state/registry-base base-good
for damage in truncate change manifest; do
  rm -rf fail-state/registry-base
  cp -r base-good fail-state/registry-base
  chmod -R u+w fail-state/registry-base
  case "$damage" in
    truncate) head -n 4 base-good/user.reg > fail-state/registry-base/user.reg ;;
    change) sed -i 's/"Untouched"="2"/"Untouched"="3"/' fail-state/registry-base/user.reg ;;
    manifest) rm fail-state/registry-base/manifest ;;
  esac
  merge fail "$PWD/layer1" 2> base.log
  grep -F 'is damaged' base.log
  grep -F 'merged again on the next launch' base.log
  cmp user-before.reg fail/user.reg
  test ! -e fail-state/registry-sources
done
rm -rf fail-state/registry-base
merge fail "$PWD/layer1"
has fail '"Untouched"="kept"'
grep -Fx '"Untouched"="1"' fail-state/registry-base/user.reg

# The signature and the base record are bound to each other by the commit
# that wrote them; when they disagree, only what can be traced is trusted.
# An older launcher without base records merged layers that add New=2 and
# rewrote the signature: the base record still holds for the values it has
# (such a merge keeps the writable value), and New, which it lacks, came
# from the layers the signature names. Both follow the layers again.
merge hist "$PWD/layer1"
merge-wine-registries hist "$PWD/layer2" "$PWD/hist"
printf '%s\n' "$PWD/layer2" > hist-state/registry-sources
layer layer-new3 <<'EOF'
[Software\\Pkg]
"Untouched"="3"
"New"="3"
EOF
merge hist "$PWD/layer-new3" 2> base.log
grep -F 'the layer signature was rewritten' base.log
has hist '"New"="3"'
has hist '"Untouched"="3"'
# Another state's base record (valid, but not the one this state's last
# commit wrote), whose value happens to be the user's, does not give the
# user's value to the layers: it is rebuilt from the signature's layers.
merge own "$PWD/layer1"
sed -i 's/^"Changed"="1"$/"Changed"="user"/' own/user.reg
layer layer-user <<'EOF'
[Software\\Pkg]
"Changed"="user"
EOF
merge foreign "$PWD/layer-user"
rm -r own-state/registry-base
cp -r foreign-state/registry-base own-state/registry-base
merge own "$PWD/layer2" 2> base.log
grep -F 'rebuilt it from the layers that merge used' base.log
has own '"Changed"="user"'
has own '"Untouched"="2"'
# A signature edited to name a layer that has the user's value: the base
# record says the layers gave "1", so "user" stays the user's.
merge edited "$PWD/layer1"
sed -i 's/^"Changed"="1"$/"Changed"="user"/' edited/user.reg
printf '%s\n' "$PWD/layer-user" > edited-state/registry-sources
merge edited "$PWD/layer2" 2> base.log
grep -F 'the layer signature was rewritten' base.log
has edited '"Changed"="user"'
has edited '"Untouched"="2"'
# ... and one that names layers whose values are not in the writable hive
# (they cannot have been merged into it) is not used for what the base lacks.
merge edited2 "$PWD/layer1"
printf '"Mine"="user"\n' >> edited2/user.reg
layer layer-mine <<'EOF'
[Software\\Pkg]
"Mine"="user"
"NeverMerged"="1"
EOF
printf '%s\n' "$PWD/layer-mine" > edited2-state/registry-sources
merge edited2 "$PWD/layer2" 2> base.log
grep -F 'cannot have been merged into' base.log
has edited2 '"Mine"="user"'
# With the named layers gone, only the base record is used.
printf '%s\n' /nix/store/gone-layers > fail-state/registry-sources
merge fail "$PWD/layer2" 2> base.log
grep -F 'layers the signature names are gone' base.log
has fail '"Untouched"="kept"'
has fail '"New"="2"'
grep -Fx '"Untouched"="2"' fail-state/registry-base/user.reg
# Neither the base record nor the signature traceable: the writable values
# win once.
merge lost "$PWD/layer1"
sed -i 's/^"Changed"="1"$/"Changed"="user"/' lost/user.reg
rm lost-state/registry-base.binding
printf '%s\n' "$PWD/layer-user" > lost-state/registry-sources
merge lost "$PWD/layer2" 2> base.log
grep -F 'neither it nor the layer signature can be traced' base.log
has lost '"Changed"="user"'
has lost '"Untouched"="1"'

# An interrupted merge is completed (or, before its journal, dropped) on
# the next run, at every step: the result is the same as without the
# interruption, and nothing is taken for the user's.
merge ref "$PWD/layer1"
cp app/user.reg user-edited.reg
sed -i 's/^"Untouched"="mine now"$/"Untouched"="1"/' user-edited.reg
cp user-edited.reg ref/user.reg
merge ref "$PWD/layer2"
has ref '"Untouched"="2"'
step=1
while :; do
  rm -rf int int-state
  merge int "$PWD/layer1"
  cp user-edited.reg int/user.reg
  NIX_OVERLAYFS_REGISTRY_TEST_INTERRUPT=$step merge int "$PWD/layer2" 2> int.log || true
  if ! grep -F 'interrupting the registry merge' int.log; then
    break
  fi
  test ! -e int-state/registry-sources
  merge int "$PWD/layer2" 2> int.log
  cat int.log
  for hive in system user userdef; do
    cmp "ref/$hive.reg" "int/$hive.reg"
    cmp "ref-state/registry-base/$hive.reg" "int-state/registry-base/$hive.reg"
  done
  cmp ref-state/registry-base/manifest int-state/registry-base/manifest
  cmp ref-state/registry-sources int-state/registry-sources
  test -z "$(find int int-state -name '.*.nix-overlayfs-*')"
  test ! -e int-state/registry-base.new -a ! -e int-state/registry-base.old -a ! -e int-state/registry-base.journal
  step=$((step + 1))
done
# (Every step of the commit was tried.)
test "$step" -gt 8

# The launch goes on after a merge stopped in the middle only once that
# merge is completed: Wine's saves after it are not replaced by the next
# launch's recovery. (Each step: stopped, then the application saves a
# value, then the next launch.)
step=1
while :; do
  rm -rf save save-state
  merge save "$PWD/layer1"
  cp user-edited.reg save/user.reg
  NIX_OVERLAYFS_REGISTRY_TEST_INTERRUPT=$step merge save "$PWD/layer2" 2> save.log
  if ! grep -F 'interrupting the registry merge' save.log; then
    break
  fi
  test ! -e save-state/registry-base.journal
  test -z "$(find save -name '.*.nix-overlayfs-*')"
  sed -i 's/^"Changed"=.*/"Changed"="saved-after-failed-merge"/' save/user.reg
  merge save "$PWD/layer2"
  has save '"Changed"="saved-after-failed-merge"'
  step=$((step + 1))
done
test "$step" -gt 8

# If the stopped merge cannot be completed, the launch must not go on.
merge abort "$PWD/layer1"
printf '%s\n' "$PWD/layer2" > tmp/abort-next
NIX_OVERLAYFS_REGISTRY_TEST_INTERRUPT=3 merge-wine-registries --base "$PWD/abort-state/registry-base" \
  --signature abort-state/registry-sources --signature-next tmp/abort-next "$PWD/abort" "$PWD/layer2" || true
test -e abort-state/registry-base.journal
cp abort/user.reg abort-before.reg
chmod a-w abort
! merge abort "$PWD/layer2" 2> abort.log
cat abort.log
grep -F 'cannot be completed' abort.log
chmod u+w abort
cmp abort-before.reg abort/user.reg
merge abort "$PWD/layer2"
test ! -e abort-state/registry-base.journal
has abort '"Untouched"="2"'

# Recovery checks what it completes against the journal: a damaged journal,
# a missing staged hive or one from another transaction, or a hive changed
# since, change nothing and stop the launch, with what to remove.
pending() {
  rm -rf "$1" "$1-state"
  merge "$1" "$PWD/layer1"
  cp user-edited.reg "$1/user.reg"
  printf '%s\n' "$PWD/layer2" > "tmp/$1-next"
  NIX_OVERLAYFS_REGISTRY_TEST_INTERRUPT=3 merge-wine-registries --case-table ${caseTable} \
    --base "$PWD/$1-state/registry-base" --signature "$1-state/registry-sources" \
    --signature-next "tmp/$1-next" "$PWD/$1" "$PWD/layer2" || true
  test -e "$1-state/registry-base.journal"
}
snapshot() {
  find "$1" "$1-state" -type f -exec cksum {} + | sort
}
for damage in empty-journal truncated-journal missing-staged other-staged changed-hive; do
  pending tamper
  case "$damage" in
    empty-journal) : > tamper-state/registry-base.journal ;;
    truncated-journal) head -n 2 tamper-state/registry-base.journal > journal.tmp && cat journal.tmp > tamper-state/registry-base.journal ;;
    missing-staged) rm tamper/.user.reg.nix-overlayfs-new ;;
    other-staged) cp tamper/user.reg tamper/.user.reg.nix-overlayfs-new ;;
    changed-hive) sed -i 's/^"Changed"=.*/"Changed"="saved meanwhile"/' tamper/user.reg ;;
  esac
  snapshot tamper > tamper-before.txt
  ! merge tamper "$PWD/layer2" 2> tamper.log
  cat tamper.log
  grep -F 'cannot be completed safely' tamper.log
  grep -F 'To start over' tamper.log
  grep -F 'not starting' tamper.log
  snapshot tamper | diff -u tamper-before.txt -
done
# Removing what the message names starts over: the writable values win.
rm -rf tamper-state/registry-base tamper-state/registry-base.new tamper-state/registry-base.old \
  tamper-state/registry-base.journal tamper/.*.nix-overlayfs-new
merge tamper "$PWD/layer2"
has tamper '"Changed"="saved meanwhile"'
test -s tamper-state/registry-sources

# Values are compared as Wine sees them: key paths and value names without
# regard to case, @ as the empty name, data by type and bytes whatever form
# it is written in. A type change is a change.
layer forms1 <<'EOF'
[Software\\Forms]
@="default"
"Expand"=hex(2):61,00,00,00
"Sz"=hex(1):61,00,00,00
"Dw"=hex(4):01,00,00,00
"Multi"=hex(7):61,00,00,00,62,00,00,00,00,00
"Esc"="a\\b"
"Uni"="\x00e9"
"Case"="1"
"Wrapped"=hex:00,01,02,03,04,05,06,07,08,09,0a,0b,0c,0d,0e,0f,10,11,12,13,14,15,16,17,18,19,1a,1b,1c
"TypeChange"="1"
"Retyped"=hex(2):31,00,00,00
"StrColon"=str:"a"
"Spaced"="a"
"ShortDword"=dword:00000001
"HexDigits"=hex:01,02
"\x0386"="old"
"\x0531"="old"
EOF
layer forms2 <<'EOF'
[Software\\Forms]
@="new default"
"Expand"=str(2):"b"
"Sz"="b"
"Dw"=dword:00000002
"Multi"=str(7):"c\0"
"Esc"="new"
"Uni"="new"
"Case"="2"
"Wrapped"=hex:ff
"TypeChange"="2"
"Retyped"="2"
"StrColon"="b"
"Spaced"="b"
"ShortDword"=dword:00000002
"HexDigits"=hex:03
"\x0386"="new"
"\x0531"="new"
EOF
merge forms "$PWD/forms1"
# Wine saves the same values in its own forms; the user changes the type of
# two values (the data stays the same bytes or digits).
hive forms user 'User\\S-1-5-21-0-0-0-1000' <<'EOF'
[software\\FORMS] 1700000000
""="default"
"Expand"=str(2):"a"
"Sz"="a"
"Dw"=dword:00000001
"Multi"=str(7):"a\0b\0"
"Esc"="a\x005cb"
"Uni"="é"
"CASE"="1"
"Wrapped"=hex:00,01,02,03,04,05,06,07,08,09,0a,0b,0c,0d,0e,0f,10,11,12,13,14,15,\
  16,17,18,19,1a,1b,1c
"TypeChange"=dword:00000001
"Retyped"="1"
"StrColon"="a"
"Spaced" = "a"
"ShortDword"=dword:1
"HexDigits"=hex:1 , 2
"\x03ac"="old"
"\x0561"="old"
EOF
merge forms "$PWD/forms2"
cat forms/user.reg
has forms '@="new default"'
lacks forms '""="default"'
has forms '"Expand"=str(2):"b"'
has forms '"Sz"="b"'
has forms '"Dw"=dword:00000002'
has forms '"Multi"=str(7):"c\0"'
has forms '"Esc"="new"'
has forms '"Uni"="new"'
has forms '"Case"="2"'
lacks forms '"CASE"="1"'
has forms '"Wrapped"=hex:ff'
has forms '"TypeChange"=dword:00000001'
has forms '"Retyped"="1"'
# Everything Wine's loader accepts, and its own case mapping (l_intl.nls):
# str:"a" is "a", spaces around =, short dwords and hex bytes, Greek and
# Armenian names that differ only in case.
has forms '"StrColon"="b"'
has forms '"Spaced"="b"'
has forms '"ShortDword"=dword:00000002'
has forms '"HexDigits"=hex:03'
has forms '"\x0386"="new"'
lacks forms '"\x03ac"="old"'
has forms '"\x0531"="new"'
lacks forms '"\x0561"="old"'
test "$(grep -ci '^\[software\\\\forms\]' forms/user.reg)" -eq 1

# A layer's hive can delete what the layers below give: "name"=- a value,
# [-key] that key's values (not its subkeys). Only layers may.
layer dlow <<'EOF'
[Software\\Del]
"Gone"="1"
"Stays"="1"

[Software\\DelKey]
"a"="1"

[Software\\DelKey\\Sub]
"b"="1"
EOF
hive dhigh user 'User\\S-1-5-21-0-0-0-1000' <<'EOF'
[Software\\Del]
"Gone"=-

[-Software\\DelKey]

[Software\\OnlyDeletes]
"nothing"=-
EOF
merge del "$PWD/dlow" "$PWD/dhigh"
has del '"Stays"="1"'
lacks del '"Gone"="1"'
lacks del '"a"="1"'
has del '"b"="1"'
! grep -F 'OnlyDeletes' del/user.reg
! grep -F '=-' del/user.reg del-state/registry-base/user.reg
cp del/user.reg del-before.reg
printf '"Mine"=-\n' >> del/user.reg
cp del/user.reg del-bad.reg
rm del-state/registry-sources
merge del "$PWD/dlow" "$PWD/dhigh" 2> del.log
grep -F 'which only layers may have' del.log
cmp del-bad.reg del/user.reg

# The launcher's integration layer: on a merge without a base record, the
# keys it has come from the layers, not from the writable hive, where
# earlier launchers wrote them (with a store path that may be gone).
layer lbase <<'EOF'
[Software\\Wine\\WineBrowser]
"Browsers"="layer opener"
EOF
hive integration user 'User\\S-1-5-21-0-0-0-1000' <<'EOF'
[Software\\Wine\\WineBrowser]
"Browsers"="/nix/store/new-opener"

[Software\\Classes\\probe]
@="URL:probe Protocol"
"URL Protocol"=""
EOF
hive launched user 'User\\S-1-5-21-0-0-0-1000' <<'EOF'
[Software\\Wine\\WineBrowser] 1700000000
"Browsers"="/nix/store/old-opener"

[Software\\Classes\\probe] 1700000000
@="URL:probe Protocol"
"URL Protocol"=""
"Mine"="kept"

[Software\\Other] 1700000000
"Mine"="kept"
EOF
${registry} merge --launcher-layer "$PWD/integration" "$PWD/launched" launched-state/registry-sources \
  tmp/registry-sources "$PWD/lbase" "$PWD/integration" "$PWD/launched"
has launched '"Browsers"="/nix/store/new-opener"'
has launched '"Mine"="kept"'
test "$(grep -c '"Mine"="kept"' launched/user.reg)" -eq 2
# With the base recorded, the integration layer's values follow it.
sed -i 's|new-opener|newer-opener|' integration/user.reg
rm launched-state/registry-sources
${registry} merge --launcher-layer "$PWD/integration" "$PWD/launched" launched-state/registry-sources \
  tmp/registry-sources "$PWD/lbase" "$PWD/integration" "$PWD/launched"
has launched '"Browsers"="/nix/store/newer-opener"'

touch "$out"
''
