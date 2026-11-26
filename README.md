# nix-overlayfs

*Composable, reproducible overlay-based packaging for Wine applications*

## Usage

An example package definition is located in `apps/notepad-plus-plus`:

```
nix run .#notepad-plus-plus
```

The flake also exposes the packaged app itself, so you can build it directly:

```
nix build .#notepad-plus-plus
```

The top-level flake surface is intentionally narrow:

- `packages.<system>` contains only buildable derivations
- `apps.<system>` contains only schema-valid flat app entries

The richer internal package set is exposed through:

```text
legacyPackages.<system>.nix-overlayfs
```

That internal package set contains:

- `packages`: the flat default derivation set mirrored into the flake `packages` output
- `apps`: the flat default app set mirrored into the flake `apps` output
- `moduleScopes`: runtime/module scopes such as `nativeModules` and `x64FexModules`;
  `makeNativeModules` constructs the same module set from custom Wine/runtime
  arguments
- `packageVariants`: namespaced derivation variants such as `x64Fex.notepad-plus-plus`
- `appVariants`: namespaced app variants with the same runtime split

If you consume this repository as an overlay, the same package set is available
as:

```text
pkgs.nix-overlayfs
```

Each of these modules can be used as an install-time (see `lib.mkWindowsPackage`)
or runtime (see `lib.composeWindowsLayers`) dependency for other modules or applications;
each module serves a purpose similar to each of [Winetricks](https://github.com/Winetricks/winetricks)' verbs.
This module-based approach provides an advantage over the traditional Winetricks + prefix-per-application,
in that each module is a self-contained overlayfs and can thus be shared between multiple application
prefixes, saving on build/install time and disk space.

`runtime.mkSession` exposes `commands.wine`, `commands.wineserver`,
`commands.wineboot`, and `commands.winecfg` as the stable execution surface.
`commands.wine64` is optional; on `wow64` runtimes it aliases the main `wine`
launcher instead of a separate `bin/wine64` path.

For runtime wrappers that need host graphics bootstrap, the library also exposes
`overlayfsLib.mkGraphicsBootstrap`. It returns an `extraPreLaunchCommands`
fragment that leaves host graphics discovery untouched by default and supports
an explicit `NIX_OVERLAYFS_GRAPHICS_STACK=system` override for hosts that
surface their GL/EGL/Vulkan stack via `/run/opengl-driver`.

## Runtime namespace modes

Runtime wrappers default to `namespaceMode = "auto"`. They use isolated user
and mount namespaces when the required `unshare` operation succeeds. If the
host denies unprivileged user namespaces, as Ubuntu 24.04 does by default, the
wrapper falls back to a direct rootless `fuse-overlayfs` mount and prints a
warning explaining why.

Callers can set `namespaceMode` to `"required"` to reject that fallback or to
`"direct"` to avoid the namespace probe. Users can override the packaged mode
at runtime with `NIX_OVERLAYFS_NAMESPACE_MODE=auto|required|direct`.

Direct mode keeps its mount under the user's private nix-overlayfs temporary
directory and performs the normal explicit FUSE unmount and temporary-directory
cleanup. It does not disable host AppArmor or user-namespace policy.
Without a user namespace the mount goes through the setuid `fusermount3`,
which NixOS installs only with `programs.fuse.enable = true` (opt-in since
NixOS 26.11); if the mount fails, the launcher stops with an error.

## Runtime process supervision

Each runtime session is launched below a dedicated Linux child subreaper. When
the application session ends, nix-overlayfs first asks Wine to shut down
cleanly, then terminates and reaps only processes descended from that session
before unmounting its prefix. This contains double-forked and native helper
processes without selecting processes globally by command line or environment.

In namespace mode the session, including the package's
`extraPreLaunchCommands` and any services they start in the background, also
runs in its own PID namespace (with its own `/proc`), whose init is the
runtime supervisor. When that init exits, or is killed (it gets `SIGKILL` when
the outer supervisor dies), the kernel kills every process left in the
namespace, so nothing of a session can outlive it. If the namespace cannot be
set up, the supervisor says so and supervises the session as in direct mode.
`.nix-overlayfs/session.pid` records the init's process id as seen from
outside, so other launchers still find the running session.

Direct mode has no PID namespace. There, every process of a session carries
the session's own id in `NIX_OVERLAYFS_SESSION_ID`, and when the supervisor
was killed itself, the launcher terminates the processes that carry it (only
those) before unmounting. A launcher killed together with its supervisor
(`SIGKILL` to both) leaves them running.

`processTerminationTimeout` controls the grace period between `SIGTERM` and
`SIGKILL` and defaults to 5 seconds. It is accepted by `mkOverlayfsPackage`,
`composeWindowsLayers`, `mkWindowsPackage`, and `mkWinpkgsPackage`. The runtime
override `NIX_OVERLAYFS_PROCESS_TERMINATION_TIMEOUT` accepts a non-negative
duration with an optional `ms`, `s`, `m`, `h`, or `d` suffix.

Web pages that Wine asks the host to open (Wine's browser hook and the
`start.exe` shim) go through a broker that runs next to the session, outside
its namespaces. It ends with the runtime supervisor, so a launcher that is
killed (and cannot stop it) does not leave it running; browsers it started
keep running.

Host browser requests use a separate transient user service with
`ExitType=cgroup`, so asynchronous browser startup and URL-forwarding processes
can finish after `xdg-open` exits. The service remains active until its remaining
processes exit, which can include the browser's lifetime. This service mode needs
systemd 250 or newer; if the service cannot be started, the URL opener uses its
existing detached-process fallback.

## Persistent runtime state

A persistent runtime keeps its writable layer in
`$XDG_DATA_HOME/<packageName>` (by default `~/.local/share/<packageName>`),
mounted above the read-only Nix layers. Files in the writable layer always win,
so the launcher guards against changes that would hide newer Nix layers after
a rebuild.

### One session per writable layer

Before it changes anything in the writable layer (merging the registry, the
overlay work directory, the shadowed-files check, the mount), a launch takes an
exclusive `flock` on `<writable layer>/.nix-overlayfs/session.lock`. Creating
that file (and its directory) is the only change made before the lock is
held; the launch then checks the [state generation](#state-generation) and
only after that writes its process id into the file. The lock is taken with
up to a second of waiting, since URL forwarders test it briefly. The runtime
supervisor keeps the lock until the
session has ended and its prefix is unmounted. The descriptor is closed for
every process of the session (close-on-exec), so a process left over from a
session cannot keep the layer locked.

A second launch while the lock is held changes nothing and exits with status
75, naming the holder:

```
error: nix-overlayfs: <package> already runs from <writable layer>: process 1234 (<command line>)
```

URLs never take the lock; see [URL schemes](#url-schemes) for how they reach a
session that is starting, running or closing.

This is the only session lock a package needs. Packages that took a lock of
their own in `extraPreLaunchCommands` (often also called `session.lock`) to
keep two sessions apart should drop it: it came too late (after the registry
merge and the mount), and its descriptor was inherited by Wine, so a leftover
Wine process kept it.

### State generation

An older build of a package run against a writable layer that a newer build
already used could misread or damage it. The launcher therefore keeps the
layer's format generation in `.nix-overlayfs/state-generation` (the
generation, the launcher's store path and when it wrote the file). A launch
whose own generation (`overlayfsLib.stateGeneration`, defined in
`lib/state-generation.nix`) is lower refuses the layer, right after taking the
session lock and before it changes anything else, and exits 1:

```
error: nix-overlayfs: the writable layer <layer> has state generation 2 (written by /nix/store/...-<package>-overlay-<version> on <date>); this launcher (/nix/store/...) only knows generation 1 and could damage it. Start the newer package instead.
```

URL forwarding checks the generation too, before it writes anything: a
launcher does not hand a URL to the session of a layer with a newer
generation (`--nix-overlayfs-open-url` and `--nix-overlayfs-forward-url` exit
1).

Layers without the file (from launchers before it existed) are accepted and
get it; a lower or equal generation is accepted and recorded. The generation
is raised in the same change that makes launchers write the layer in a way
older launchers cannot handle; `lib/state-generation.nix` keeps its history.
It covers nix-overlayfs's own state. A package whose own state format changes
incompatibly (files its hooks write into the layer) needs nix-overlayfs's
generation raised in the same change, or a guard of its own.

The protection has limits: launchers built before the guard existed do not
check the file and can still damage a newer layer, and the guard only
compares generations, so a format change made without raising it is not
caught.

### Wine prefix updates

Wine updates a prefix (wineboot's `PreInstall`, `DefaultInstall` and
`Wow64Install`) when `.update-timestamp` is missing or does not match its
`wine.inf`. In a layered prefix that update rewrites every builtin DLL into the
writable layer, where the copies then hide the Nix layers for good, including
native DLLs such as DXVK's `d3d11.dll`. The launcher's
[integration layer](#integration-layer) therefore has a `.update-timestamp`
that says `disable`, which stops wineboot's automatic update (`programs/wineboot/wineboot.c`,
`update_timestamp()`). It does not stop an explicit `wineboot -u` or a program
that runs `wine.inf`'s sections itself. Prefix contents come from the Nix
layers; a Wine change that needs new prefix contents belongs in a rebuilt
base environment.

Before mounting, the launcher removes a `.update-timestamp` from the writable
layer, where it would hide the marker (launchers from before the integration
layer wrote the marker there), and a whiteout of it in either form
fuse-overlayfs reads (a `.wh..update-timestamp` file, or `.update-timestamp` as
a 0/0 character device). A writable root that is opaque hides every layer and is
reported. After mounting, the launcher checks that the prefix's
`.update-timestamp` says `disable`, and stops with an error instead of starting
Wine if it does not. Set `NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1` to restore
Wine's default behaviour for a launch: the writable layer then gets the
timestamp of the highest Nix layer without the marker (an empty one if none
has a timestamp), and the next launch without the variable removes it again.

### Integration layer

What the launcher itself puts into the prefix comes from a small layer
generated with the launcher (`passthru.integrationLayer`), mounted above the
package's layers and merged into the registry with them, so the writable
layer holds only what the application and the user write:

- `.update-timestamp` with `disable` (see above);
- with host integration, the `start.exe` shim in `system32` and `syswow64`;
- with host integration in a Wine package, a `user.reg` with the host URL
  opener (`HKCU\Software\Wine\WineBrowser`) and the package's declared
  `urlSchemes` (`HKCU\Software\Classes\<scheme>`, opening `executablePath`,
  when that lies below `drive_c`).

The layer changes with the launcher only, so a rebuilt launcher (another
opener store path, another scheme) reaches existing users through the
[registry merge](#registry). Its `user.reg` has only these keys, so it masks
no other layer's values. On the first merge without a base record, the values
that these keys have in the writable layer are taken as unchanged (earlier
launchers wrote them there at every launch), so the layer's values win. Copies of the shim
that earlier launchers left in the writable layer are removed before mounting.

What a launch still writes into the writable layer: the merged registry
itself (Wine needs complete hives; the values that came from the layers
follow them, see [Registry](#registry)), and the registry entries of URL
schemes that only `urlSchemeDiscoveryCommands` finds at launch, or of all
schemes when `executablePath` is not below `drive_c` (its Windows path
depends on the session's mount point). Hooks that call
`nix_overlayfs_upsert_user_reg_section` write there too;
`nix_overlayfs_configure_host_browser` and `nix_overlayfs_remove_start_shim`
are kept so that existing hooks still work, but they do nothing now.

### Registry

Wine keeps the registry in the writable layer's `system.reg`, `user.reg` and
`userdef.reg`, and saves the whole registry there, including every value
that came from the Nix layers. Whenever the set of Nix layers changes (or a
hive is missing), the launcher merges these hives again before mounting
(`nix-overlayfs-registry merge`, `merge-wine-registries`). The merge is
three-way: `.nix-overlayfs/registry-base/` holds what the layers gave at the
last successful merge (the layers' hives merged, lowest priority first,
without the writable layer). For each value:

| Writable hive | Base record | Result |
| --- | --- | --- |
| same type and data as the base | has it | the layers' value now, or none if they dropped it |
| has it | lacks it, or has another type or data | the writable value (the user or the application changed or added it) |
| lacks it | has it | none (the user deleted it) |
| lacks it | lacks it | the layers' value, if any |

So a value that the user never touched follows the layers when a rebuilt layer
changes, adds or removes it, and a value that the user changed stays.

Keys and values are matched as Wine matches them: key paths and value names
without regard to case, with the case mapping of the Wine the launcher runs
(its `l_intl.nls`, the table wineserver itself uses; `mkWindowsPackage` and
`composeWindowsLayers` pass it as `registryCaseTable`, and without it only
ASCII letters are matched without case), `@` as the empty name, escapes
decoded as Wine decodes them. Values are compared by type and data, read as
Wine's registry loader reads them (`get_data_type` and `load_value` in
`server/registry.c`): `"a"`, `str:"a"` and `hex(1):61,00,00,00` are the same
`REG_SZ`; `str(2):"a"` and `hex(2):61,00,00,00` are the same `REG_EXPAND_SZ`
(Wine saves terminated strings in string form); `dword:1`, `dword:00000001`
and `hex(4):01,00,00,00` the same `REG_DWORD`; spaces around `=` and between
hex bytes, and where long hex values are broken over lines, do not matter.
Text Wine would not load is compared as it is. A
different type is a different value, so `REG_SZ` `"1"` and `REG_DWORD` `1`
differ. The merged hive keeps the text of the side that won. A key without values follows the
same rules: a key that the user deleted stays deleted, and a key that the layers
no longer have is removed unless the user created it. A key that the user deleted
comes back if a layer adds a new value to it. A hive missing from the writable layer is taken
from the layers as it is.

A writable layer from before the base record is merged as before, with the
writable values on top, and gets a base record. Values it shares with the
layers then follow the next layer change; values that differ stay the user's.

The base record has a `manifest` naming the size and hash of each of its hives
(or that the layers had none) and the Nix layers it was made for. A record
that does not match its manifest (truncated, changed, or without manifest) fails
the merge: taking it for no record would make every packaged value the user's.
Delete `.nix-overlayfs/registry-base` to merge once with the writable values on
top and record it anew.

A record made for other layers than the signature names (the layers of the last
merge: a launcher without base records merged in between, or the record comes
from another state) does not say what the writable hives got from the layers,
and is not trusted. It is rebuilt from the layers the signature names, which are
store paths and exist as long as a package that uses them does: a value that
older merge brought in follows the layers from now on, and a value it kept from
the writable layer over its layers stays the user's, as it was for that launcher.
If one of those layers is gone, the history is unknown and the merge goes as
without a record, in the direction that loses nothing of the user's: the
writable values win once, and the record is made anew. Both cases print a
warning. Without a signature (the last merge failed) the record is the last
successful merge's and is used.

A hive that cannot be read or parsed fails the merge before anything is
written. Every new hive and the new base record
(`.nix-overlayfs/registry-base.new`) are staged and read back first. The commit
then removes the layer signature (`.nix-overlayfs/registry-sources`), writes a
journal (`registry-base.journal`), moves the hives and the base record into
place, removes the journal and writes the signature last. A merge stopped
before the journal exists leaves the old hives and base, and what it staged
is dropped; one stopped after it is completed, before anything else. Both
happen right after a failed merge, in the same launch, and again at the
start of the next merge (for a launcher that was killed). A launch never
starts Wine while a journal is left: Wine would save to hives that
completing the merge then replaces. If the merge cannot be completed, the
launch stops with an error. Otherwise a failed merge keeps the old base, has
no signature and lets the launch go on; the next launch merges again. Delete
`.nix-overlayfs/registry-sources` to merge on the next launch anyway.

Layers hold only their own changes (see [Registry of a layer](#registry-of-a-layer)),
so a setting in a lower layer is not masked by a layer above that does not
touch it.

Package settings belong in a layer (a `mkFileLayer`'s
`registryDllOverrides`, or a layer whose build writes the registry). Do not
write them into the writable layer at every launch with `wine reg add` in
`extraPreLaunchCommands`: such values become the user's and no longer follow
the package, and the state is no longer reproducible from the layers. Once a
setting is in a layer, a package update reaches existing users, unless they
changed that value themselves.

### Files hiding the Nix layers

Whenever the set of Nix layers changes (and on the first launch with this
check), the launcher compares the writable layer's `drive_c/windows` with the
layers below before mounting. A writable file "hides" a layer file only if the
mounted prefix would show that layer file without it: the path is resolved
through the layers as overlayfs does, so whiteouts (`.wh.<name>` files or 0/0
character devices), opaque directories (`.wh..wh..opq` or an opaque xattr, in
the writable layer also above `drive_c/windows`) and non-directory entries end
the lookup. A hiding file is handled according to
`NIX_OVERLAYFS_SHADOWED_FILES`:

- `prune-builtin` (default): Wine builtin modules (winebuild's
  `Wine builtin DLL` signature at offset 0x40), typically left by an earlier
  prefix update, and copies identical to the file they hide (which would hide
  that file's next change) are moved aside; other files are kept and reported.
- `prune`: every hiding file is moved aside.
- `warn`: only report.
- `ignore`: skip the check.

Nothing is deleted: moved files are kept in
`<writable layer>/.nix-overlayfs/shadowed/<time>/`, and the latest report is
`.nix-overlayfs/shadowed-files` (`moved` or `hides`, kind, path, layer). The
scan and every decision come before the first move; if a directory or an
xattr cannot be read, nothing is moved and the check runs again on the next
launch. Delete `.nix-overlayfs/shadow-check-sources` to run it on the next
launch anyway.

### Session directories

Each launch mounts its prefix in its own directory, `tmp.*` below
`$XDG_CACHE_HOME/nix-overlayfs/tmp` (or `$XDG_RUNTIME_DIR/nix-overlayfs` for
ephemeral runtimes), and removes it when the session ends. A launcher that is
killed cannot clean up. Each launch therefore holds an exclusive `flock` on its
directory's `session.lock`; the descriptor is inherited by every process of
the session, in any mount namespace, so the lock is released only when the
last of them exits. Holding a lock on the base directory itself, each launch creates
and locks its own directory and removes the directories whose lock is free
and that have nothing mounted below them. Directories without `session.lock`
(left by launchers before this) are never removed automatically; delete them
by hand once no session of that application runs.

## URL schemes

A package's `urlSchemes` (plus anything `urlSchemeDiscoveryCommands` prints)
are registered in two places:

- in the Wine prefix (`HKCU\Software\Classes\<scheme>`), so Windows programs
  can open them: declared schemes by the
  [integration layer](#integration-layer), schemes found at launch by the
  launch;
- on the host, unless `registerHostUrlHandlers = false`: a hidden
  `<executableName>-nix-overlayfs-url-handler.desktop` in
  `$XDG_DATA_HOME/applications`, made the user's default with `xdg-mime`.

The host handler calls the launcher with `--nix-overlayfs-open-url URL`. If a
session of the package is running, the URL is handed to it
(`urlSchemeOpenCommands`); otherwise the application starts with the URL.
`--nix-overlayfs-forward-url URL` only hands the URL to a running session,
without starting anything; a dispatcher can use it to find the right
application when several share a scheme.

A session goes through three phases, recorded in
`.nix-overlayfs/session-state` (its id, then the phase): `starting` from when
it holds the session lock until the package's `extraPreLaunchCommands` have
run, `ready` while the application runs, and `closing` from when the
application has exited (or the launcher is cleaning up) until the lock is
free. Only a `ready` session takes URLs, from a queue of its own
(`.nix-overlayfs/open-requests/<session id>/`). A URL is published by
writing it to a hidden file in that queue and renaming it to `request.*`, so
the session never sees a partial request, and the launcher that forwards it
waits until the session has taken it. Taking it means a positive
acknowledgment: the session writes its id to
`.nix-overlayfs/open-acks/<request token>`, and the forwarder accepts only an
acknowledgment from the session it handed the URL to. A request that merely
disappears (removed with the queue of a session that ended, when the next one
starts) is not delivered; the forwarder goes on with the next session. If the
session starts closing first,
the forwarder takes the URL back; a URL is never left for a session that is
over, and a new session starts with an empty queue (queues of earlier
sessions are removed).

While the session is starting or closing, both options wait for it, up to
`NIX_OVERLAYFS_URL_FORWARD_WAIT` seconds (default 30, `0` to not wait): when
it becomes ready the URL is handed to it; when it is over (the lock is free),
`--nix-overlayfs-open-url` starts a new session with the URL and
`--nix-overlayfs-forward-url` reports that the session ended (5). Status 3
means only that no session was there when the command started.

Exit status of both options:

| Status | Meaning |
| --- | --- |
| 0 | The running session took the URL. (`--nix-overlayfs-open-url` that started a new session exits with that session's status.) |
| 1 | The writable layer has a newer [state generation](#state-generation); nothing was written. (Also other errors.) |
| 2 | The URL is missing. |
| 3 | `--nix-overlayfs-forward-url` only: no session of this layer was there when the command started. Try the next application. |
| 4 | A session is starting or closing and did not become ready (or did not take the URL) within the wait; the URL was taken back. Try again later, do not fall through to another application. |
| 5 | `--nix-overlayfs-forward-url` only: a session of this layer was there (starting, ready or closing) when the command started, but ended before it took the URL; the URL was taken back. The URL belongs to this application: start it with the URL (for example with `--nix-overlayfs-open-url`), do not try the next one. |
| 75 | Not these options: a normal launch while a session runs (below). |

A normal launch (without these options) while a session runs exits 75 (see
[One session per writable layer](#one-session-per-writable-layer)).

Set `registerHostUrlHandlers = false` (accepted by `mkOverlayfsPackage`,
`composeWindowsLayers`, `mkWindowsPackage` and `mkWinpkgsPackage`) when the
host declares the handler itself, for example a NixOS or home-manager module
with a `.desktop` file and `xdg.mime.defaultApplications`. Otherwise the
launcher's per-user default (in `~/.config/mimeapps.list`) takes precedence
over the system's. With the option off, a launch also removes the handler
entries earlier launches of the same state directory wrote, under any
executable name, and their defaults in the user's `mimeapps.list` files
(symlinked lists, such as home-manager's, are left alone).

The generated `open-url` script calls the package that wrote it and, once that
store path was garbage collected, the launcher of the same name on `PATH`.

## Headless and ephemeral runtimes

`composeWindowsLayers` can produce a one-shot, non-interactive runtime for CLI
programs:

```nix
overlayfsLib.composeWindowsLayers {
  # ...runtime, base layer, and executable arguments...
  hostIntegration = false;
  managedRuntime = "disabled";
  stateMode = "ephemeral";
}
```

`hostIntegration = false` omits browser brokerage, URL/desktop registration,
and the host `start.exe` shim. URL scheme options are rejected in this mode.
`managedRuntime = "disabled"` uses a base environment without Wine Mono and
disables Wine's `mscoree` and `mshtml` loaders, preventing interactive Mono or
Gecko installation prompts. `stateMode = "ephemeral"` places the writable
prefix, XDG data, and XDG cache below a per-invocation temporary directory and
removes it after the command exits.

`managedRuntime = "external"` uses a base environment without Wine Mono but
leaves `mscoree` enabled, for prefixes that get .NET from a layer such as
`dotnet-framework-4-8`. That layer, and every package built with
`managedRuntime = "external"`, declares `passthru.requiredManagedRuntime =
"external"`; `mkWindowsPackage` and `composeWindowsLayers` refuse a layer with
that requirement anywhere in the dependency closure (following
`overlayDependencies`) unless the package itself uses `"external"`, since
such layers were built on a base that never had Wine Mono. Layers built on the
`"auto"` and `"disabled"` bases are not checked against each other.

On `x86_64-linux`, `moduleScopes.nativeWin32HeadlessModules` pairs these options
with the lean `winePackages.stable` Win32 runtime. Desktop applications should
continue using `nativeWin32Modules`, whose existing persistent and integrated
behavior remains the default.

## Build namespace modes

`mkWindowsPackage` defaults to `buildNamespaceMode = "auto"`. It uses the
kernel overlay build when user and mount namespaces are available. Otherwise,
it materializes the prepared prefix, runs the installer as the normal Nix build
user, and uses `rsync --compare-dest` to retain the resulting layer delta. This
supports Ubuntu's default AppArmor policy without changing host configuration.

Package definitions can select `"required"` to require the namespace build or
`"direct"` to always use the materialized build.

For native Wine installers that create directory junctions or symbolic links,
set `portableReparsePoints = true;`. Nix builds may deny writes to extended
attributes, and NAR archives do not preserve Wine's `user.WINEREPARSE`
metadata. This option stores only directory reparse records inside the build's
Wine prefix as temporary sidecar files and converts them to relative Unix
symlinks before collecting the layer. It automatically selects a materialized
build because kernel overlayfs can reject Wine's directory rename with
`EXDEV`; it cannot be combined with `buildNamespaceMode = "required"`.

A custom `unshareInstall` callback can call
`${session.commands.normalizeReparsePoints} "$WINEPREFIX"` before native Linux
tools need to follow installer-created links. Stop the relevant Wine processes
before normalizing links they still use. The adapter is scoped to installation;
it does not change host xattr policy or the runtime environment. Targets outside
drive C, targets escaping the prefix, unsupported reparse types, and nonempty
placeholder directories fail normalization rather than being discarded.

## Windows layer contract

A Windows layer contains every entry directly below its `basePackage` root,
including dotfiles. Producers and consumers must therefore move or copy the
directory contents rather than using a `*` glob. Wine's generated
`.update-timestamp` belongs to the base-environment layer; application delta
layers deliberately omit that runtime-owned control file while retaining any
other hidden files created by their installers.

An installation built with `mkWindowsPackage` starts from its dependencies'
layers: for a dependency that is itself a package (it has
`passthru.basePackage`), that layer derivation, not the launcher around it.
Changes that only affect launchers (environment, DLL overrides, URL handling,
the launcher scripts of this library) therefore do not rebuild dependent
installations.

### Registry of a layer

A layer's `system.reg`, `user.reg` and `userdef.reg` hold only what it
changes against the layers below it, not complete hives. The base environment
is the exception: it is the bottom layer and has the complete hives. An
installation built with `mkWindowsPackage` captures its hives as the
difference between the registry Wine saved after the installer and the hive
its dependencies compose to: the keys and values it added or changed, and
what it deleted, written as `"name"=-` (a value), `[-key]` (that key's
values, not its subkeys) and, in a key, `#-link` (its symbolic-link flag; `#-class`
removes a key's class the same way). `HIVE.json` holds the same difference as a JSON
merge patch (deletions as `null`), which dependent builds compose on.

At launch the layers' hives are merged in launch order, lowest priority
first: each value comes from the highest layer that sets it, and a deletion
removes what the layers below gave. So a layer above (an application) does
not mask a setting of a layer below (a configuration layer) that it did not
change itself. (When layers held complete hives, the layer above carried the
base environment's value and overrode the layer below.)

Values the capture leaves out of a layer (installation dates, paths of
temporary directories, `lib/diffs`) are left out on both sides, so they are
not taken for deletions; nor is a key of the dependencies that has subkeys
but no values, which Wine does not write. Deletions are for layers only: a
writable hive that contains one fails the merge. Hand-written layer hives (for
example `mkFileLayer`'s) contain just their own keys and values.

## Installing and launching with different Wine builds

`mkWindowsPackage` and `composeWindowsLayers` take `runtime`, the Wine that
builds the layers and the base environment, and `launchRuntime` (default:
`runtime`), the Wine the launcher runs. Building with a released Wine and
launching with a patched build of it lets patches be tried without rebuilding
any layer: changing `launchRuntime` rebuilds only the launcher.

```nix
overlayfsLib.mkWindowsPackage {
  runtime = releaseModules.runtime;      # builds base environment and layers
  launchRuntime = patchedModules.runtime; # runs the application
  # ...
}
```

Wine loads a builtin module from its own installation when the file in the
prefix is a builtin copy (`load_builtin()` in `dlls/ntdll/unix/loader.c`:
builtin first, the prefix file as fallback), and the launcher keeps wineboot
from updating the prefix automatically. So code changes in the launch Wine's
existing modules take effect. Prefix contents do not change: registry keys and
files that only `wine.inf` creates, modules the launch Wine adds (not in the
prefix) or removes (the old prefix copy is used, or nothing for a fake DLL).
The two Wines must therefore produce the same prefix, which this library
cannot determine. It compares the runtimes' `prefixCompatibility` (the Wine
package's `passthru.prefixCompatibility`, or else its upstream release) and
Windows architecture, and fails evaluation if they differ. A Wine package that
declares `prefixCompatibility` vouches that builds sharing the value differ
only in code; for anything else, rebuild the layers with that Wine
(`runtime`).

## DLL overrides

Layers and packages declare Wine DLL load-order overrides as data instead of a
`WINEDLLOVERRIDES` string:

```nix
overlayfsLib.mkWindowsPackage {
  # ...
  dllOverrides = {
    d3d11 = "n";          # native
    d3dcompiler_47 = "n,b";
    msquic = "";          # disabled
  };
}
```

`mkWindowsPackage`, `mkWinpkgsPackage` and `composeWindowsLayers` accept
`dllOverrides`. A launcher merges the overrides of all its layers per module
and adds its own, which win. Two layers that disagree about a module fail
evaluation unless the package sets that module itself. Names and orders are
normalized as Wine reads them: case-insensitive, without `.dll`, and only the
first letter of each order entry counts (`native,builtin` is `n,b`; `d` and
`disabled` are `""`).

A `WINEDLLOVERRIDES` in `runtimeEnvVars` is still accepted and merged the same
way, so layers using it no longer replace each other's overrides. A
`WINEDLLOVERRIDES` set by the user at launch is appended after the packaged
overrides, so the user's entries win (Wine lets a later entry for the same
module replace an earlier one). The helpers are available as
`overlayfsLib.dllOverrides` (`parse`, `normalize`, `combine`, `render`).

Wine reads `WINEDLLOVERRIDES` before the per-program keys
(`HKCU\Software\Wine\AppDefaults\<program>.exe\DllOverrides`), so an override
set this way also applies to programs that must not get it. For overrides
that belong to a layer's files and may need per-program exceptions, use the
registry instead (`registryDllOverrides` of `mkFileLayer`, below).

## File layers: DXVK, vkd3d-proton and other native DLLs

`overlayfsLib.mkFileLayer` builds a layer from files and registry DLL
overrides, without Wine:

```nix
overlayfsLib.mkFileLayer {
  pname = "my-dlls";
  version = "1.0";
  files."drive_c/windows/system32/foo.dll" = "${foo}/x64/foo.dll";
  registryDllOverrides.foo = "native";
}
```

The overrides go into the layer's `user.reg` (`HKCU\Software\Wine\DllOverrides`),
merged with the other layers' registry at launch; per-program keys from other
layers keep their priority. Registry values from different layers do not
conflict at evaluation: the higher layer wins at runtime.

The module scopes provide:

- `dxvk` (nixpkgs' DXVK), `dxvk_2_6_2`, and `dxvkRelease { version; src; }`
  for a release archive pinned by its hash;
- `vkd3d-proton` (3.0.1 by default; nixpkgs has no package), with
  `.override { archive = fetchurl { ... }; archiveVersion = "..."; }` for
  another release or a patched build with the same layout (`x64/`, `x86/`).

All three set their DLLs to `native` in the registry. Used as
`overlayDependencies` of `composeWindowsLayers`, they are runtime layers:
changing their version rebuilds only the launcher, not the installation
below.

## WebView2

The module scopes provide WebView2 Runtime layers the way they provide DXVK:

- `webview2`: the x64 Evergreen Standalone Installer of WebView2
  154.0.4258.62, fetched from Microsoft by a pinned URL and hash. Unfree
  (`meta.license`), so evaluating it needs `allowUnfree` or a matching
  `allowUnfreePredicate`.
- `webview2Release { version; src; architecture; managedRuntime; }`: the same
  layer from another installer, pinned by its hash (below).
- `webview2-winget`: the installer winget-pkgs' manifest names today.
  Evaluating it fetches the whole `microsoft/winget-pkgs` repository and reads
  the manifest from a build result (import from derivation), so it is slow and
  fails under `--option allow-import-from-derivation false`. Prefer `webview2`.

`webview2` used to be the winget-based module. A package that used it gets the
pinned 154.0.4258.62 now; to keep the old behaviour use `webview2-winget`, or
pin the version it needs with `webview2Release`.

`webview2` runs `<installer> /silent /install`, waits at most 60
seconds (`wineserverWaitTimeout`) for the Wine processes the installer leaves
behind (then kills them), and fails the build unless `Program Files` or
`Program Files (x86)` has `Microsoft\EdgeWebView\Application\<version>\msedgewebview2.exe`
as a regular file whose PE header names the installer's architecture
(Machine `0x8664` for x64, `0x14c` for x86, `0xaa64` for arm64), with
`<version>` the one the layer is declared with; other version directories are
ignored. The check is `passthru.checkInstall`
(`nix-overlayfs-webview2-check-install PREFIX VERSION ARCHITECTURE`), tested
against fake prefixes in `tests/webview2-install-check`. Built on 2026-11-19 with
`managedRuntime = "external"` on `nativeModules` (x86_64-linux), the layer is
912 MB; the installer leaves Wine processes behind, so the 60-second wait
ends with a kill.

A layer is the difference against the base environment it was installed on,
so it has to use the `managedRuntime` of the package it goes into (see
[Headless and ephemeral runtimes](#headless-and-ephemeral-runtimes)). For a
package that gets .NET from `dotnet-framework-4-8`:

```nix
let
  modules = pkgs.nix-overlayfs.moduleScopes.nativeModules;
in
overlayfsLib.mkWindowsPackage {
  inherit (modules) runtime;
  managedRuntime = "external";
  overlayDependencies = [
    modules.dotnet-framework-4-8
    (modules.webview2.override { managedRuntime = "external"; })
  ];
  # ...
}
```

Without the override the package still evaluates (only layers built on the
`"external"` base are checked), but its WebView2 layer was then installed
into a prefix with Wine Mono, which the package's own prefix does not have.
The other way round is refused: an `"external"` WebView2 layer in a package
with Wine Mono fails evaluation.

Another installer (a newer release, or the x86 or arm64 one for a runtime that
prefers it), pinned by its hash:

```nix
modules.webview2Release {
  version = "<version>";
  src = fetchurl {
    url = "https://msedge.sf.dl.delivery.mp.microsoft.com/.../MicrosoftEdgeWebView2RuntimeInstallerX64.exe";
    hash = "sha256-...";
    meta.license = lib.licenses.unfree;
  };
  architecture = "x64";        # default; must be one the runtime prefers
  managedRuntime = "external"; # default "auto"
}
```

`webview2.override` accepts `installer`, `installerVersion`,
`installerArchitecture`, `managedRuntime`, `packageName` and
`wineserverWaitTimeout` (not `src`/`version`, which callPackage would fill
from nixpkgs). An installer whose architecture the runtime does not
prefer (`runtime.preferredInstallerArchitecture`) fails when the layer's
derivation is evaluated. The `webview2` check evaluates both layers,
their base environments and their use in packages, without winget-pkgs.

`mkWinpkgsPackage` passes `managedRuntime` and its other `mkWindowsPackage`
options on as well, so `modules.webview2-winget.override { managedRuntime =
"external"; }` also works.

## Migrating from `composeWineLayers`

The old `composeWineLayers` entrypoint has been replaced by
`composeWindowsLayers`.

The functional role is the same: compose a runnable overlay package from a base
layer, additional overlay layers, and a target executable path.

The main API change is that callers no longer pass a `wine` package directly.
They now pass a `runtime` taken from the selected module scope.

Old shape:

```nix
overlayfsLib.composeWineLayers {
  wine = wineModules.wine;
  packageName = "my-app";
  baseLayer = wineModules.base-env;
  overlayDependencies = [ wineModules.dxvk ];
  executableName = "my-app";
  executablePath = "${wineModules.wine.programFilesPath}/My App/app.exe";
}
```

New shape:

```nix
overlayfsLib.composeWindowsLayers {
  runtime = someModules.runtime;
  packageName = "my-app";
  baseLayer = someModules.base-env;
  overlayDependencies = [ someModules.dxvk ];
  executableName = "my-app";
  executablePath = "${someModules.runtime.programFilesPath}/My App/app.exe";
}
```

In practice, the migration is:

- `composeWineLayers` -> `composeWindowsLayers`
- `wine = ...` -> `runtime = ...`
- `wine.programFilesPath` -> `runtime.programFilesPath`
- choose the backend by choosing the module scope, not by swapping a Wine package manually

For example, on `aarch64-linux` you can point `runtime` at:

- `legacyPackages.aarch64-linux.nix-overlayfs.moduleScopes.nativeModules.runtime`
- `legacyPackages.aarch64-linux.nix-overlayfs.moduleScopes.x64FexModules.runtime`

## `aarch64-linux` runtime options

On `aarch64-linux`, this repository exposes two separate 64-bit Windows
runtime strategies.

### 1. `x64FexModules`

This is the native-host Wine path:

- Wine itself is built as native `aarch64-linux`.
- The Wine build is configured with `--enable-archs=arm64ec,aarch64,i386 --disable-tests`.
- The FEX WoA DLLs are bundled into `lib/wine/aarch64-windows/`.
- The base prefix explicitly sets `HKLM\Software\Microsoft\Wow64\amd64=libarm64ecfex.dll`
  and `HKLM\Software\Microsoft\Wow64\x86=libwow64fex.dll`, and mirrors those
  choices into `KnownDLLs\xtajit64` and `KnownDLLs\xtajit`.

The runtime shape is:

```text
app -> wine (native aarch64-linux) -> Windows ARM64EC/FEX WoA bridge -> host
```

This keeps Wine itself native on the host and avoids the separate Linux guest
userspace layer used by the older guest-FEX implementation, while making both
x64 and x86 WoW dispatch explicit in the runtime prefix.

### 2. `nativeModules`

This is the native Windows ARM64 path:

- Wine itself is built as native `aarch64-linux`.
- The packaged app uses the upstream Windows ARM64 build when one is available.
- No FEX WoA bridge is involved.

The runtime shape is:

```text
app -> wine (native aarch64-linux) -> Windows ARM64 binary -> host
```

### Which scope to use

Use `nativeModules` when:

- you want the host-native Wine path for the current system
- on `x86_64-linux`, your target is a standard Windows x64 application
- on `aarch64-linux`, your target has a native Windows ARM64 build

Use `x64FexModules` on `aarch64-linux` when:

- you want the native-host ARM64EC + FEX path
- your target application is the Windows x64 build
- you want the repo's default `aarch64-linux` path for mainstream Windows apps

### Selecting a runtime in your own package

The flake keeps bare top-level names for the preferred default on each host.
Explicit runtime variants live under `legacyPackages.<system>.nix-overlayfs`.

On `aarch64-linux`:

```text
nix run .#notepad-plus-plus

nix build .#notepad-plus-plus
nix build .#legacyPackages.aarch64-linux.nix-overlayfs.packageVariants.x64Fex.notepad-plus-plus
nix run .#legacyPackages.aarch64-linux.nix-overlayfs.appVariants.x64Fex.notepad-plus-plus

nix build .#legacyPackages.aarch64-linux.nix-overlayfs.packageVariants.native.notepad-plus-plus
nix run .#legacyPackages.aarch64-linux.nix-overlayfs.appVariants.native.notepad-plus-plus
```

`notepad-plus-plus` is the per-app preferred default on `aarch64-linux`.
Today it resolves to the Windows x64 package on the ARM64EC + FEX path.

`legacyPackages.aarch64-linux.nix-overlayfs.packageVariants.x64Fex.notepad-plus-plus` is the explicit Windows x64 variant on the
ARM64EC + FEX path.

`legacyPackages.aarch64-linux.nix-overlayfs.packageVariants.native.notepad-plus-plus` uses the upstream ARM64 portable zip with the native
ARM64 Wine path, which is useful for validating native Windows ARM64 execution
separately from x64-on-ARM64EC.

On `x86_64-linux`:

```text
nix run .#notepad-plus-plus

nix build .#notepad-plus-plus
nix build .#legacyPackages.x86_64-linux.nix-overlayfs.packageVariants.native.notepad-plus-plus
```

There is no `x64Fex` variant namespace on `x86_64-linux`.

For a minimal x64 Windows repro on `aarch64-linux`, the flake also exposes:

```text
nix run .#hello-x64

nix build .#hello-x64
nix build .#legacyPackages.aarch64-linux.nix-overlayfs.packageVariants.x64Fex.hello-x64
```

`hello-x64` is a locally built x64 Windows console executable packaged through
the same runtime wrapper. It is intended specifically for isolating the
ARM64EC/FEX x64 execution path from application complexity.

To opt into a specific runtime in your own package definition, use that scope's
`runtime` explicitly:

```nix
overlayfsLib.mkWinpkgsPackage {
  runtime = pkgs.nix-overlayfs.moduleScopes.x64FexModules.runtime;
  packageName = "Notepad++/Notepad++";
  executableName = "notepad++";
  executablePath = "${pkgs.nix-overlayfs.moduleScopes.x64FexModules.runtime.programFilesPath}/Notepad++/notepad++.exe";
}
```

The `apps` listing layer decides which runtime to use for the bare package/app
name on each host. The explicit variant trees are available from
`pkgs.nix-overlayfs.packageVariants` and `pkgs.nix-overlayfs.appVariants` when
consuming the overlay, or via `legacyPackages.<system>.nix-overlayfs` from the
flake.

### Related package outputs on `aarch64-linux`

For the native ARM64EC path, the package set exposes:

- `llvmMingwArm64ec`: the llvm-mingw toolchain bundle used for ARM64EC/ARM64 PE builds
- `fexWineDlls`: the built FEX WoA DLL package
- `nativeArm64ecWine`: the native-host ARM64EC-enabled Wine build
- `nativeArm64ecWineWithFex`: that Wine build with the FEX WoA DLLs merged in

These are useful if you want to inspect or override the native path directly
without going through `x64FexModules` or `nativeModules`.

### Current status

On `aarch64-linux`, the `x64Fex` namespace is the default backend for apps that
ship a Windows x64 build.

The minimal x64 Windows repro `hello-x64` now runs successfully through the
native ARM64EC + FEX path on this repository's 16K-page Asahi test machine.
The two main bring-up issues were:

- Wine misparsing the ARM64X dynamic relocation tail in `.reloc` as classic
  base relocations, which produced `Unknown/unsupported relocation 507c`
- ARM64EC work-list setup failing when the shared section mapping was attempted
  strictly with `MEM_TOP_DOWN`

Those are currently fixed by the local Wine patches in
[packages/patches/wine-arm64x-basereloc-fix.patch](/home/conroy/src/nix-overlayfs/packages/patches/wine-arm64x-basereloc-fix.patch)
and
[packages/patches/wine-arm64ec-worklist-fallback.patch](/home/conroy/src/nix-overlayfs/packages/patches/wine-arm64ec-worklist-fallback.patch).

Where an application does not support unattended installation, its installer can be automated
by providing an AutoHotKey script (see `lib.mkWindowsPackage`).

With this toolbox of fully reproducible Wine environments, application dependencies,
and unattended installation helpers, it should be possible to package and distribute any Windows application
for Linux without needing to distribute the installers themselves.

## Launcher runtime scripts and tests

The launcher `mkOverlayfsPackage` generates (`bin/<executableName>-unwrapped`,
which sets up the session, and `libexec/<executableName>-setupEnv.sh`, which
mounts the prefix and runs the application) is mostly glue. The work is done by
standalone programs in `lib/runtime/`, built with `writeShellApplication` so
`shellcheck` checks them at build time, and exposed as
`overlayfsLib.runtimeScripts`:

- `nix-overlayfs-sessions`: session directories of killed launchers, the
  running session of a writable layer, URLs handed to it, processes left
  over from a session in direct mode;
- `nix-overlayfs-state`: who holds a writable layer's session lock, its state
  generation;
- `nix-overlayfs-url-handlers`: the host URL handler `.desktop` entry, its
  `open-url` script and the scheme defaults;
- `nix-overlayfs-forget-desktop-entry`: removes a deleted entry from
  `mimeapps.list` files;
- `nix-overlayfs-host-browser-broker`: opens the pages Wine asks for in the
  host browser;
- `nix-overlayfs-registry`: merges the layers' registry files with the
  writable layer's (see [Registry](#registry)), replaces keys of `user.reg`;
- `nix-overlayfs-upper-layer`: the writable layer's directory skeleton, and
  removing `start.exe` shims that earlier launchers left there;
- `nix-overlayfs-guard-prefix-updates` and `nix-overlayfs-check-shadowed`:
  see [Persistent runtime state](#persistent-runtime-state);
- `nix-overlayfs-namespace`: the namespace mode, hiding `/etc/ld.so.preload`,
  unmounting;
- `nix-overlayfs-wine-shutdown`: waits for the prefix's `wineserver`.

What stays in the generated scripts needs the launcher shell itself: the
session lock descriptors, sourcing and recording `session-env`, the package's
hooks and environment, and the launch loop. The shell functions that hooks use
(`nix_overlayfs_upsert_user_reg_section`, `nix_overlayfs_registry_string`)
call the programs.

Each program has a check in `tests/<name>/` that runs it against fixtures
(`nix build .#checks.x86_64-linux.<name>`). NixOS VM tests run real
launchers: `lifecycle-vm` installs a fake Windows application, launches it
(its URL handler is registered), switches to a version whose Nix layer changed
and checks that nothing in the writable layer hides the new layer file, and
finally launches it with `registerHostUrlHandlers = false`, after which
`~/.local/share/applications` holds nothing of it. `session-isolation-vm`
runs a session whose pre-launch commands start a background service, in
namespace and direct mode: a second launch is refused and names the session,
neither the application nor the service has the state lock open, and nothing
of the session is left when it ends or when its supervisor is killed.
`state-lock` checks in the build sandbox that a launch refused because of the
lock or a newer state generation changes nothing in the writable layer. `nix flake check` runs all of them.

## Acknowledgements

Many thanks to [nix-overlayfs concept by xstepa73](https://github.com/xstepa73/nix-overlayfs),
upon which this is based.

## Maintaining Wine Mono metadata

See [Wine Mono updates](docs/wine-mono-updates.md) for the checksum-verifying
updater, scheduled metadata commits, and runtime validation.
