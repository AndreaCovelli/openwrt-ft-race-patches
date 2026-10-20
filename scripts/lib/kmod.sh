#!/usr/bin/env bash

# Helpers for scripts/build-kmod.sh. They only read their arguments and print
# results, so the CI self-test can exercise them with synthetic release
# metadata and ELF objects.

kmod_die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

# Print "sha256<TAB>path" for the single sha256sums entry whose path matches
# the extended regular expression PATTERN.
kmod_release_entry() {
  local sums="$1"
  local pattern="$2"
  local -a matches=()

  mapfile -t matches < <(
    awk -v pattern="$pattern" '{ file = $2; sub(/^\*/, "", file); if (file ~ pattern) print $1 "\t" file }' \
      "$sums"
  )
  ((${#matches[@]} == 1)) ||
    kmod_die "expected one release file matching $pattern, found ${#matches[@]}" ||
    return 1
  [[ "${matches[0]%%$'\t'*}" =~ ^[0-9a-f]{64}$ ]] ||
    kmod_die "release sha256sums has an invalid checksum for ${matches[0]#*$'\t'}" ||
    return 1
  printf '%s\n' "${matches[0]}"
}

# Match the dots of a release version or target name literally. Callers
# validate those names to [A-Za-z0-9._-] first.
kmod_regex_escape() {
  printf '%s' "${1//./[.]}"
}

# Print "url ref" from the base feed line of an SDK feeds.conf.default. The
# official SDK pins the release's OpenWrt commit there.
kmod_sdk_base_feed() {
  local feeds_conf="$1"
  local -a lines=()

  mapfile -t lines < <(grep -E '^src-git --root=package base ' "$feeds_conf")
  ((${#lines[@]} == 1)) ||
    kmod_die "expected one base feed in $feeds_conf, found ${#lines[@]}" ||
    return 1
  [[ "${lines[0]}" =~ ^src-git\ --root=package\ base\ (https://[A-Za-z0-9./_~:+-]+)\^([0-9a-f]{40})$ ]] ||
    kmod_die "unsupported SDK base feed definition: ${lines[0]}" ||
    return 1
  printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Print the strings of one ELF section, one per line. A missing section
# prints nothing.
kmod_elf_strings() {
  local file="$1"
  local section="$2"

  { readelf -W -p "$section" "$file" 2>/dev/null || true; } |
    sed -n 's/^ *\[ *[0-9a-f]*\]  //p'
}

# Print the module metadata that must match the official module: every
# .modinfo entry except srcversion, which hashes the module sources.
kmod_modinfo() {
  kmod_elf_strings "$1" .modinfo | sed '/^srcversion=/d' | LC_ALL=C sort
}

# Print the symbols the module exports.
kmod_exports() {
  kmod_elf_strings "$1" __ksymtab_strings | LC_ALL=C sort -u
}

# Print the symbols the module imports.
kmod_imports() {
  readelf -W -s "$1" | awk '$7 == "UND" && $8 != "" { print $8 }' | LC_ALL=C sort -u
}

# Print "path<TAB>type" for every non-directory entry below DIR.
kmod_tree_listing() {
  (cd "$1" && find . ! -type d -printf '%P\t%y\n') | LC_ALL=C sort
}
