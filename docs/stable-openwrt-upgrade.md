# Stable OpenWrt Router Upgrade Guide

This guide describes the safe path for updating a supported Cudy WR3000-family
router to a newer stable OpenWrt release while keeping this repository's
FT race patch bundle and reproducible build inputs.

Run these commands from the repository root.

The upgrade flow is:

1. Read router state and ASU metadata.
2. Dry-run the selected release and lock-file changes.
3. Prepare the lock and package baseline.
4. Build the patched image.
5. Verify local artifacts.
6. Copy and test the sysupgrade image without flashing.
7. Flash only after the preflight passes.

Do not use this guide for a cross-branch major upgrade unless you have reviewed
the target release, package changes, and OpenWrt upgrade notes separately. The
preparation script intentionally refuses cross-branch upgrades.

## Pick the target lock

Use the stable lock that matches the router:

| Router | Lock file |
| --- | --- |
| WR3000 | `locks/build-wr3000.lock` |
| WR3000E | `locks/build-wr3000e.lock` |
| WR3000P | `locks/build-wr3000p.lock` |

Do not use `locks/build-wr3000e-main.lock` for a router upgrade. It is for a
main-branch compile check, not for stable sysupgrade preparation.

In the examples below, replace:

- `<ssh-target>` with the SSH host alias or address for the router.
- `<lock-file>` with the matching lock file from the table.
- `<build>` with the artifact bundle directory created under
  `openwrt-artifacts/`.
- `<image-sysupgrade.bin>` with the matching `*sysupgrade.bin` file.

## Confirm SSH access

Confirm that the target name reaches the router before running the preparation
script:

```sh
ssh <ssh-target> 'cat /etc/openwrt_release; cat /tmp/sysinfo/board_name'
```

Check that the board name matches the lock you plan to use. The preparation
script also validates this against ASU profile metadata, but checking it early
helps avoid preparing the wrong target.

## Dry-run the upgrade preparation

Always start with a dry run:

```sh
./scripts/prepare-openwrt-upgrade.sh --dry-run <ssh-target> <lock-file>
```

Example:

```sh
./scripts/prepare-openwrt-upgrade.sh --dry-run wr3000e locks/build-wr3000e.lock
```

The dry run reads the router over SSH and queries the ASU server. It prints the
selected release, the lock-file changes, the package baseline paths, and the
EC2 build command. It does not write files, start a build, copy firmware, or
flash the router.

To prepare a specific same-branch stable release instead of the latest release
reported by ASU metadata, pass `--version`:

```sh
./scripts/prepare-openwrt-upgrade.sh --dry-run --version 25.12.4 <ssh-target> <lock-file>
```

Continue only if the dry run shows the expected router, target, profile,
release, and lock file.

## Prepare and build

Run the preparation for real after the dry run looks correct:

```sh
./scripts/prepare-openwrt-upgrade.sh <ssh-target> <lock-file> -- --make-jobs 4 --download-jobs 8
```

Example:

```sh
./scripts/prepare-openwrt-upgrade.sh wr3000e locks/build-wr3000e.lock -- --make-jobs 4 --download-jobs 8
```

This command:

- reads `/etc/openwrt_release`, `attendedsysupgrade.server.url`,
  `/etc/apk/world`, and the installed apk database from the router;
- validates the target and profile against ASU metadata;
- updates only the selected stable lock file to exact OpenWrt and release feed
  commits, and switches its `PATCH_SOURCE` and `PATCH_SHA256` to the mac80211
  patch in `patches/<release>/subsys/`;
- refreshes that device's package baseline;
- refreshes the lock's SDK, ImageBuilder, and repository index pins with
  `scripts/pin-imagebuilder.sh`, and stops if that fails;
- starts `scripts/run-ec2-build.sh` with `--no-strict-manifest` for the
  transition build.

Do not pass `--strict-manifest` or `--no-strict-manifest` to
`prepare-openwrt-upgrade.sh`. The preparation script controls strict-manifest
mode itself.

If the router already runs the selected release, the script refreshes the
package baseline and exits without starting a build.

Locks with `PREBUILT_APKS`, such as the WR3000P lock and its patched `usteer`,
need APKs built against the new release. When an APK filename names the lock's
current release but not the selected one, the script stops before changing any
file. Publish a matching `usteer-apk-builder` release, update the lock and the
local feed `PKG_SOURCE` and `PKG_HASH`, then rerun. A dry run reports the
mismatch as a warning, and `--allow-prebuilt-apk-mismatch` deliberately keeps
the old APK.

The mac80211 patch is refreshed separately for each release. Before preparing
a new release, add its refreshed patch under `patches/<release>/subsys/` as
described in "Refreshing pinned patches" in the README. When the selected
release has no such patch, the script stops before changing any file; a dry
run reports it as a warning.

The stable locks build with the official SDK and ImageBuilder by default (see
"Build methods" in the README). The ImageBuilder installs the captured world
packages in place of its default package selection and records the package
list in `metadata/imagebuilder-packages.txt`. With `--build-method source`,
captured world packages are added to the device configuration
using the pinned OpenWrt package metadata, including the mapping from ABI-suffixed
APK names to Kconfig symbols. A newly installed package such as `htop` is selected
even if it was absent from the saved `diffconfig`. The builder rejects packages
that are unavailable or cannot be selected for the target before downloading
sources or compiling. Review `reports/world-config.tsv` and
`reports/world-unselected-package-names.txt` when diagnosing package selection.
The final manifest still must contain every required world package.

## Check the repository changes

After preparation, review the changed lock and device baseline files:

```sh
git diff -- <lock-file> devices
```

Run the focused validation checks before relying on the updated inputs:

```sh
bash -n scripts/*.sh scripts/**/*.sh locks/*.lock
shellcheck --severity=warning -x scripts/*.sh scripts/**/*.sh
shellcheck --severity=warning --shell=bash --exclude=SC2034 locks/*.lock
scripts/ci/check-locks.sh
scripts/ci/check-build-names.sh
scripts/ci/check-prepare-openwrt-upgrade.sh
scripts/ci/check-upgrade-router-image.sh
scripts/ci/check-prebuilt-apks.sh
scripts/ci/check-world-config.sh
scripts/ci/check-ec2-cleanup.sh
```

These checks do not replace the firmware build. They validate the repository
inputs and helper scripts.

## Verify the fetched artifacts

When the build finishes and artifacts have been fetched, verify the local
checksums before copying anything to the router:

```sh
cd ./openwrt-artifacts/<build>
sha256sum -c sha256sums.txt
```

Use the `*sysupgrade.bin` image for an installed router. Do not flash an
initramfs image through this sysupgrade flow.

## Run preflight without flashing

Use the helper in no-flash mode first:

```sh
./scripts/upgrade-router-image.sh --no-flash <ssh-target> ./openwrt-artifacts/<build>/<image-sysupgrade.bin>
```

This step:

- creates a local router configuration backup under `./backups/`;
- copies the sysupgrade image to `/tmp/` on the router;
- verifies the remote SHA-256 against the local image;
- runs `sysupgrade -T`;
- stops before flashing.

Do not continue if this command fails.

## Flash the image

After the no-flash preflight succeeds, flash with an interactive confirmation:

```sh
./scripts/upgrade-router-image.sh <ssh-target> ./openwrt-artifacts/<build>/<image-sysupgrade.bin>
```

For an already-confirmed maintenance window, the prompt can be skipped:

```sh
./scripts/upgrade-router-image.sh --yes <ssh-target> ./openwrt-artifacts/<build>/<image-sysupgrade.bin>
```

Expect SSH to disconnect while `sysupgrade` reboots the router.

## Manual flashing equivalent

If you do not use `scripts/upgrade-router-image.sh`, perform the same safety
checks manually:

```sh
mkdir -p ./backups
ssh <ssh-target> 'sysupgrade -b /tmp/pre-upgrade-backup.tar.gz'
scp -O <ssh-target>:/tmp/pre-upgrade-backup.tar.gz ./backups/
scp -O ./openwrt-artifacts/<build>/<image-sysupgrade.bin> <ssh-target>:/tmp/
sha256sum ./openwrt-artifacts/<build>/<image-sysupgrade.bin>
ssh <ssh-target> 'sha256sum /tmp/<image-sysupgrade.bin>'
ssh <ssh-target> 'sysupgrade -T /tmp/<image-sysupgrade.bin>'
ssh <ssh-target> 'sysupgrade /tmp/<image-sysupgrade.bin>'
```

Compare the router-side SHA-256 with the local image before running
`sysupgrade -T`. Run the final `sysupgrade` only if the test passes.

## Stop conditions

Stop and investigate before flashing if any of these happen:

- the dry run selects an unexpected release, target, profile, or lock file;
- the router board name does not match the selected lock;
- ASU metadata validation fails;
- any captured `apk world` package is missing from the built image;
- artifact checksum verification fails;
- `sysupgrade -T` fails;
- the image path is not a `*sysupgrade.bin` file.

## Cleanup

`scripts/run-ec2-build.sh` cleans up its temporary EC2 instance and security
group automatically unless `--keep-instance` is used. If you used
`scripts/orchestrate-ec2-build.sh` against a manually created EC2 host,
terminate the disposable builder and remove any build-only storage after
artifacts are fetched.
