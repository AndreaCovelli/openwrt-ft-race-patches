Patch bundle for the OpenWrt `hostapd: nl80211: kernel reports: key addition failed` FT race.

It contains `400-mac80211-defer-ap-side-ft-key-upload.patch`, refreshed for
each supported OpenWrt release under `patches/<release>/subsys/` (for example
`patches/25.12.5/subsys/`) and installed into
`package/kernel/mac80211/patches/subsys/`.

This repo also contains a generic reproducible OpenWrt builder plus example
device inputs.

See the [FT key upload race guide](docs/ft-key-upload-race/README.md) for the
patch behavior, driver constraints, and roaming checks.

Build entrypoints:
- generic: `./scripts/build-image.sh --builder-id <builder-id> locks/<device>.lock`
- example wrapper: `./scripts/build-wr3000.sh`
- example wrapper: `./scripts/build-wr3000e.sh`
- example wrapper: `./scripts/build-wr3000p.sh`
- ASU-like latest release preparation:
  `./scripts/prepare-openwrt-upgrade.sh wr3000e locks/build-wr3000e.lock -- --make-jobs 4 --download-jobs 8`
- stable upgrade guide:
  [docs/stable-openwrt-upgrade.md](docs/stable-openwrt-upgrade.md)
- local Docker builder: `./scripts/run-local-docker-build.sh locks/<device>.lock`
- EC2 orchestrator: `./scripts/orchestrate-ec2-build.sh <ssh-target> locks/<device>.lock`
- full EC2 lifecycle wrapper: `./scripts/run-ec2-build.sh locks/<device>.lock`
- router image upgrade helper:
  `./scripts/upgrade-router-image.sh --no-flash wr3000e ./openwrt-artifacts/<build>/<image-sysupgrade.bin>`
- patched `kmod-mac80211` for a stock release, without an image:
  `./scripts/build-kmod.sh 25.12.6 mediatek/filogic`

Development checks:
- Install the checksum-locked tools with `mise install`.
- Run the complete local validation suite with `mise run check`.
- Run an individual group with `mise run check:shell`,
  `mise run check:metadata`, or `mise run check:links`. The shell group also
  lints `docker/Dockerfile.ec2` with hadolint.

Build verification:
- Builds fail by default if the generated package manifest differs from the
  reference manifest, including missing packages, extra packages, version
  mismatches, or missing `apk world` package names.
- Default build/session artifact bundle names follow:
  `openwrt-ft-<device-id>-<openwrt-version>-<variant>-<utc-build-id>`.
  The actual OpenWrt firmware image filenames are left unchanged.
- Local Docker builds reuse `build/openwrt-ft-<device-id>-ib` for
  ImageBuilder builds and `build/openwrt-ft-<device-id>-dev` for source
  builds by default, while every local session still gets its own timestamped
  `openwrt-artifacts/<session>/` bundle. Direct builds use the same stable
  workspace default. Use `--workspace <name>` for an independent tree for the
  same device.
- Local artifact destinations must be new directories outside the build
  workspace and cache. The wrapper verifies checksums in a temporary directory
  before publishing the bundle and refuses to overwrite an existing path,
  including one created while the build runs.
- Build artifacts include `logs/build.log` with the builder stdout/stderr.
  If OpenWrt writes package build logs, those are saved under `logs/openwrt/`.
- Lock files can list `MANIFEST_BUILTIN_PACKAGE_NAMES` for packages that are
  intentionally built into the kernel on a target and therefore do not appear
  as installed packages in the generated manifest.
- Local `src-link` feeds are build inputs, not public runtime repositories.
  Every `LOCAL_FEEDS` entry must have a matching
  `CONFIG_FEED_<name>=m` line in `EXTRA_CONFIG_LINES`; OpenWrt then keeps the
  generated runtime URL commented out while still building selected packages
  from that feed into the image.
- Lock files can list `PREBUILT_APKS` for pinned binary APK inputs. The builder
  downloads those APKs into `DL_DIR`, verifies their SHA-256 checksums, and
  writes `metadata/prebuilt-apks.tsv` into the artifact bundle. Private GitHub
  release assets use the local `gh auth token` credential first, then
  `GITHUB_TOKEN` if the GitHub CLI token is unavailable. The EC2 orchestrator
  downloads those assets locally and copies them into the remote download cache
  so GitHub repository credentials are not sent to the remote host.
- Source builds select captured `apk world` packages in addition to the device
  `diffconfig`. It maps ABI-suffixed APK names to Kconfig symbols using the
  pinned OpenWrt package metadata, then runs `make defconfig` and checks that
  each required package is selected for the image. Unavailable names or
  selections rejected by target dependencies fail before source downloads and
  compilation. The mapping is saved in `reports/world-config.tsv`. OpenWrt's
  automatic `kernel` package and the lock's explicit built-in package exceptions
  need no Kconfig selection; final manifest requirements still apply.
- To allow intentional package drift while still writing drift reports, run with
  `STRICT_MANIFEST=0 ./scripts/build-image.sh --builder-id <builder-id> locks/<device>.lock`
  or pass
  `--no-strict-manifest` to the local Docker builder or EC2 orchestrator.
  Missing `apk world` package names are always fatal, even when strict
  manifest checking is disabled.

Build methods:
- `--build-method imagebuilder` is the default for the stable locks, which set
  `DEFAULT_BUILD_METHOD='imagebuilder'`. It downloads the release's official
  SDK and ImageBuilder, rebuilds only the packages that carry a pinned patch
  in the SDK, and assembles the image with the ImageBuilder from the official
  release packages, the SDK-built `IMAGEBUILDER_PATCHED_PACKAGES`, and the
  lock's `PREBUILT_APKS`. Only `kmod-mac80211` is replaced; the kernel, its
  other modules, and every other package are the official release builds.
- `--build-method source` builds the whole tree from the pinned OpenWrt
  checkout and feeds, as before. Locks without `DEFAULT_BUILD_METHOD`,
  including `locks/build-wr3000e-main.lock`, use it. Use it for initramfs
  images, for patches outside mac80211, and for local feed packages that do
  not have a `PREBUILT_APKS` entry.
- ImageBuilder builds produce only the sysupgrade image; `initramfs_image` and
  `initramfs_sha256` are empty in `build-summary.txt`.
- The lock pins `SDK_URL`, `SDK_SHA256`, `IMAGEBUILDER_URL`,
  `IMAGEBUILDER_SHA256`, and every apk repository index the ImageBuilder
  uses in `IMAGEBUILDER_REPOSITORIES` (`url|sha256`). The build verifies the
  SDK feed commits against the lock's OpenWrt and feed pins, the ImageBuilder
  repository list against the pinned index URLs, and the SDK's mac80211
  package options against the release `.config` shipped in the ImageBuilder.
  It seeds apk with the pinned indexes, which keep package signature checks
  enabled, and fails if an index changes during the image build.
- OpenWrt rebuilds release indexes when it republishes packages. A build then
  fails before compiling with a checksum mismatch for the index URL until the
  lock is refreshed with `./scripts/pin-imagebuilder.sh locks/<device>.lock`
  (use `--dry-run` to print the new pins first). The script reads the
  release's `sha256sums`, `profiles.json`, and `feeds.buildinfo`, requires
  them to match the lock's release, target, device, and feed pins, and
  rewrites only the ImageBuilder assignments.
- The SDK packages its prebuilt kernel modules before compiling mac80211 so
  OpenWrt's package dependency check passes; only the patched packages reach
  the image. After the image build, every file of each injected package must
  be byte-identical in the image root, and every symlink must have the same
  target, so apk cannot silently pick the equally versioned official package.
  `PREBUILT_APKS` names count as available world packages even when the
  release metadata does not list them.
- The image kernel must equal the ImageBuilder's kernel package. The
  reference manifest's `kernel` line is recorded as
  `reference_kernel_version` and is not counted as a version mismatch;
  `image_kernel_version` shows the shipped kernel.
- The captured `apk world` replaces the ImageBuilder's default package
  selection: defaults that the world neither lists nor provides are removed.
  The package list passed to the ImageBuilder is saved as
  `metadata/imagebuilder-packages.txt`, and the injected packages with their
  checksums as `metadata/imagebuilder-injected.tsv`.
- OpenWrt keeps rebuilding a release's package repositories from the release
  branch after the tag, so an ImageBuilder image installs those newer
  userland packages (for example LuCI and hostapd revisions) rather than the
  versions built from the lock's feed commits. The index pins make that set
  reproducible; the feed pins still describe the SDK source. Expect version
  drift against a reference manifest captured from a source-built image, and
  use `--no-strict-manifest` for that first ImageBuilder build; strict
  checking applies again once the reference is refreshed from a router that
  runs an ImageBuilder image.
- Index files are cached by checksum under `cache/imagebuilder/indexes/`, and
  apk's package downloads under `cache/imagebuilder/apk-cache/`, shared by
  builds with the same index pins.

Patched kmod-mac80211 for a stock release:
- `scripts/build-kmod.sh <openwrt-version> <target>/<subtarget>` builds only
  the patched `kmod-mac80211` package for an official release. It needs no
  lock file, device inputs, Docker, or private release assets, so it works for
  any release and target that publishes an SDK.
- It reads the release `sha256sums` and `profiles.json`, then downloads and
  verifies the release SDK and the official `kmod-mac80211` package against
  them. Pass `--sdk-sha256 <hex>` to also require a known SDK checksum. The
  SDK's base feed is checked out at the OpenWrt commit the SDK records, the
  patch is added to the mac80211 package, and the SDK compiles mac80211 with
  the release package configuration.
- The build fails unless the patch is present in the prepared mac80211 source
  tree and the patched package matches the official one: the same file name
  and version, the same file list, the same module metadata (`vermagic`,
  `depends`, `name`, and the other `.modinfo` entries except `srcversion`),
  and the same exported symbols. At least one module must differ from the
  official build. Symbols the patched modules import but the official modules
  do not are listed in `metadata/new-imports.txt` and counted as
  `new_imports` in `build-summary.txt`.
- By default the build applies every patch in `patches/<version>/subsys/`,
  the patches refreshed for that release, and stops if the release has none.
  Pass repeatable `--patch <file>` to use others. The build stops if a patch
  does not apply to the release's backports version; refresh it for that
  release first.
- Artifacts go to a new
  `openwrt-artifacts/openwrt-ft-kmod-mac80211-<version>-<target>-<subtarget>-<utc>/`
  directory (or `--artifact-dir <new-dir>`): the patched package with its
  official file name, the extracted `mac80211.ko`, `sha256sums.txt`,
  `build-summary.txt`, the patches, the SDK `.config`, the release metadata,
  and `logs/build.log`. The workspace is
  `build/openwrt-ft-kmod-<version>-<target>-<subtarget>`; rerun with
  `--fresh` to replace it. The SDK archive is cached in `cache/dl`.
- The host needs the usual OpenWrt SDK build prerequisites plus `curl`, `jq`,
  `zstd`, and `readelf`. `docker/Dockerfile.ec2` installs all of them except
  `jq`.
- The module only loads on a router running exactly that release and target.
  Confirm that `DISTRIB_RELEASE` and `DISTRIB_TARGET` in
  `/etc/openwrt_release` match `openwrt_version` and `target` in
  `build-summary.txt`, and that the router has the file named by
  `module_path`. To use the module, keep a copy of the router's
  `module_path` file, replace it with the artifact's `mac80211.ko`, and
  reboot. Copy the saved module back to revert.
- The package is not signed with the release key, and its name and version
  are the same as the official package. Any `apk` reinstall or upgrade of
  `kmod-mac80211`, a sysupgrade, or an attended sysupgrade image brings back
  the official module.

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
  package baseline, refreshes the lock's ImageBuilder pins with
  `scripts/pin-imagebuilder.sh` when it has them, then starts
  `scripts/run-ec2-build.sh` with
  `--no-strict-manifest` for the transition build. The build still fails if any
  package from the router's captured `apk world` is missing from the image.
- Use `--dry-run` to print the selected release, lock changes, package baseline
  paths, and EC2 build command without writing files or starting a build. Use
  `--version 25.12.4` to prepare a specific release instead of the latest
  same-branch ASU release.
- `PREBUILT_APKS` are compiled against one OpenWrt release. When a filename
  names the lock's current release but not the selected one, a real run stops
  before changing files; publish a matching `usteer-apk-builder` release and
  update the lock first. `--dry-run` only warns, and
  `--allow-prebuilt-apk-mismatch` deliberately keeps the old APK.
- Set `BUILD_SCRIPT=/path/to/build-wrapper` to delegate to a different
  compatible build wrapper. It must accept `--no-strict-manifest` and the lock
  file path.
- If the router already runs the selected latest release, the command refreshes
  the package baseline and exits without starting a build.
- The command does not copy or flash firmware. After the artifact is fetched,
  verify checksums, copy the `*sysupgrade.bin` image to the router, back up the
  router configuration, run `sysupgrade -T`, then flash manually or with
  `scripts/upgrade-router-image.sh` as described below.

Refreshing pinned patches:
- Each OpenWrt release can ship a different backports version, so the stable
  patch is kept per release in `patches/<release>/subsys/`. To support a new
  release, copy the previous release's patch to
  `patches/<new-release>/subsys/` with the same file name and refresh the copy
  in a checkout of the new release. Leave the earlier release's directory
  unchanged for its locks and module builds. `scripts/ci/check-locks.sh`
  requires a tagged lock's patches in `patches/<OPENWRT_TAG without v>/subsys/`
  and the untagged `main` lock's in `patches/main/subsys/`.
- Run the package-specific refresh before orchestration when a patch changes
  and needs to be normalized for OpenWrt submission. The command must run from
  a full OpenWrt checkout because it uses OpenWrt package build rules and quilt
  patch stacks.
- For the mac80211 patch, copy the local patch into the OpenWrt checkout,
  refresh it there, copy the refreshed patch back into this repo, then update
  `PATCH_SHA256` before building:

```sh
OPENWRT=/path/to/openwrt  # checked out at the release's tag
RELEASE=25.12.5
PATCH=patches/$RELEASE/subsys/400-mac80211-defer-ap-side-ft-key-upload.patch
DEST=package/kernel/mac80211/patches/subsys/400-mac80211-defer-ap-side-ft-key-upload.patch

cp "$PATCH" "$OPENWRT/$DEST"

(
  cd "$OPENWRT"
  make package/mac80211/{clean,refresh} V=99
)

cp "$OPENWRT/$DEST" "$PATCH"
sha256sum "$PATCH"
```

- Copy the printed SHA-256 into `PATCH_SHA256` in the locks for that release,
  then run `./scripts/orchestrate-ec2-build.sh <ssh-target> locks/<device>.lock`.
- `scripts/ci/check-locks.sh` also requires every local feed package that
  repackages an APK to name the same `PKG_SOURCE` and `PKG_HASH` as the lock's
  `PREBUILT_APKS` entry.

What it fixes:
- The mac80211 patch follows wireless-next v4 (source commit
  `33d4e0eb234c721f655bf6386ca3faf62f09626d`). The 25.12.5 copy is adapted to
  that release's backports 6.18.26 sources.
- When automatic software fallback is allowed, `mac80211` accepts AP / AP_VLAN
  pre-`ASSOC` pairwise keys once a STA object exists and marks each accepted
  key for deferred hardware upload. Drivers advertising `SW_CRYPTO_CONTROL`
  retain the existing rejection.
- The deferred marker skips the initial hardware `set_key()` call. After the
  driver completes the STA's `AUTH`-to-`ASSOC` transition, mac80211 scans the
  STA's PTK slots, refreshes each marked key's PMF (`RX_MGMT`) and SPP A-MSDU
  flags from the association parameters, and uploads it. The refreshed flags
  are computed locally and published with `WRITE_ONCE()` so RX/TX readers
  cannot observe a temporary cleared state. Keys remain usable through
  software crypto if hardware upload fails.

Device lock inputs in this repo:
- `locks/build-wr3000.lock`
- `locks/build-wr3000e.lock`
- `locks/build-wr3000p.lock`
- `locks/build-wr3000e-main.lock` for a main-branch compile check only. It
  uses `patches/main/subsys/400-wifi-mac80211-defer-ap-side-ft-key-upload.patch`,
  the patch refreshed for the backports version on OpenWrt `main`.

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
6. Run `./scripts/pin-imagebuilder.sh locks/your-device.lock` so the
   ImageBuilder pins match the new target.
7. Run `./scripts/run-local-docker-build.sh locks/your-device.lock`.

Local Docker builds:
- `scripts/run-local-docker-build.sh` runs the same pinned builder image used by
  the EC2 wrapper, mounts this repo at `/workspace`, and writes artifacts to
  `openwrt-artifacts/<build>/`.
- The first build seeds the workspace; later compatible builds reuse its
  OpenWrt checkout and compiled tree, or its extracted SDK and ImageBuilder.
  The workspace is locked against concurrent builds and is retained after
  success or failure.
- The wrapper mounts the selected workspace at `/build` and sets
  `WORKSPACE_PATH=/build`, so every workspace and device compiles under the
  same absolute path and shares ccache entries. EC2 builds use the same mount.
- Source builds clone OpenWrt and every feed as partial clones
  (`--filter=blob:none`) at the pinned commits: full history for version
  stamps, but file contents only for the checked-out tree.
- `--fresh` safely replaces only the selected workspace and performs a full
  build. Use `--workspace <name>` when one device needs multiple independent
  build trees.
- A full build records its prepared state once the checkout, feeds, patches,
  and final `.config` are in place. If that first build fails later, the next
  run resumes it (`build_mode=resume`) instead of requiring `--fresh`.
- Patch checksum changes automatically clean and compile the `mac80211`
  package before the normal incremental image build.
  Identical patches keep their existing timestamps so OpenWrt preparation
  stamps remain valid for packages that have not changed. Local feed content or
  `PREBUILT_APKS` changes likewise rebuild the packages in
  `LOCAL_FEED_INSTALLS`.
  Use repeatable `--rebuild-package mac80211`,
  `--rebuild-package local-feeds`, or `--rebuild-package all` to force those
  steps without changing an input.
- Reuse is refused when pinned repositories, feeds, target/config baselines,
  patch topology, local feed names and paths, ccache mode, platform, or builder
  image identity differs. Reference manifest and world inputs are compared after
  each build instead. The diagnostic lists the changed keys; rerun with
  `--fresh` only after confirming the replacement is intended. Workspaces
  created by older versions of the builder, including every workspace from
  before state schema 3 (which added the build method and the fixed
  workspace path), require one fresh build. `--fresh` clears the workspace
  contents in place, so it also works on the mounted directory.
- ImageBuilder workspaces rebuild the image from the pristine ImageBuilder
  package directory on every run. A patch change cleans and recompiles the SDK
  mac80211 package; `--rebuild-package local-feeds` is rejected because
  prebuilt APKs are injected directly.
- Builds enable OpenWrt's `CONFIG_BUILD_LOG`, so each package's compiler output
  is copied to `logs/openwrt/` in the artifact directory, including after a
  failure.
- The wrapper mounts the repo-local `cache/` directory at `/cache`. OpenWrt
  source downloads use `/cache/dl`, so repeated local builds reuse the same
  download cache instead of writing downloads under the per-build tree.
- OpenWrt ccache is enabled by default for local Docker builds. It uses
  `cache/ccache` on the host, `/cache/ccache` in the container, and a default
  `CCACHE_MAXSIZE` of `20G`. Use `--ccache-maxsize <size>` to override the
  limit or `--no-ccache` for a cache-free workspace (an existing workspace
  with the other ccache mode must be replaced with `--fresh`).
- Source builds key ccache on the OpenWrt commit, builder image, and
  toolchain configuration rather than compiler timestamps; ImageBuilder
  builds key it on the SDK checksum and builder image. A fresh workspace
  rebuilds or re-extracts its cross-compiler, so the default mtime check would
  otherwise miss every cached object. The fixed `/build` path keeps objects
  that embed absolute paths identical across workspaces, so a fresh
  workspace for the same pins reuses the cache.
- The container runs as the invoking user's UID and GID, so the workspace,
  cache, and artifacts stay owned by that user. UIDs other than the image's
  UID 1000 get `HOME=/tmp` inside the container.
- The default builder image is `DEFAULT_BUILDER_IMAGE` in
  `scripts/lib/builder-image.sh`. A digest-pinned image that is already
  present locally is not pulled again. Use
  `--no-pull --builder-image <local-tag>` when testing a locally rebuilt
  builder image that has not been pushed to a registry.
- When a lock uses private `PREBUILT_APKS`, the wrapper downloads and verifies
  those APKs on the host using `gh auth token` or `GITHUB_TOKEN`, then stores
  them in `cache/dl` before starting the builder container. GitHub repository
  credentials are not passed into the container.
- Pass `--cache-dir <dir>` to use a different host cache directory, and
  `--rebuild-builder-image` only when intentionally rebuilding
  `docker/Dockerfile.ec2` locally.
- Direct `scripts/build-image.sh` calls expose the same `--workspace`,
  `--fresh`, and repeatable `--rebuild-package` options. They also require
  `--builder-id <id>` (or `BUILDER_ID`) so a workspace cannot be reused across
  an unrecorded builder-environment change. The Docker wrapper inspects the
  selected image and supplies its immutable image ID automatically.
- The device wrappers use `direct-host` as the default direct-builder identity
  so their zero-argument examples remain usable. Set `BUILDER_ID` explicitly
  when switching the host toolchain or maintaining more than one direct build
  environment.

EC2 orchestration:
- `scripts/orchestrate-ec2-build.sh` uploads a fresh snapshot of this repo to the EC2 host, prepares a per-run remote workspace, builds `docker/Dockerfile.ec2`, and starts the image build in a detached `tmux` session.
- EC2 workspaces remain session-scoped and disposable: every remote run is a
  full build and does not reuse a prior OpenWrt compiled tree.
- `scripts/run-ec2-build.sh` provisions a temporary EC2 builder, creates a
  temporary SSH-only security group restricted to the current client public IP,
  runs the orchestrator through a temporary SSH config file, fetches artifacts,
  and terminates/deletes the temporary EC2 resources on exit. By default it
  uses a `c8a.xlarge` instance and a 30 GiB gp3 root volume; set `--key-name`
  and `--key-file` when the defaults do not match your AWS account.
- The wrapper requests a one-time spot instance by default and falls back to
  on-demand, with the spot error logged, when capacity is unavailable. A spot
  reclaim ends that run; the wrapper names the cause, and `--on-demand` avoids
  it for builds that must not be interrupted.
- Boot-time user data arms `shutdown -h +360`, which terminates the instance
  after six hours even if the local machine loses its connection before
  cleanup. Adjust with `--max-runtime-minutes <n>` or disable with `0`. The
  limit also applies with `--keep-instance`.
- The same user data installs `tmux`, Docker, and Buildx while SSH comes up,
  and the wrapper polls SSH directly instead of waiting for EC2 status checks.
  The orchestrator waits for cloud-init before checking prerequisites.
- The temporary SSH config uses a per-run `known_hosts` file, keepalives, and
  one multiplexed connection for all polls and copies. Build polling tolerates
  about 10 minutes of consecutive SSH failures before giving up with a
  reattach command.
- The artifact directory must not exist yet; the wrapper checks before
  creating any AWS resource.
- Cleanup retries failed termination, termination waits, and security group
  deletion up to three times. Persistent failures report the AWS diagnostics,
  resource IDs, and region for manual cleanup, and make an otherwise successful
  build command exit nonzero. An existing build failure keeps its exit status.
  `--keep-instance` intentionally retains the instance and security group.
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
  `ghcr.io/andreacovelli/openwrt-ft-race-patches/openwrt-builder:ubuntu-noble-20260410-snapshot-20260410t000000z@sha256:ddd581ad95983400564b019d362b674eb24ecd096ca8cb4fc64cc6f5a86a0ea5`
  by default. Because the image is private, set `GHCR_TOKEN` locally with
  package read access so the remote host can authenticate to GHCR before
  pulling. The orchestrator uses `GHCR_USERNAME` when set, otherwise
  `GITHUB_ACTOR`, otherwise the locally authenticated `gh` CLI account. When a
  lock uses private `PREBUILT_APKS`, the orchestrator downloads and verifies
  those APKs locally using `gh auth token` or `GITHUB_TOKEN`, copies them into
  the remote download cache, and does not pass GitHub repository credentials
  into the remote host or builder container.
  Both host authentication lookups retain the caller's `PATH`, including a
  `gh` installation managed by Mise.
  Use
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
  `--fetch-artifacts <local-dir>` naming a directory that does not exist yet.
  This waits for the remote `tmux` build to finish, copies the remote
  `output/` contents and logs into a staging directory, verifies
  `sha256sums.txt`, and only then moves the staging directory into place.
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
- When `sha256sums.txt` sits next to the image, as in fetched artifact
  directories, the image must match its entry before the router is contacted.
  The local backup must be a readable gzip tar archive before the router-side
  copy is removed; otherwise the helper stops and keeps the router copy.
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

License:
- GPL-2.0-only. See [LICENSE](LICENSE).
