#!/usr/bin/env bash
set -euo pipefail

# Resolve installed APK names to Kconfig package symbols using the pinned
# tree's tmp/.packageinfo. ABI suffixes follow include/feeds.mk:FormatABISuffix.
# Arguments: package metadata, captured world, built-in package names.
world_config_resolve() {
  awk '
    function add(name, symbol) {
      if (name in symbols && symbols[name] != symbol) ambiguous[name] = 1
      symbols[name] = symbol
    }
    function package_end(    suffix) {
      if (package == "") return
      add(package, package)
      if (abi != "" && package !~ /^kmod-/) {
        suffix = (package ~ /[0-9]$/ ? "-" : "") abi
        add(package suffix, package)
      }
    }
    FILENAME == ARGV[1] {
      if ($1 == "Package:") {
        package_end()
        package = $2
        abi = ""
      } else if ($1 == "ABI-Version:") {
        abi = $2
      }
      next
    }
    !flushed { package_end(); flushed = 1 }
    FILENAME == ARGV[2] { builtin[$0] = 1; next }
    {
      name = $0
      sub(/=.*/, "", name)
      if (name !~ /^[A-Za-z0-9][A-Za-z0-9+_.-]*$/) {
        printf "error: unsupported apk world entry: %s\n", $0 > "/dev/stderr"
        failed = 1
      } else if (name in builtin) {
        next
      } else if (name == "kernel") {
        # package/kernel/linux builds this unconditionally and omits it from
        # DUMP metadata. It still must appear in the final image manifest.
        printf "kernel\t-\n"
      } else if (!(name in symbols) || name in ambiguous) {
        printf "error: cannot resolve apk world package in pinned OpenWrt metadata: %s\n", name > "/dev/stderr"
        failed = 1
      } else {
        printf "%s\t%s\n", name, symbols[name]
      }
    }
    END { exit failed }
  ' "$1" "$3" "$2"
}

# Print world packages that Kconfig did not select for inclusion in the image.
world_config_missing() {
  awk '
    FILENAME == ARGV[1] {
      if ($0 ~ /^CONFIG_PACKAGE_.+=y$/) {
        symbol = $0
        sub(/^CONFIG_PACKAGE_/, "", symbol)
        sub(/=y$/, "", symbol)
        selected[symbol] = 1
      }
      next
    }
    $2 != "-" && !($2 in selected) { print $1 }
  ' "$2" "$1"
}

# Replace existing settings for required symbols, keeping all other config.
world_config_apply() {
  awk '
    FILENAME == ARGV[1] {
      if ($2 == "-") next
      if (!($2 in required)) order[++count] = $2
      required[$2] = 1
      next
    }
    {
      symbol = $0
      sub(/^# /, "", symbol)
      if (symbol ~ /^CONFIG_PACKAGE_/) {
        sub(/^CONFIG_PACKAGE_/, "", symbol)
        sub(/[= ].*/, "", symbol)
        if (symbol in required) next
      }
      print
    }
    END {
      for (i = 1; i <= count; i++) printf "CONFIG_PACKAGE_%s=y\n", order[i]
    }
  ' "$1" "$2"
}
