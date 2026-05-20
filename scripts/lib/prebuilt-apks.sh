#!/usr/bin/env bash

prebuilt_apk_die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

prebuilt_apk_parse_entry() {
  local entry="$1"
  local -n out_name="$2"
  local -n out_file="$3"
  local -n out_url="$4"
  local -n out_sha256="$5"

  IFS='|' read -r out_name out_file out_url out_sha256 <<<"$entry"
  [[ -n "$out_name" && -n "$out_file" && -n "$out_url" && -n "$out_sha256" ]] ||
    prebuilt_apk_die "PREBUILT_APKS entries must use name|filename|url|sha256 format"
}

prebuilt_apk_verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  actual="$(sha256sum "$file" | awk '{ print $1 }')"
  [[ "$actual" == "$expected" ]] ||
    prebuilt_apk_die "sha256 mismatch for $file: expected $expected got $actual"
}

prebuilt_apk_download_token() {
  printf '%s\n' "${GITHUB_TOKEN:-${GITHUB_PAT_TOKEN:-}}"
}

prebuilt_apk_download_one() {
  local dl_dir="$1"
  local entry="$2"
  local name file url sha256 dest tmp_dest token
  local -a curl_args=()

  prebuilt_apk_parse_entry "$entry" name file url sha256
  [[ "$file" != */* && "$file" != .* ]] ||
    prebuilt_apk_die "PREBUILT_APKS filename must be a plain basename: $file"
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] ||
    prebuilt_apk_die "PREBUILT_APKS sha256 for $name must be a 64-character lowercase hex checksum"

  mkdir -p "$dl_dir"
  dest="$dl_dir/$file"
  if [[ -f "$dest" ]]; then
    if prebuilt_apk_verify_sha256 "$dest" "$sha256"; then
      return 0
    fi
    rm -f "$dest"
  fi

  tmp_dest="$dest.tmp.$$"
  rm -f "$tmp_dest"

  if [[ "$url" == https://api.github.com/* ]]; then
    curl_args+=(
      -H 'Accept: application/octet-stream'
      -H 'X-GitHub-Api-Version: 2022-11-28'
    )
    token="$(prebuilt_apk_download_token)"
    if [[ -n "$token" ]]; then
      curl_args+=(-H "Authorization: Bearer $token")
    fi
  fi

  if ! curl -fsSL \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 10 \
    --max-time 300 \
    --retry 3 \
    --retry-connrefused \
    "${curl_args[@]}" \
    -o "$tmp_dest" \
    "$url"; then
    rm -f "$tmp_dest"
    prebuilt_apk_die "failed to download prebuilt APK: $name"
  fi

  if ! prebuilt_apk_verify_sha256 "$tmp_dest" "$sha256"; then
    rm -f "$tmp_dest"
    return 1
  fi

  mv "$tmp_dest" "$dest"
}

prebuilt_apk_download_all() {
  local dl_dir="$1"
  shift

  local entry
  for entry in "$@"; do
    prebuilt_apk_download_one "$dl_dir" "$entry"
  done
}
