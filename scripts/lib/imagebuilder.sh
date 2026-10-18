#!/usr/bin/env bash

# Helpers for the SDK + ImageBuilder build method. They only read their
# arguments and print results, so the CI self-test can exercise them with
# synthetic ImageBuilder metadata.

imagebuilder_die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

# Split an IMAGEBUILDER_REPOSITORIES entry ("url|sha256") into two variables.
imagebuilder_parse_repository() {
  local entry="$1"
  local -n out_url="$2"
  local -n out_sha256="$3"
  local extra

  IFS='|' read -r out_url out_sha256 extra <<<"$entry"
  [[ -n "$out_url" && -n "$out_sha256" && -z "$extra" ]] ||
    imagebuilder_die "IMAGEBUILDER_REPOSITORIES entries must use url|sha256 format: $entry" ||
    return 1
  [[ "$out_url" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/+-]+/packages\.adb$ ]] ||
    imagebuilder_die "IMAGEBUILDER_REPOSITORIES URL must be an https packages.adb URL: $out_url" ||
    return 1
  [[ "$out_sha256" =~ ^[0-9a-f]{64}$ ]] ||
    imagebuilder_die "IMAGEBUILDER_REPOSITORIES sha256 for $out_url must be a 64-character lowercase hex checksum" ||
    return 1
}

# apk-tools stores a remote index in its cache directory under the first eight
# hex digits of the SHA-256 of the repository URL.
imagebuilder_index_cache_name() {
  local url="$1"
  local digest

  digest="$(printf '%s' "$url" | sha256sum | cut -c1-8)"
  printf 'APKINDEX.%s.tar.gz\n' "$digest"
}

# Print the "Default Packages" list from a saved `make -s info` output.
imagebuilder_info_default_packages() {
  awk '
    /^Default Packages:/ {
      sub(/^Default Packages:[[:space:]]*/, "")
      n = split($0, packages, /[[:space:]]+/)
      for (i = 1; i <= n; i++)
        if (packages[i] != "") print packages[i]
      found = 1
      exit
    }
    END { exit !found }
  ' "$1"
}

# Print the profile package list from a saved `make -s info` output. A
# profile without a Packages line has no profile packages.
imagebuilder_info_profile_packages() {
  awk -v profile="$2" '
    $0 == profile ":" { in_profile = 1; found = 1; next }
    in_profile && /^[^[:space:]]/ { exit }
    in_profile && /^[[:space:]]+Packages:/ {
      sub(/^[[:space:]]+Packages:[[:space:]]*/, "")
      n = split($0, packages, /[[:space:]]+/)
      for (i = 1; i <= n; i++)
        if (packages[i] != "") print packages[i]
      exit
    }
    END { exit !found }
  ' "$1"
}

# Print package names satisfied by the resolved world: the resolved package
# symbols plus everything those packages provide.
imagebuilder_satisfied_names() {
  awk '
    FILENAME == ARGV[1] {
      split($0, fields, "\t")
      if (fields[2] != "-") symbols[fields[2]] = 1
      next
    }
    $1 == "Package:" {
      package = $2
      if (package in symbols) print package
      next
    }
    $1 == "Provides:" && (package in symbols) {
      for (i = 2; i <= NF; i++) {
        name = $i
        sub(/^@/, "", name)
        sub(/=.*/, "", name)
        if (name != "") print name
      }
    }
  ' "$2" "$1" | LC_ALL=C sort -u
}

# Print "-package" removals for default and profile packages that the
# captured world does not keep, so the image contains the world rather than
# the default selection plus the world.
# Arguments: info output, profile, package metadata, resolved world TSV.
imagebuilder_default_removals() {
  local info_file="$1"
  local profile="$2"
  local packageinfo="$3"
  local resolved="$4"
  local satisfied package
  local -a selected=()
  local -A seen=()

  satisfied="$(imagebuilder_satisfied_names "$packageinfo" "$resolved")"
  mapfile -t selected < <(
    imagebuilder_info_default_packages "$info_file" &&
      imagebuilder_info_profile_packages "$info_file" "$profile"
  )
  ((${#selected[@]} > 0)) ||
    imagebuilder_die "ImageBuilder info has no default or profile packages for $profile" ||
    return 1

  for package in "${selected[@]}"; do
    [[ "$package" != -* ]] || continue
    [[ -z "${seen[$package]:-}" ]] || continue
    seen[$package]=1
    if ! grep -Fqx -- "$package" <<<"$satisfied"; then
      printf -- '-%s\n' "$package"
    fi
  done
}

# Print the kernel package version shipped in a pristine ImageBuilder
# packages directory.
imagebuilder_kernel_version() {
  local packages_dir="$1"
  local -a kernels=()

  mapfile -t kernels < <(find "$packages_dir" -maxdepth 1 -type f -name 'kernel-*.apk' -printf '%f\n')
  ((${#kernels[@]} == 1)) ||
    imagebuilder_die "expected exactly one kernel package in $packages_dir, found ${#kernels[@]}" ||
    return 1
  printf '%s\n' "${kernels[0]#kernel-}" | sed 's/\.apk$//'
}

# Print the single apk for package NAME in DIR. Version strings start with a
# digit, which keeps kmod-mac80211 from matching kmod-mac80211-hwsim.
imagebuilder_find_package_apk() {
  local dir="$1"
  local name="$2"
  local file
  local -a matches=()

  while IFS= read -r file; do
    if [[ "${file#"$name"-}" =~ ^[0-9] ]]; then
      matches+=("$dir/$file")
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name "$name-*.apk" -printf '%f\n' | LC_ALL=C sort)

  ((${#matches[@]} == 1)) ||
    imagebuilder_die "expected exactly one $name apk in $dir, found ${#matches[@]}" ||
    return 1
  printf '%s\n' "${matches[0]}"
}
