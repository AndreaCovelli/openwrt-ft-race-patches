Patch bundle for the OpenWrt `hostapd: nl80211: kernel reports: key addition failed` FT race.

Use `patches/subsys/390-mac80211-defer-ap-side-ft-key-upload.patch` in:
`package/kernel/mac80211/patches/subsys/`

This repo also contains a generic reproducible OpenWrt builder plus example
device inputs.

Build entrypoints:
- generic: `./scripts/build-image.sh locks/<device>.lock`
- example wrapper: `./scripts/build-wr3000.sh`
- example wrapper: `./scripts/build-wr3000e.sh`
- example wrapper: `./scripts/build-wr3000p.sh`
- ASU-like latest release preparation:
  `./scripts/prepare-openwrt-upgrade.sh wr3000e locks/build-wr3000e.lock -- --make-jobs 4 --download-jobs 8`
- EC2 orchestrator: `./scripts/orchestrate-ec2-build.sh <ssh-target> locks/<device>.lock`
- full EC2 lifecycle wrapper: `./scripts/run-ec2-build.sh locks/<device>.lock`
- router image upgrade helper:
  `./scripts/upgrade-router-image.sh --no-flash wr3000e ./openwrt-artifacts/<build>/<image-sysupgrade.bin>`

Build verification:
- Builds fail by default if the generated package manifest differs from the
  reference manifest, including missing packages, extra packages, version
  mismatches, or missing `apk world` package names.
- Default build/session artifact bundle names follow:
  `openwrt-ft-<device-id>-<openwrt-version>-<variant>-<utc-build-id>`.
  The actual OpenWrt firmware image filenames are left unchanged.
- Build artifacts include `logs/build.log` with the builder stdout/stderr.
  If OpenWrt writes package build logs, those are saved under `logs/openwrt/`.
- Lock files can list `MANIFEST_BUILTIN_PACKAGE_NAMES` for packages that are
  intentionally built into the kernel on a target and therefore do not appear
  as installed packages in the generated manifest.
- To allow intentional package drift while still writing drift reports, run with
  `STRICT_MANIFEST=0 ./scripts/build-image.sh locks/<device>.lock` or pass
  `--no-strict-manifest` to the EC2 orchestrator. Missing `apk world` package
  names are always fatal, even when strict manifest checking is disabled.

ASU-like latest release preparation:
- `scripts/prepare-openwrt-upgrade.sh` follows the attended-sysupgrade style of
  selecting the latest available release for the router's current stable branch
  and preserving the router's live `apk world`, but it still builds with this
  repo's patched OpenWrt builder instead of the public ASU image builder.
- The command reads `/etc/openwrt_release`, `attendedsysupgrade.server.url`,
  `/etc/apk/world`, and the installed apk database from the router over SSH.
  It validates target/profile availability against the ASU server, verifies the
  router board is supported by that profile, updates only the selected stable
  lock file to exact OpenWrt and release feed commits, refreshes that device's
  package baseline, then starts `scripts/run-ec2-build.sh` with
  `--no-strict-manifest` for the transition build. The build still fails if any
  package from the router's captured `apk world` is missing from the image.
- Use `--dry-run` to print the selected release, lock changes, package baseline
  paths, and EC2 build command without writing files or starting a build. Use
  `--version 25.12.4` to prepare a specific release instead of the latest
  same-branch ASU release.
- Set `BUILD_SCRIPT=/path/to/build-wrapper` to delegate to a different
  compatible build wrapper. It must accept `--no-strict-manifest` and the lock
  file path.
- If the router already runs the selected latest release, the command refreshes
  the package baseline and exits without starting a build.
- The command does not copy or flash firmware. After the artifact is fetched,
  verify checksums, copy the `*sysupgrade.bin` image to the router, back up the
  router configuration, run `sysupgrade -T`, then flash manually or with
  `scripts/upgrade-router-image.sh` as described below.

Refreshing the mac80211 patch:
- Run this before orchestration when the patch changes and needs to be
  normalized for OpenWrt submission. The command must run from a full OpenWrt
  checkout because it uses OpenWrt's mac80211 package, build rules, and quilt
  patch stack.
- Copy the local patch into the OpenWrt checkout, refresh it there, copy the
  refreshed patch back into this repo, then update the lock-file checksum before
  building:

```sh
OPENWRT=/path/to/openwrt
PATCH=patches/subsys/390-mac80211-defer-ap-side-ft-key-upload.patch
DEST=package/kernel/mac80211/patches/subsys/390-mac80211-defer-ap-side-ft-key-upload.patch

cp "$PATCH" "$OPENWRT/$DEST"

(
  cd "$OPENWRT"
  make package/mac80211/{clean,refresh} V=99
)

cp "$OPENWRT/$DEST" "$PATCH"
sha256sum "$PATCH"
```

- Copy the printed SHA-256 into `PATCH_SHA256` in the relevant `locks/*.lock`,
  then run `./scripts/orchestrate-ec2-build.sh <ssh-target> locks/<device>.lock`.

What it fixes:
- `mac80211` no longer rejects the AP-side pairwise key install that happens during the FT pre-`ASSOC` timing window just because `WLAN_STA_ASSOC` is not set yet.
- The first hardware `set_key()` attempt is skipped until the STA is associated; the later `AUTHORIZED` transition is only an extra retry point, so this is not the naive "delete the check and stay on software crypto forever" workaround.
- The current patch accepts only AP / AP_VLAN pre-`ASSOC` pairwise keys when a STA object already exists, then relies on the deferred upload path to push them to hardware once the STA transitions into the ready state.

Device lock inputs in this repo:
- `locks/build-wr3000.lock`
- `locks/build-wr3000e.lock`
- `locks/build-wr3000p.lock`
- `locks/build-wr3000e-main.lock` for a main-branch compile check only

Example device metadata in this repo:
- `devices/wr3000/diffconfig`
- `devices/wr3000/installed.manifest`
- `devices/wr3000/apk-installed-and-world.txt`
- `devices/wr3000e/diffconfig`
- `devices/wr3000e/installed.manifest`
- `devices/wr3000e/apk-installed-and-world.txt`
- `devices/wr3000p/diffconfig`
- `devices/wr3000p/installed.manifest`
- `devices/wr3000p/apk-installed-and-world.txt`

To add another router:
1. Save a `diffconfig` for the target profile.
2. Save the router's installed manifest and `apk world`.
3. Create a `devices/<name>/` directory for those files.
4. Copy one of the files in `locks/` and update `CONFIG_FRAGMENT`, `WORLD_SOURCE`, `REFERENCE_MANIFEST`, and `DEVICE_ID`.
5. Set `ARTIFACT_VARIANT` to a short intent label such as `patched`.
6. Run `./scripts/build-image.sh locks/your-device.lock`.

EC2 orchestration:
- `scripts/orchestrate-ec2-build.sh` uploads a fresh snapshot of this repo to the EC2 host, prepares a per-run remote workspace, builds `docker/Dockerfile.ec2`, and starts the image build in a detached `tmux` session.
- `scripts/run-ec2-build.sh` provisions a temporary EC2 builder, creates a
  temporary SSH-only security group restricted to the current client public IP,
  runs the orchestrator through a temporary SSH config file, fetches artifacts,
  and terminates/deletes the temporary EC2 resources on exit. By default it
  uses a `c8a.xlarge` instance and a 30 GiB gp3 root volume; set `--key-name`
  and `--key-file` when the defaults do not match your AWS account.
- The upload snapshot contains tracked repo files by default. Pass
  `--include-untracked` only when intentionally sending untracked, non-ignored
  local files to the EC2 host.
- By default it auto-installs `tmux` and Docker on the EC2 host if they are
  missing, and installs Docker Buildx when the host package manager provides it.
  It supports hosts with `apt-get`, `dnf`, or `yum`; use `--no-install-prereqs`
  to disable that.
- Docker build and run use `--platform linux/amd64` by default so EC2 host
  architecture does not silently change the builder environment. Override with
  `--platform linux/arm64` only when intentionally using an arm64 builder.
- The EC2 Docker builder pulls the private prebuilt image
  `ghcr.io/andreacovelli/patch-fix-repo/openwrt-builder:ubuntu-noble-20260410-snapshot-20260410t000000z@sha256:dd52704e37949d9e815ddc762c422258e13d6783371b7eabcde759b02e85650f`
  by default. Because the image is private, set `GHCR_TOKEN`, `GITHUB_TOKEN`, or
  `GITHUB_PAT_TOKEN` locally with package read access so the remote host can
  authenticate to GHCR before pulling. The orchestrator uses `GHCR_USERNAME`
  when set, otherwise `GITHUB_ACTOR`, otherwise the locally authenticated
  `gh` CLI account. Use
  `--rebuild-builder-image` to rebuild `docker/Dockerfile.ec2` on the remote
  host. When rebuilding, the Dockerfile uses `ubuntu:noble-20260410` and the
  Ubuntu `20260410T000000Z` apt snapshot by default. Override with
  `--builder-base-image` or `--ubuntu-snapshot` only when intentionally moving
  the builder environment.
- The builder disables OpenWrt ccache and keeps only the source download cache.
  For a disposable single-device EC2 build, a 30 GiB gp3 root volume is usually
  enough; use 40 GiB for extra margin, or more only if reusing the instance or
  keeping multiple build runs.
- To automatically copy the finished images back to the local machine, pass
  `--fetch-artifacts <local-dir>`. This waits for the remote `tmux` build to
  finish, then copies the remote `output/` contents and logs to the local
  directory.
  If the image build produced `output/` and then failed during strict manifest
  verification, artifacts, logs, and `reports/` are still copied before the
  script returns the remote failure status. The outer EC2 build log is saved as
  `logs/ec2-build.log`.
- Example:
  `./scripts/orchestrate-ec2-build.sh my-ec2 locks/build-wr3000p.lock`
- Example with local artifact fetch:
  `./scripts/orchestrate-ec2-build.sh --session openwrt-ft-cudy_wr3000p-v1-25.12.4-patched-20260520T143000Z --fetch-artifacts ./openwrt-artifacts/openwrt-ft-cudy_wr3000p-v1-25.12.4-patched-20260520T143000Z my-ec2 locks/build-wr3000p.lock`
- Example with one-command EC2 provisioning and cleanup:
  `./scripts/run-ec2-build.sh --make-jobs 4 --download-jobs 8 locks/build-wr3000e.lock`

Flashing the fetched image:
- Verify the local artifact checksums before copying anything to the router:
  `cd ./openwrt-artifacts/openwrt-ft-cudy_wr3000p-v1-25.12.4-patched-20260520T143000Z && sha256sum -c sha256sums.txt`
- To automate the backup, copy, checksum, and test steps without flashing:
  `./scripts/upgrade-router-image.sh --no-flash wr3000p ./openwrt-artifacts/<build>/<image-sysupgrade.bin>`
- The helper writes router config backups under `./backups/` by default using
  `sysupgrade -b`, copies the matching `*sysupgrade.bin` image to `/tmp/`,
  verifies the remote SHA-256 against the local image, and runs
  `sysupgrade -T`.
- To run the same preflight and then flash after an interactive confirmation:
  `./scripts/upgrade-router-image.sh wr3000p ./openwrt-artifacts/<build>/<image-sysupgrade.bin>`
- To skip the prompt in an already-confirmed maintenance window:
  `./scripts/upgrade-router-image.sh --yes wr3000p ./openwrt-artifacts/<build>/<image-sysupgrade.bin>`
- Manual equivalent: copy the matching `*sysupgrade.bin` image to the router,
  not the initramfs image. OpenWrt Dropbear commonly lacks SFTP, so force legacy
  SCP mode with `scp -O`. On the router, run `sysupgrade -T` first; only if the
  test passes, run the actual `sysupgrade`.

Manual EC2 cleanup:
- `scripts/run-ec2-build.sh` cleans up its temporary instance and security group
  automatically unless `--keep-instance` is set.
- If using `scripts/orchestrate-ec2-build.sh` against a manually created EC2
  host, terminate the disposable build instance after artifacts are fetched.
- Delete any build-only EBS volumes or snapshots that were not removed with the
  instance, and release any Elastic IP or other public IPv4 address that is not
  being reused.

Important config caveat:
- If your SSIDs use `sae` or `sae-mixed`, do not force `ft_psk_generate_local '1'`. On current OpenWrt this should stay `0`; if `r0kh`/`r1kh` are not set explicitly, OpenWrt will derive them from the shared FT secret material.
- For the current `psk2` setup on these three routers, only flip `ft_psk_generate_local` to `0` if every FT AP will derive the same FT key material or you provide matching `r0kh`/`r1kh` entries explicitly.

References:
- Current upstream `cfg.c`: `https://github.com/torvalds/linux/blob/master/net/mac80211/cfg.c`
- Current OpenWrt `openwrt-25.12` `ap.uc`: `https://github.com/openwrt/openwrt/blob/openwrt-25.12/package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/ap.uc`
- OpenWrt FT generation change history: `https://lists.infradead.org/pipermail/lede-commits/2024-December/023531.html`
