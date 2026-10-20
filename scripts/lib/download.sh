#!/usr/bin/env bash

# HTTPS downloads shared by the build and pin scripts. Functions return 1
# after printing an error, so callers decide whether to exit.

download_die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

download_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

# Download URL to DEST over HTTPS only, including redirects. The optional
# MAX_TIME bounds the whole transfer in seconds.
download_https() {
  local url="$1"
  local dest="$2"
  local max_time="${3:-1800}"

  curl -fsSL \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 10 \
    --max-time "$max_time" \
    --retry 3 \
    --retry-connrefused \
    -o "$dest" \
    "$url" ||
    download_die "failed to download $url" ||
    return 1
}

# Download URL to DEST unless DEST already has the expected checksum. A
# mismatch fails closed; the optional HINT explains how to refresh the pin.
download_verified_file() {
  local url="$1"
  local dest="$2"
  local expected="$3"
  local hint="${4:-}"
  local tmp actual

  if [[ -f "$dest" ]] && [[ "$(download_sha256 "$dest")" == "$expected" ]]; then
    return 0
  fi

  mkdir -p "$(dirname -- "$dest")" || return 1
  tmp="$(mktemp "$dest.tmp.XXXXXXXX")" || return 1
  if ! download_https "$url" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  actual="$(download_sha256 "$tmp")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f -- "$tmp"
    download_die "sha256 mismatch for $url: expected $expected got $actual${hint:+; $hint}" ||
      return 1
  fi
  mv -f -- "$tmp" "$dest"
}
