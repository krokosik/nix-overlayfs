# The format generation of a persistent writable layer
# ($XDG_DATA_HOME/<package>), written to <layer>/.nix-overlayfs/state-generation
# by every launch.
#
# Raise it in the same change that makes launchers write the writable layer
# (or its .nix-overlayfs directory) in a way that launchers built before that
# change would misread or damage. A launcher refuses a layer whose generation
# is higher than its own, before it changes anything in it; layers without
# the file (from launchers before it existed) are generation 1.
#
# History:
#   1: the first generation (session.lock, registry and shadow-check
#      signatures, session.pid, open-requests, host-browser-requests).
1
