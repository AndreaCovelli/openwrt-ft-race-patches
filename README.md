Patch bundle for the OpenWrt `hostapd: nl80211: kernel reports: key addition failed` FT race.

Use `patches/subsys/999-mac80211-ft-defer-preassoc-key-upload.patch` in:
`package/kernel/mac80211/patches/subsys/`

This repo also contains a generic reproducible OpenWrt builder plus example
device inputs.

Build entrypoints:
- generic: `./scripts/build-image.sh locks/<device>.lock`
- example wrapper: `./scripts/build-wr3000e.sh`
- example wrapper: `./scripts/build-wr3000p.sh`
- EC2 orchestrator: `./scripts/orchestrate-ec2-build.sh <ssh-target> locks/<device>.lock`

Build verification:
- Builds fail by default if the generated package manifest differs from the
  reference manifest, including missing packages, extra packages, version
  mismatches, or missing `apk world` package names.
- To allow intentional package drift while still writing drift reports, run with
  `STRICT_MANIFEST=0 ./scripts/build-image.sh locks/<device>.lock` or pass
  `--no-strict-manifest` to the EC2 orchestrator.

What it fixes:
- `mac80211` no longer rejects the AP-side pairwise key install that happens during the FT pre-`ASSOC` timing window just because `WLAN_STA_ASSOC` is not set yet.
- The first hardware `set_key()` attempt is skipped until the STA is associated; the later `AUTHORIZED` transition is only an extra retry point, so this is not the naive "delete the check and stay on software crypto forever" workaround.
- The current patch accepts only AP / AP_VLAN pre-`ASSOC` pairwise keys when a STA object already exists, then relies on the deferred upload path to push them to hardware once the STA transitions into the ready state.

Device lock inputs in this repo:
- `locks/build-wr3000e.lock`
- `locks/build-wr3000p.lock`

Example device metadata in this repo:
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
- The upload snapshot contains tracked repo files by default. Pass
  `--include-untracked` only when intentionally sending untracked, non-ignored
  local files to the EC2 host.
- By default it auto-installs `tmux` and Docker on the EC2 host if they are
  missing. It supports hosts with `apt-get`, `dnf`, or `yum`; use
  `--no-install-prereqs` to disable that.
- Docker build and run use `--platform linux/amd64` by default so EC2 host
  architecture does not silently change the builder environment. Override with
  `--platform linux/arm64` only when intentionally using an arm64 builder.
- The EC2 Docker builder uses `ubuntu:noble-20260410` and the Ubuntu
  `20260410T000000Z` apt snapshot by default. Override with
  `--builder-base-image` or `--ubuntu-snapshot` only when intentionally moving
  the builder environment.
- Example:
  `./scripts/orchestrate-ec2-build.sh my-ec2 locks/build-wr3000p.lock`

Important config caveat:
- If your SSIDs use `sae` or `sae-mixed`, do not force `ft_psk_generate_local '1'`. On current OpenWrt this should stay `0`; if `r0kh`/`r1kh` are not set explicitly, OpenWrt will derive them from the shared FT secret material.
- For the current `psk2` setup on these three routers, only flip `ft_psk_generate_local` to `0` if every FT AP will derive the same FT key material or you provide matching `r0kh`/`r1kh` entries explicitly.

References:
- Current upstream `cfg.c`: `https://github.com/torvalds/linux/blob/master/net/mac80211/cfg.c`
- Current OpenWrt `openwrt-25.12` `ap.uc`: `https://github.com/openwrt/openwrt/blob/openwrt-25.12/package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/ap.uc`
- OpenWrt FT generation change history: `https://lists.infradead.org/pipermail/lede-commits/2024-December/023531.html`
