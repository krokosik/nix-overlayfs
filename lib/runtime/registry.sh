# Usage:
#   nix-overlayfs-registry merge [--launcher-layer DIR] [--case-table FILE] APPDIR SIGNATURE SIGNATURE_NEXT SOURCE...
#   nix-overlayfs-registry upsert-section REGISTRY SECTION TMPDIR < BODY
#   nix-overlayfs-registry string VALUE
#
# merge: the writable layer APPDIR holds the prefix's registry files
# (system.reg, user.reg, userdef.reg), merged from the registry files of the
# Nix layers (SOURCEs, lowest priority first; APPDIR among them is skipped)
# and APPDIR's own. The merge is three-way: registry-base/ next to SIGNATURE
# keeps what the layers gave at the last successful merge, so a value the
# user left as it was follows the layers, and one the user changed, added or
# deleted stays as the user left it (see merge-wine-registries); a base
# record that does not match its manifest fails the merge. DIR, one of the
# SOURCEs, is the launcher's integration layer: on a merge without a base
# record, the keys it has are taken from the layers, not from APPDIR, where
# earlier launchers wrote them at every launch. FILE is the l_intl.nls of
# the Wine the launcher runs: key and value names are compared with its case
# mapping, as Wine compares them. Writes the
# resolved Nix layer paths to SIGNATURE_NEXT and merges again only when they
# differ from SIGNATURE (the last successful merge) or a registry file is
# missing. A failed merge removes SIGNATURE, so the next call merges again;
# it still exits 0, so the launch goes on. The exception is a merge stopped
# in the middle of replacing the hives (its journal is left): that is
# completed first, and if it cannot be, merge exits 1, and the launch must
# not go on, since Wine would write over hives the next launch replaces.
#
# upsert-section: replaces the key SECTION of the Wine registry file REGISTRY
# (for example Software\\Wine\\WineBrowser, with doubled backslashes as in the
# file) with BODY, the key's values in the file's own syntax, and gives it the
# current time. Creates REGISTRY if needed. TMPDIR holds the files it builds.
#
# string: prints VALUE as a quoted registry string value.

usage() {
  echo "usage: nix-overlayfs-registry merge [--launcher-layer DIR] [--case-table FILE] APPDIR SIGNATURE SIGNATURE_NEXT SOURCE... | upsert-section REGISTRY SECTION TMPDIR | string VALUE" >&2
  exit 2
}

merge() {
  local -a launcher_layer=()
  local -a case_table=()
  while [ "$#" -ge 2 ]; do
    case "$1" in
      --launcher-layer) launcher_layer=(--launcher-layer "$2") ;;
      --case-table) case_table=(--case-table "$2") ;;
      *) break ;;
    esac
    shift 2
  done
  [ "$#" -ge 3 ] || usage
  local appdir="$1"
  local signature="$2"
  local signature_next="$3"
  local base=""
  local source=""
  local -a layers=()
  shift 3
  base="$(dirname "$signature")/registry-base"

  for source in "$@"; do
    if [ "$source" != "$appdir" ]; then
      layers+=("$source")
    fi
  done

  for source in "${layers[@]}"; do
    readlink -f "$source" || true
  done > "$signature_next"

  if [ -f "$appdir/system.reg" ] \
    && [ -f "$appdir/user.reg" ] \
    && [ -f "$appdir/userdef.reg" ] \
    && [ -f "$signature" ] \
    && cmp -s "$signature" "$signature_next" \
    && [ ! -e "$base.journal" ]; then
    return 0
  fi

  # A failed merge does not stop the launch (merge-wine-registries reports
  # its own errors), but it is not recorded either: the next launch merges
  # again.
  # merge-wine-registries also completes a merge that was interrupted,
  # replaces the base record and records the signature last.
  if ! merge-wine-registries "${case_table[@]}" --base "$base" --signature "$signature" \
    --signature-next "$signature_next" "${launcher_layer[@]}" "$appdir" "${layers[@]}"; then
    echo "warning: nix-overlayfs: merging the registry of $appdir failed; it is merged again on the next launch" >&2
    rm -f "$signature"
    # A merge stopped after its journal (killed, or a step failed) replaces
    # the writable hives with its staged ones when it is completed, so it is
    # completed now, before Wine writes to them; one stopped before leaves
    # staged files, which are removed.
    merge-wine-registries --recover "$base" "$appdir" || true
    if [ -e "$base.journal" ]; then
      echo "error: nix-overlayfs: an interrupted registry merge of $appdir cannot be completed (see above); not starting, since Wine would write over registry files it still has to replace" >&2
      return 1
    fi
  fi
}

upsert_section() {
  local registry="$1"
  local section="$2"
  local tmpdir="$3"
  local body_file="$tmpdir/nix-overlayfs-user-reg-body.$$"
  local next_registry="$tmpdir/nix-overlayfs-user-reg.$$"

  cat > "$body_file"
  mkdir -p "$(dirname "$registry")"

  if [ -f "$registry" ]; then
    NIX_OVERLAYFS_USER_REG_SECTION="[$section]" awk '
      BEGIN { section = ENVIRON["NIX_OVERLAYFS_USER_REG_SECTION"] }
      /^\[/ { skip = ($0 == section || substr($0, 1, length(section) + 1) == section " ") }
      !skip { print }
    ' "$registry" > "$next_registry"
  else
    printf '%s\n\n' 'WINE REGISTRY Version 2' > "$next_registry"
  fi

  {
    printf '\n[%s] %s\n' "$section" "$(date +%s)"
    cat "$body_file"
  } >> "$next_registry"

  mv "$next_registry" "$registry"
  rm -f "$body_file"
}

registry_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

case "${1:-}" in
  merge)
    [ "$#" -ge 4 ] || usage
    shift
    merge "$@"
    ;;
  upsert-section)
    [ "$#" -eq 4 ] || usage
    upsert_section "$2" "$3" "$4"
    ;;
  string)
    [ "$#" -eq 2 ] || usage
    registry_string "$2"
    ;;
  *)
    usage
    ;;
esac
