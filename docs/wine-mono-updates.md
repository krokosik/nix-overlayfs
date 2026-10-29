# Wine Mono updates

Wine pins its required Mono version and architecture-specific MSI SHA-256 in
`dlls/appwiz.cpl/addons.c`. The updater reads that file from a resolved Wine
release commit, downloads the x86 MSI, verifies it against Wine's checksum, and
records its URL and Nix SRI hash in
`packages/wine-modules/wine-base-env/wine-mono.json`.

The catalog preserves the existing Wine/Proton selections and source hashes.
The updater adds mappings; it refuses to silently replace an existing mapping,
URL, or hash. Unsupported Wine source formats and checksum mismatches stop the
update before the catalog is written. Network access happens only in this
maintenance tool, not during Nix evaluation.

## Local use

```sh
# Discover the newest numbered Wine release and newest stable X.0[.Y] release.
python3 scripts/update-wine-mono.py

# Update specific releases, including a custom runtime's upstream Wine version.
python3 scripts/update-wine-mono.py --wine-version 11.20

# Backfill missing releases by repeating the version option.
python3 scripts/update-wine-mono.py --wine-version 11.2 --wine-version 11.5

# Verify sources without modifying the catalog; exit 1 if an update is needed.
python3 scripts/update-wine-mono.py --wine-version 11.20 --check

nix build .#checks.x86_64-linux.wine-mono-update --no-link
```

`git` and Python 3 are required. An optional `GH_TOKEN` increases the GitHub API
rate limit. Prerelease tags are excluded; Proton and other custom version names
remain manually maintained. The updater does not backfill every historical
Wine release. Existing intentionally null selections remain unchanged.

## Scheduled updates

`.github/workflows/wine-mono.yml` checks weekly and supports manual dispatch
with optional space-separated Wine versions. When metadata changes, it runs
the updater and catalog selection checks, then commits the verified catalog
directly to the repository's default branch. No changes means no commit.
Scheduled and manual updates share a concurrency group. Pushes never force
rewrite history; if the default branch changes during a run, rerun the job
against the new branch tip.

The workflow must first be merged into the default branch for scheduled and
manual triggers to be available. Forks may need scheduled workflows enabled.
Only the update job requests `contents: write`; PR checks run with read access
and without persisted checkout credentials. The workflow uses the repository's
built-in token and requires no additional secret. Branch protection must allow
these automated commits. Each run records verified releases and source links
in its Actions summary.

## Validation boundaries

Automation verifies source integrity, metadata selection, and updater behavior.
It does **not** prove that a new Wine/Mono combination bootstraps successfully
or runs a Windows application. Before using a new combination, build the base
environment with the actual intended Wine runtime and check its application.

The updater does not change Wine, Nixpkgs, or the flake lock, and never extends
the Mono MSI `CREATELINKS` workaround automatically. A newly discovered Mono
version may need a separately tested compatibility adjustment. This separates
dependency discovery from runtime qualification.
