# Usage:
#   nix-overlayfs-state describe-holder STATE_DIR
#   nix-overlayfs-state check-generation STATE_DIR GENERATION LAUNCHER
#
# Keeps track of who uses a writable layer. STATE_DIR is the layer's
# .nix-overlayfs directory.
#
# Only one session uses a writable layer at a time. The launcher opens
# STATE_DIR/session.lock and takes an exclusive flock(2) on it before it
# changes anything in the layer, writes its process id into the file, and
# keeps the lock until the session has ended and its prefix is unmounted.
# The descriptor is not inherited by the session's processes, so nothing
# that is left over from a session can keep the layer locked.
#
# describe-holder: prints who holds the lock, for the message a second launch
# shows: the process id written into session.lock and its command line, or
# that it has exited (the runtime supervisor still holds the lock while the
# session shuts down).
#
# check-generation: STATE_DIR/state-generation holds the format generation of
# the writable layer (first line), the launcher that wrote it (second line)
# and when (third line). A launcher of generation GENERATION (LAUNCHER: its store path)
# refuses a layer of a higher generation, which a newer launcher wrote and it
# could damage: it prints why, with both launchers, and exits 1. Otherwise it
# records GENERATION and LAUNCHER; a layer without the file is accepted. The
# launcher calls it while it holds the session lock, before it changes
# anything else in the layer.

usage() {
  echo "usage: nix-overlayfs-state describe-holder STATE_DIR | check-generation STATE_DIR GENERATION LAUNCHER" >&2
  exit 2
}

command_line() {
  local pid="$1"
  local cmdline=""

  [ -r "/proc/$pid/cmdline" ] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || return 1
  cmdline="${cmdline% }"
  [ -n "$cmdline" ] || return 1
  printf '%s\n' "$cmdline"
}

describe_holder() {
  local state_dir="$1"
  local pid=""
  local cmdline=""

  pid="$(head -n 1 "$state_dir/session.lock" 2>/dev/null || true)"
  case "$pid" in
    '' | *[!0-9]*)
      echo "an unknown process"
      return 0
      ;;
  esac

  if cmdline="$(command_line "$pid")"; then
    printf 'process %s (%s)\n' "$pid" "$cmdline"
  else
    printf 'process %s, which has exited; its session is still shutting down\n' "$pid"
  fi
}

check_generation() {
  local state_dir="$1"
  local generation="$2"
  local launcher="$3"
  local marker="$state_dir/state-generation"
  local found=""
  local writer=""
  local written=""

  case "$generation" in
    '' | *[!0-9]*) usage ;;
  esac

  if [ -e "$marker" ]; then
    {
      read -r found || true
      read -r writer || true
      read -r written || true
    } < "$marker" || true
    case "$found" in
      '' | *[!0-9]*)
        echo "error: nix-overlayfs: $marker is not a state generation; this launcher ($launcher, state generation $generation) does not know what wrote it. Move it aside only if no newer package uses this writable layer." >&2
        return 1
        ;;
    esac
    if [ "${#found}" -gt 9 ] || [ "$((10#$found))" -gt "$generation" ]; then
      echo "error: nix-overlayfs: the writable layer $(dirname "$state_dir") has state generation $found (written by ${writer:-an unknown launcher}${written:+ on $written}); this launcher ($launcher) only knows generation $generation and could damage it. Start the newer package instead." >&2
      return 1
    fi
    if [ "$((10#$found))" = "$generation" ] && [ "$writer" = "$launcher" ]; then
      return 0
    fi
  fi

  printf '%s\n%s\n%s\n' "$generation" "$launcher" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker.$$"
  mv -f "$marker.$$" "$marker"
}

case "${1:-}" in
  describe-holder)
    [ "$#" -eq 2 ] || usage
    describe_holder "$2"
    ;;
  check-generation)
    [ "$#" -eq 4 ] || usage
    check_generation "$2" "$3" "$4"
    ;;
  *)
    usage
    ;;
esac
