# Usage: nix-overlayfs-host-browser-broker REQUEST_DIR OPENER [WATCH_PID]
#
# Opens the web pages a Windows application asks for in the host's browser.
# Wine's browser hook and the start.exe shim write each URL to a file
# REQUEST_DIR/request.* (written as *.tmp first and renamed). This program
# claims every finished request, runs OPENER --direct URL for it, and polls
# for new ones until REQUEST_DIR/.stop exists or process WATCH_PID (the
# session's runtime supervisor) is gone; then it handles what is left once
# more and exits. Browsers it started keep running.
#
# It runs with the caller's PATH unchanged (no runtime inputs), so the
# browser it starts sees the user's environment.

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: nix-overlayfs-host-browser-broker REQUEST_DIR OPENER [WATCH_PID]" >&2
  exit 2
fi

request_dir="$1"
opener="$2"
watch_pid="${3:-}"

session_runs() {
  [ ! -e "$request_dir/.stop" ] || return 1
  [ -z "$watch_pid" ] || kill -0 "$watch_pid" 2>/dev/null
}

process_requests() {
  local processing_file=""
  local request_file=""
  local target_url=""

  mkdir -p "$request_dir" || true
  for request_file in "$request_dir"/request.*; do
    [ -f "$request_file" ] || continue
    case "$request_file" in
      *.tmp | *.processing.*)
        continue
        ;;
    esac

    processing_file="$request_file.processing.$$"
    if ! mv "$request_file" "$processing_file" 2>/dev/null; then
      continue
    fi

    target_url="$(cat "$processing_file" 2>/dev/null || true)"
    rm -f "$processing_file"
    [ -n "$target_url" ] || continue

    if ! "$opener" --direct "$target_url"; then
      echo "warning: failed to open URL with host browser: $target_url" >&2
    fi
  done
}

while session_runs; do
  process_requests
  sleep 0.2
done
process_requests
