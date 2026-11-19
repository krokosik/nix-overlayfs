# Usage:
#   nix-overlayfs-state describe-holder STATE_DIR
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

usage() {
  echo "usage: nix-overlayfs-state describe-holder STATE_DIR" >&2
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

case "${1:-}" in
  describe-holder)
    [ "$#" -eq 2 ] || usage
    describe_holder "$2"
    ;;
  *)
    usage
    ;;
esac
