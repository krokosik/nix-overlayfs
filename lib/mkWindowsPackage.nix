# Maintainer: Conroy Cheers <conroy@corncheese.org>
# Based on original work by Libor Stepanek 2025
{
  lib,
  mkOverlayfsPackage,
  diffs,

  writeShellScript,
  stdenv,

  xorg-server,
  util-linux,
  mount,
  bash,
  jq,
  jd-diff-patch,
  gnused,
  moreutils,
  x11vnc,
  coreutils,
  rsync,

  overlayfsLib,
}:
{
  # The Wine the installation and its base environment are built with.
  runtime,
  # The Wine the launcher runs, a build of the same Wine release (for example
  # with patches under test). Changing it rebuilds only the launcher.
  launchRuntime ? runtime,
  pname,
  version,
  src,
  packageName,
  executableName ? "",
  executablePath ? "",
  workingDirectory ? null,
  extraPreLaunchCommands ? "",
  extraPostLaunchCommands ? "",
  overlayDependencies ? [ ],
  extraPathsToRemove ? [ ],
  extraPathsToInclude ? [ ],
  silentFlags ? "",
  ahkScript ? "",
  postInstall ? "",
  launchVncServer ? false,
  unshareInstall ? null,
  buildNamespaceMode ? "auto",
  # Materialized builds avoid overlayfs EXDEV when Wine renames reparse directories.
  portableReparsePoints ? false,
  hostIntegration ? true,
  registerHostUrlHandlers ? true,
  managedRuntime ? "auto",
  namespaceMode ? "auto",
  processTerminationTimeout ? 5,
  stateMode ? "persistent",
  wineserverWaitTimeout ? null,
  runtimeEnvVars ? { },
  dllOverrides ? { },
  urlSchemes ? [ ],
  urlSchemeDiscoveryCommands ? "",
  urlSchemeOpenCommands ? "",
  entrypointWrapper ? (entrypoint: ''exec ${entrypoint} "$@"''),
  ...
}:
let
  scripts = overlayfsLib.scripts;
  _checkBuildNamespaceMode =
    if
      builtins.elem buildNamespaceMode [
        "auto"
        "required"
        "direct"
      ]
    then
      true
    else
      throw "buildNamespaceMode must be one of: auto, required, direct";
  _checkManagedRuntime = overlayfsLib.managedRuntime.check managedRuntime;
  winedbg = "-all";
  packageVersion = version;
  pathsToRemove = builtins.concatStringsSep " " (
    builtins.map (val: "\"" + val + "\"") extraPathsToRemove
  );
  renderEnvExports =
    env: builtins.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "export ${n}=${v}") env);
  managedRuntimeCommands = lib.optionalString (managedRuntime == "disabled") ''
    export WINEDLLOVERRIDES="mscoree,mshtml=d''${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
  '';

  ahkScriptPresent = ahkScript != "";

  baseEnvLayer =
    if runtime ? selectBaseEnvLayer then
      runtime.selectBaseEnvLayer { inherit hostIntegration managedRuntime; }
    else if hostIntegration && managedRuntime == "auto" then
      runtime.baseEnvLayer
    else
      throw "the selected runtime does not provide capability-specific base environment layers";
  baseEnv = [ baseEnvLayer ];
  overlayDependenciesPlusUtils =
    (lib.optionals ahkScriptPresent [
      runtime.autohotkeyLayer
    ])
    ++ overlayDependencies;
  overlayDependenciesPlusEnv = baseEnv ++ overlayDependenciesPlusUtils;
  _checkLayerManagedRuntime = overlayfsLib.managedRuntime.checkLayers {
    inherit managedRuntime packageName;
    layers = overlayDependenciesPlusUtils;
  };
  _checkLaunchRuntime = overlayfsLib.launchRuntime.check {
    inherit runtime launchRuntime packageName;
  };
  launchSession = launchRuntime.mkSession {
    phase = "launch";
    sessionRoot = "$tempdir/runtime-session";
    overlayRoot = "$tempdir/overlay";
    homeDir = "$HOME";
  };
  hostBrowserBootstrapCommands = lib.optionalString hostIntegration ''
        nix_overlayfs_upsert_user_reg_section 'Software\\Wine\\WineBrowser' <<EOF
    "Browsers"=$(nix_overlayfs_registry_string '${lib.getExe overlayfsLib.hostUrlOpener}')
    EOF
  '';
  protocolRegistrationCommands = lib.optionalString hostIntegration ''
        if [ -s "$nix_overlayfs_url_schemes_file" ]; then
          nix_overlayfs_protocol_executable=${lib.escapeShellArg executablePath}
          case "$nix_overlayfs_protocol_executable" in
            /drive_c/*)
              nix_overlayfs_protocol_executable="C:\\''${nix_overlayfs_protocol_executable#/drive_c/}"
              nix_overlayfs_protocol_executable="''${nix_overlayfs_protocol_executable//\//\\}"
              ;;
            drive_c/*)
              nix_overlayfs_protocol_executable="C:\\''${nix_overlayfs_protocol_executable#drive_c/}"
              nix_overlayfs_protocol_executable="''${nix_overlayfs_protocol_executable//\//\\}"
              ;;
            *)
              nix_overlayfs_protocol_executable="$(${launchRuntime.toolsPackage}/bin/winepath -w "$tempdir/overlay/${executablePath}")"
              ;;
          esac
          while IFS= read -r nix_overlayfs_url_scheme; do
            nix_overlayfs_upsert_user_reg_section 'Software\\Classes\\'"$nix_overlayfs_url_scheme" <<EOF
    @=$(nix_overlayfs_registry_string "URL:$nix_overlayfs_url_scheme Protocol")
    "URL Protocol"=""
    EOF
            nix_overlayfs_upsert_user_reg_section 'Software\\Classes\\'"$nix_overlayfs_url_scheme"'\\shell\\open\\command' <<EOF
    @=$(nix_overlayfs_registry_string "\"$nix_overlayfs_protocol_executable\" \"%1\"")
    EOF
          done < "$nix_overlayfs_url_schemes_file"
        fi
  '';

  # The installation builds on its dependencies' layers, not on their
  # launchers: a package made by mkWindowsPackage exposes its layer as
  # passthru.basePackage (the same path its launcher links as basePackage).
  # Referring to the launcher would rebuild every dependent installation
  # whenever only launcher scripts change.
  layerRoot =
    dependency:
    if dependency ? basePackage && lib.isDerivation dependency.basePackage then
      "${dependency.basePackage}"
    else
      "${dependency}/basePackage";
  deps = builtins.map (x: "\"" + layerRoot x + "\"") overlayDependenciesPlusEnv;

  buildSession = runtime.mkSession {
    phase = "build";
    sessionRoot = "$PWD/runtime-session";
    overlayRoot = "$PWD/merged";
    homeDir = "$temp";
  };

  basePackage =
    let
      waitForWineserver =
        if wineserverWaitTimeout == null then
          ''
            ${buildSession.commands.wineserver} --wait
          ''
        else
          ''
            timeout ${toString wineserverWaitTimeout} ${buildSession.commands.wineserver} --wait || {
              echo "warning: wineserver did not exit within ${toString wineserverWaitTimeout}s; killing remaining Wine processes" >&2
              ${buildSession.commands.wineserver} -k || true
            }
          '';
      defaultUnshareInstallSteps = (
        [
          ''
            ${buildSession.commands.wine} '${src}' ${silentFlags} ${if ahkScriptPresent then "&" else ""}
          ''
        ]
        ++ (lib.optionals ahkScriptPresent [
          ''
            cat > unattended-install.ahk <<'EOF'
            ${ahkScript}
            EOF

            ${buildSession.commands.wine} "$WINEPREFIX${runtime.autohotkeyLayer.executablePath}" "Z:$(pwd)/unattended-install.ahk"
          ''
        ])
        ++ (lib.optionals (postInstall != "") [ postInstall ])
        ++ [
          waitForWineserver
        ]
      );

      buildPhaseUnshareScript = writeShellScript "buildUnshare" (
        (lib.concatStringsSep "\n" (
          [
            ''
              set -e

              ${lib.optionalString portableReparsePoints ''
                export LD_PRELOAD="${scripts.portableReparse}/lib/libwine-portable-reparse.so''${LD_PRELOAD:+:$LD_PRELOAD}"
              ''}

              cleanup_runtime_session() {
                local status=$?
                ${buildSession.postCommands}
                exit $status
              }

              trap cleanup_runtime_session EXIT

              ${renderEnvExports buildSession.env}
              ${managedRuntimeCommands}
              ${buildSession.preCommands}
            ''
          ]
          ++ (lib.optionals launchVncServer [
            ''
              sleep 5
              ${lib.getExe x11vnc} \
                -viewonly \
                -display "$DISPLAY" \
                -shared -noxdamage -wait 5 &
              X11VNC_PID=$!
              sleep 5
            ''
          ])
          ++ (lib.optionals (unshareInstall == null) defaultUnshareInstallSteps)
          ++ (lib.optionals (unshareInstall != null) [
            (unshareInstall {
              inherit runtime;
              session = buildSession // {
                commands = buildSession.commands // {
                  normalizeReparsePoints = "${scripts.portableReparse}/bin/normalize-wine-reparse.py";
                };
              };
            })
          ])
          ++ (lib.optionals portableReparsePoints [
            ''${scripts.portableReparse}/bin/normalize-wine-reparse.py "$WINEPREFIX" || exit $?''
          ])
          ++ (lib.optionals launchVncServer [
            ''
              kill $X11VNC_PID
            ''
          ])
        ))
      );

      buildPhaseEnvScript = writeShellScript "buildEnv" ''
        mount -t overlay -o lowerdir=./wineprefix,upperdir=./data,workdir=./work overlay ./merged

        export USER="$originalUser"

        Xvfb :999 -screen 0 1600x900x16 &
        XVFB_PROC_ID=$!
        export DISPLAY=:999

        unshare --map-user="$originalUser" "${buildPhaseUnshareScript}"
        INSTALL_STATUS=$?

        kill $XVFB_PROC_ID;

        exit $INSTALL_STATUS
      '';

      buildPhaseDirectScript = writeShellScript "buildDirect" ''
        xvfb_pid=""

        cleanup_direct_build() {
          status=$?
          trap - EXIT
          if [ -n "$xvfb_pid" ]; then
            kill "$xvfb_pid" 2>/dev/null || true
          fi
          exit "$status"
        }
        trap cleanup_direct_build EXIT

        cp -a "$PWD/wineprefix/." "$PWD/merged/"

        export USER="$originalUser"
        Xvfb :999 -screen 0 1600x900x16 &
        xvfb_pid=$!
        export DISPLAY=:999

        "${buildPhaseUnshareScript}"
        install_status=$?
        if [ "$install_status" -ne 0 ]; then
          exit "$install_status"
        fi

        rsync -a --checksum --compare-dest="$PWD/wineprefix/" "$PWD/merged/" "$PWD/data/"
      '';
    in
    stdenv.mkDerivation {
      inherit pname src;
      version = packageVersion;

      unpackPhase = "true";

      buildInputs = [
        xorg-server
        util-linux
        mount
        bash
        jq
        jd-diff-patch
        scripts.json2reg
        scripts.reg2json
        gnused
        moreutils
        rsync
      ]
      ++ buildSession.buildInputs;

      buildPhase =
        let
          jqRegMerge = ".[0] * .[1]";
          jqRemoveNulls = "del(.. | select(. == null))";
          dupesToRemove = lib.subtractLists extraPathsToInclude diffs.dupes;
        in
        ''
          mkdir wineprefix data work merged

          deps=(${lib.strings.concatStringsSep " " deps});

          cp "''${deps[0]}/system.json" "''${deps[0]}/user.json" "''${deps[0]}/userdef.json" ./

          for i in ''${!deps[@]}; do
            if [[ $i != 0 ]]; then
              for file in system.json user.json userdef.json; do
                basepath="''${deps[$i]}/$file"
                if [ -e "$basepath" ]; then
                  jq -s '${jqRegMerge}' $file "$basepath" | sponge $file || true
                fi
              done
            fi
            # Copy the directory itself so Wine control files such as
            # .update-timestamp survive composition. A trailing glob silently
            # drops dotfiles and makes Wine rerun Wow64Install on every layer.
            cp --recursive "''${deps[$i]}"/. ./wineprefix/
            chmod --recursive +rw ./wineprefix
          done

          json2reg system.json system.reg
          json2reg user.json user.reg
          json2reg userdef.json userdef.reg

          cp system.reg user.reg userdef.reg ./wineprefix/

          export temp=$(mktemp -d)
          export originalUser=$(id --user --name)

          namespace_mode=${
            lib.escapeShellArg (if portableReparsePoints then "direct" else buildNamespaceMode)
          }
          if [ "$namespace_mode" = auto ]; then
            if unshare --map-root-user --mount true 2>/dev/null; then
              namespace_mode=required
            else
              echo "warning: nix-overlayfs: build user/mount namespaces are unavailable; using materialized build mode" >&2
              namespace_mode=direct
            fi
          fi

          if [ "$namespace_mode" = direct ]; then
            "${buildPhaseDirectScript}"
          else
            unshare --fork --map-root-user --mount bash -c -- '${buildPhaseEnvScript}'
          fi

          rm --force ./data/.update-timestamp
          mkdir --parents ./data/bin

          # Kernel overlayfs manages private workdir entries. Only the
          # produced delta needs permission normalization before packaging.
          chmod --recursive a+rw ./data
          rm --recursive --force "./data/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/"
          find ./data/ -type d -empty -delete

          # A layer's hives hold only its own changes against its
          # dependencies (the hives they compose to): the values and keys it
          # added or changed, and as [-key] or "name"=- what it deleted.
          # Complete hives would re-assert every dependency value in this
          # layer and, since it is merged above them, mask what other layers
          # below it change. HIVE.json is the same delta as a JSON merge
          # patch, which dependent builds compose on. What the capture
          # leaves out of the new hive (installation dates, temporary paths,
          # the noise in lib/diffs) is left out of the dependencies' hives
          # too before comparing, so it is not taken for a deletion.
          nix_overlayfs_capture_hive() {
            local hive="$1"
            local filter="$2"
            local noise="$3"

            reg2json "./data/$hive.reg" > "$hive.new.json"
            jq '${jqRemoveNulls}' "$hive.new.json" | sponge "$hive.new.json"
            if [ -n "$noise" ]; then
              jd -p -f=merge -o "$hive.new.json" "$noise" "$hive.new.json" || true
            else
              noise=/dev/null
            fi
            # (The composed hive keeps the nulls of its dependencies'
            # deletions; json2reg dropped them from the prefix.)
            jq -s "((.[0] * (.[1] // {})) | del(.. | nulls)) | $filter" "$hive.json" "$noise" > "$hive.before.json"
            jd -f=merge -o "$hive.diff.json" "$hive.before.json" "$hive.new.json" || true
            [ -s "$hive.diff.json" ] || printf '{}' > "$hive.diff.json"
            # Wine does not write keys that have subkeys but no values, so
            # such a key of the dependencies looks deleted; only keys that
            # had values are.
            jq -s '.[2] as $before | .[0] | if .keys then .keys |= with_entries(select(.value != null or (($before.keys[.key] // {}) | length) > 0)) else . end' \
              "$hive.diff.json" "$hive.new.json" "$hive.before.json" > "./data/$hive.json"
            jq -s '{version: .[1].version, location: .[1].location, arch: .[1].arch, keys: (.[0].keys // {})}' \
              "./data/$hive.json" "$hive.new.json" > "$hive.delta.json"
            json2reg --deletions "$hive.delta.json" "./data/$hive.reg"
          }

          if [ -e ./data/system.reg ]; then
            sed -i '/^"InstallDate"=/d' ./data/system.reg
            sed -i '/^"FirstInstallDateTime"=/d' ./data/system.reg
            nix_overlayfs_capture_hive system \
              '.keys |= with_entries(if (.value | type) == "object" then .value |= with_entries(select(.key != "\"InstallDate\"" and .key != "\"FirstInstallDateTime\"")) else . end)' \
              "${diffs.system}"
          fi

          if [ -e ./data/user.reg ]; then
            sed -i -E '/tmp.[0-9A-Za-z]{10}/d' ./data/user.reg
            nix_overlayfs_capture_hive user \
              '.keys |= with_entries(select(.key | test("tmp.[0-9A-Za-z]{10}") | not) | if (.value | type) == "object" then .value |= with_entries(select("\(.key)=\(.value)" | test("tmp.[0-9A-Za-z]{10}") | not)) else . end)' \
              "${diffs.user}"
          fi

          if [ -e ./data/userdef.reg ]; then
            nix_overlayfs_capture_hive userdef . ""
          fi

          # A successful no-op installer can legitimately produce no drive_c
          # delta once Wine's update marker is retained by the base layer.
          if [ -d ./data/drive_c ]; then
            pushd ./data/drive_c || exit 1

            rm --force ${lib.concatMapStringsSep " " (x: "'${x}'") dupesToRemove}
            rm --recursive --force \
              ./windows/Installer \
              ./users/nixbld/Desktop \
              ./users/nixbld/AppData/Roaming/Microsoft/Windows/Templates \
              ./users/nixbld/Documents \
              ./users/nixbld/Music \
              ./users/nixbld/Videos \
              ./users/nixbld/Desktop \
              ./users/nixbld/Pictures \
              ./users/nixbld/Downloads
            rm --force ${pathsToRemove}
            find . -type d -empty -delete
            popd || exit 1
          fi
        '';

      installPhase = ''
        mkdir $out
        # A layer is the complete set of entries below its root, including
        # dotfiles created by an installer.
        find ./data -mindepth 1 -maxdepth 1 -exec mv --target-directory="$out" -- {} +
      '';

      passthru = {
        inherit
          buildPhaseUnshareScript
          buildPhaseEnvScript
          buildPhaseDirectScript
          runtime
          ;
      };
    };
in
assert _checkBuildNamespaceMode;
assert lib.assertMsg (
  !(portableReparsePoints && buildNamespaceMode == "required")
) "portableReparsePoints requires a materialized build; use buildNamespaceMode auto or direct";
assert _checkManagedRuntime;
assert _checkLayerManagedRuntime;
assert _checkLaunchRuntime;
mkOverlayfsPackage {
  inherit
    basePackage
    executableName
    executablePath
    hostIntegration
    registerHostUrlHandlers
    namespaceMode
    processTerminationTimeout
    stateMode
    workingDirectory
    entrypointWrapper
    urlSchemes
    urlSchemeDiscoveryCommands
    urlSchemeOpenCommands
    ;
  extraPreLaunchCommands = hostBrowserBootstrapCommands + extraPreLaunchCommands;
  inherit extraPostLaunchCommands;
  urlSchemeRegistryCommands = protocolRegistrationCommands;
  overlayDependencies = overlayDependenciesPlusEnv;
  session = launchSession;
  launchProgram = launchSession.commands.wine;
  basePackageName = packageName;
  extraEnvCommands = ''
    export WINEDEBUG="${winedbg}"
  ''
  + builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (n: v: "export ${n}='${v}'") (
      overlayfsLib.dllOverrides.withoutOverrides runtimeEnvVars
    )
  )
  + "\n"
  + overlayfsLib.dllOverrides.exportCommand (
    overlayfsLib.dllOverrides.combine {
      layers = overlayDependenciesPlusEnv;
      package = { inherit dllOverrides runtimeEnvVars; };
    }
  )
  + lib.optionalString (managedRuntime == "disabled") ''

    export WINEDLLOVERRIDES="mscoree,mshtml=d''${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
  '';
  passthru = {
    inherit
      managedRuntime
      runtime
      launchRuntime
      runtimeEnvVars
      ;
    # Built on a base without Wine Mono, this layer only fits such a base.
    requiredManagedRuntime = if managedRuntime == "external" then "external" else null;
    # This package's own overrides, for packages that use it as a layer.
    dllOverrides = overlayfsLib.dllOverrides.fromLayer { inherit dllOverrides runtimeEnvVars; };
  };
}
