# Maintainer: Conroy Cheers <conroy@corncheese.org>
# Based on original work by Libor Štěpánek 2025
{
  writeShellScriptBin,
  jq,
  gnused,
}:
writeShellScriptBin "json2reg" ''
  # json2reg [--deletions] IN.json OUT.reg
  #
  # convert JSON to the .reg structure. Nulls (keys and values a JSON merge
  # patch deletes) are dropped; with --deletions they are written as a
  # layer's deletions instead, [-key] for a key, "name"=- for a value and
  # #-link for a key's symbolic-link flag (see merge-wine-registries).
  if [ "$1" = --deletions ]; then
    shift
    ${jq}/bin/jq --raw-output '"WINE REGISTRY Version \(.version)\n;; All keys relative to \(.location)\n\n#arch=\(.arch)\n",((.keys // {}) | to_entries[] | if .value == null then ("[-\(.key)]", "") else ("[\(.key)]", (if .value.__wine_link == "1" then "#link" elif (.value | has("__wine_link")) then "#-link" else empty end), (.value | to_entries[] | select(.key != "__wine_link") | if .value == null then "\(.key)=-" else "\(.key)=\(.value)" end), "") end)' < "$1" > "$2"
  else
    ${jq}/bin/jq --raw-output 'del(..|nulls) | "WINE REGISTRY Version \(.version)\n;; All keys relative to \(.location)\n\n#arch=\(.arch)\n",(.keys | to_entries[] | ("[\(.key)]", (if .value.__wine_link == "1" then "#link" else empty end), (.value | to_entries[] | select(.key != "__wine_link") | ("\(.key)=\(.value)")), ""))' < "$1" > "$2"
  fi

  # remove empty line at the end of the file
  ${gnused}/bin/sed -i '$ d' "$2"
''
