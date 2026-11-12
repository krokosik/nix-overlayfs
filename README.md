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

## Runtime process supervision

Each runtime session is launched below a dedicated Linux child subreaper. When
the application session ends, nix-overlayfs first asks Wine to shut down
cleanly, then terminates and reaps only processes descended from that session
before unmounting its prefix. This contains double-forked and native helper
processes without selecting processes globally by command line or environment.

`processTerminationTimeout` controls the grace period between `SIGTERM` and
`SIGKILL` and defaults to 5 seconds. It is accepted by `mkOverlayfsPackage`,
`composeWindowsLayers`, `mkWindowsPackage`, and `mkWinpkgsPackage`. The runtime
override `NIX_OVERLAYFS_PROCESS_TERMINATION_TIMEOUT` accepts a non-negative
duration with an optional `ms`, `s`, `m`, `h`, or `d` suffix.

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

### Wine prefix updates

Wine updates a prefix (wineboot's `PreInstall`, `DefaultInstall` and
`Wow64Install`) when `.update-timestamp` is missing or does not match its
`wine.inf`. In a layered prefix that update rewrites every builtin DLL into the
writable layer, where the copies then hide the Nix layers for good, including
native DLLs such as DXVK's `d3d11.dll`. Before mounting, the launcher therefore
writes `disable` into the writable layer's `.update-timestamp`, which stops
wineboot's automatic update (`programs/wineboot/wineboot.c`,
`update_timestamp()`). It does not stop an explicit `wineboot -u` or a program
that runs `wine.inf`'s sections itself. Prefix contents come from the Nix
layers; a Wine change that needs new prefix contents belongs in a rebuilt
base environment.

Set `NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1` to restore Wine's default behaviour
for a launch; the launcher then removes its marker again.

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
last of them exits. Under the base directory's `.lock`, each launch creates
and locks its own directory and removes the directories whose lock is free
and that have nothing mounted below them. Directories without `session.lock`
(left by launchers before this) are never removed automatically; delete them
by hand once no session of that application runs.

## URL schemes

A package's `urlSchemes` (plus anything `urlSchemeDiscoveryCommands` prints)
are registered in two places at every launch:

- in the Wine prefix (`HKCU\Software\Classes\<scheme>`), so Windows programs
  can open them;
- on the host, unless `registerHostUrlHandlers = false`: a hidden
  `<executableName>-nix-overlayfs-url-handler.desktop` in
  `$XDG_DATA_HOME/applications`, made the user's default with `xdg-mime`.

The host handler calls the launcher with `--nix-overlayfs-open-url URL`. If a
session of the package is running, the URL is handed to it
(`urlSchemeOpenCommands`); otherwise the application starts with the URL.
`--nix-overlayfs-forward-url URL` only hands the URL to a running session and
exits with status 3 when there is none, without starting anything; a
dispatcher can use it to find the right application when several share a
scheme.

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

## Acknowledgements

Many thanks to [nix-overlayfs concept by xstepa73](https://github.com/xstepa73/nix-overlayfs),
upon which this is based.

## Maintaining Wine Mono metadata

See [Wine Mono updates](docs/wine-mono-updates.md) for the checksum-verifying
updater, scheduled metadata commits, and runtime validation.
