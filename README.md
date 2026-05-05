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
- EC2 orchestrator: `./scripts/orchestrate-ec2-build.sh <ssh-target> locks/<device>.lock`
- full EC2 lifecycle wrapper: `./scripts/run-ec2-build.sh locks/<device>.lock`

Build verification:
- Builds fail by default if the generated package manifest differs from the
  reference manifest, including missing packages, extra packages, version
  mismatches, or missing `apk world` package names.
- Build artifacts include `logs/build.log` with the builder stdout/stderr.
  If OpenWrt writes package build logs, those are saved under `logs/openwrt/`.
- Lock files can list `MANIFEST_BUILTIN_PACKAGE_NAMES` for packages that are
  intentionally built into the kernel on a target and therefore do not appear
  as installed packages in the generated manifest.
- To allow intentional package drift while still writing drift reports, run with
  `STRICT_MANIFEST=0 ./scripts/build-image.sh locks/<device>.lock` or pass
  `--no-strict-manifest` to the EC2 orchestrator.

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
5. Run `./scripts/build-image.sh locks/your-device.lock`.

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
- The EC2 Docker builder uses `ubuntu:noble-20260410` and the Ubuntu
  `20260410T000000Z` apt snapshot by default. Override with
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
  `./scripts/orchestrate-ec2-build.sh --fetch-artifacts ./openwrt-artifacts/wr3000p my-ec2 locks/build-wr3000p.lock`
- Example with one-command EC2 provisioning and cleanup:
  `./scripts/run-ec2-build.sh --make-jobs 4 --download-jobs 8 locks/build-wr3000e.lock`

Flashing the fetched image:
- Verify the local artifact checksums before copying anything to the router:
  `cd ./openwrt-artifacts/wr3000p && sha256sum -c sha256sums.txt`
- Copy the matching `*sysupgrade.bin` image to the router, not the initramfs
  image. OpenWrt Dropbear commonly lacks SFTP, so force legacy SCP mode:
  `scp -O *sysupgrade.bin root@192.168.1.1:/tmp/`
- On the router, test the image first:
  `sysupgrade -T /tmp/<image-sysupgrade.bin>`
- If the test passes, run the actual upgrade with verbose output:
  `sysupgrade -v /tmp/<image-sysupgrade.bin>`

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
