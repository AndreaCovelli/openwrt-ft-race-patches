# Repository Guidelines

## Scope

These instructions apply to the whole repository.

This repo maintains a reproducible OpenWrt builder and FT race patches for Cudy
WR3000-family devices. Treat router firmware generation and flashing notes as
high impact: prefer dry runs, preserve pinned inputs, and do not start remote
builds or router upgrades unless the user explicitly asks.

## Repository Layout

- `README.md` is the user-facing operating guide. Keep command examples and
  behavior descriptions in sync with script changes.
- `patches/subsys/400-mac80211-defer-ap-side-ft-key-upload.patch` is copied into
  OpenWrt at `package/kernel/mac80211/patches/subsys/`.
- `patches/hostapd/022-hostapd-ft-readd-unassociated-sta-before-ptk.patch` is
  copied into OpenWrt at `package/network/services/hostapd/patches/`.
- `locks/*.lock` pin OpenWrt, feeds, patch checksums, device metadata paths, and
  artifact naming fields. They are Bash files and are sourced by scripts.
- `devices/<name>/` contains the reference `diffconfig`, installed manifest, and
  apk world input for each example device.
- `scripts/` contains the local builder, wrappers, EC2 orchestration, and CI
  checks. Shared shell helpers live in `scripts/lib/`.
- `docker/Dockerfile.ec2` defines the remote Docker builder environment.
- `openwrt-artifacts/`, `build/`, and `cache/` are generated output/cache
  directories and are ignored.

## Development Commands

Use the committed Mise configuration for the complete validation suite:

```sh
mise install
mise run check
```

Run an individual group with `mise run check:shell`,
`mise run check:metadata`, or `mise run check:links`.

Run the focused checks that match your change:

```sh
bash -n scripts/*.sh scripts/**/*.sh locks/*.lock
shellcheck --severity=warning -x scripts/*.sh scripts/**/*.sh
shellcheck --severity=warning --shell=bash --exclude=SC2034 locks/*.lock
scripts/ci/check-locks.sh
scripts/ci/check-build-names.sh
scripts/ci/check-prepare-openwrt-upgrade.sh
scripts/ci/check-upgrade-router-image.sh
scripts/ci/check-prebuilt-apks.sh
scripts/ci/check-run-local-docker-build.sh
scripts/ci/check-incremental-build.sh
```

CI also runs a Markdown link check over `README.md` and `docs/**/*.md` with
Lychee. If you add external links, expect that check to run in GitHub Actions.

Full firmware builds are expensive and may use network, Docker, SSH, AWS, or EC2
resources:

```sh
./scripts/build-image.sh --builder-id <builder-id> locks/<device>.lock
./scripts/orchestrate-ec2-build.sh <ssh-target> locks/<device>.lock
./scripts/run-ec2-build.sh locks/<device>.lock
```

Do not run those full build or EC2 commands unless the user asked for them.

## Shell Style

- Use Bash with `set -euo pipefail` for repository scripts.
- Keep scripts executable when they are intended as entrypoints.
- Prefer arrays for command construction and quoted expansions for paths and
  user-provided values.
- Use existing helpers and patterns before adding new abstractions.
- Keep lock files as simple literal assignments and arrays. They are parsed by
  `scripts/lib/build-name.sh` and validated by `scripts/ci/check-locks.sh`.
- Do not introduce commands with side effects into lock files.

## Lock And Patch Rules

- When editing the mac80211 patch, update `PATCH_SHA256` in every affected
  `locks/*.lock` file. Verify with `scripts/ci/check-locks.sh`.
- When editing extra package patches such as the hostapd patch, update the
  matching `EXTRA_PATCH_SHA256S` entry in every affected `locks/*.lock` file.
  Verify with `scripts/ci/check-locks.sh`.
- Keep `PATCH_SOURCE` and `PATCH_DEST` basenames identical. `PATCH_DEST` must
  remain under `package/kernel/mac80211/patches/subsys/`.
- Keep `EXTRA_PATCH_SOURCES` and `EXTRA_PATCH_DESTS` arrays aligned by index,
  with matching basenames and matching `EXTRA_PATCH_SHA256S` entries.
- Feed refs and `OPENWRT_REF` values must be full 40-character lowercase commit
  hashes.
- `OPENWRT_TAG` is optional for main-branch compile-check locks, but stable
  upgrade preparation expects tagged stable locks.
- Artifact names are generated from lock fields; validate changes with
  `scripts/ci/check-build-names.sh`.

## ASU-Like Upgrade Preparation

Use dry runs first:

```sh
./scripts/prepare-openwrt-upgrade.sh --dry-run <ssh-target> locks/<device>.lock
```

The preparation script reads router state over SSH, queries ASU metadata, updates
the selected lock and device package baselines, and can launch the EC2 build
wrapper. It intentionally controls strict-manifest mode; do not pass
`--strict-manifest` or `--no-strict-manifest` through to it.

The script does not copy or flash firmware. Do not automate `sysupgrade` from
this repo unless the user explicitly requests it and has confirmed the target
image and router.

## Generated Files And Artifacts

- Leave generated build output under ignored directories such as `build/`,
  `cache/`, and `openwrt-artifacts/`.
- Do not commit firmware images, source download caches, tarballs, or transient
  EC2 logs unless the user explicitly asks.
- If adding a new device, commit only the device inputs in `devices/<name>/` and
  the matching lock file unless a broader change is required.

## Safety Notes

- Remote orchestration may install packages, start Docker, create EC2 resources,
  open a temporary SSH-only security group, fetch artifacts, and terminate cloud
  resources. Make the intended target and cleanup behavior explicit before
  running it.
- Flashing instructions in `README.md` require manual checksum verification,
  copying the matching `*sysupgrade.bin`, running `sysupgrade -T`, and only then
  running the actual upgrade.
- Preserve unrelated user changes in the working tree. Avoid broad cleanup or
  destructive git commands unless explicitly requested.
