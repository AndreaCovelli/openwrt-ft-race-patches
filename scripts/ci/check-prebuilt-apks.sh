#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"

# shellcheck source=scripts/lib/prebuilt-apks.sh
source "$repo_root/scripts/lib/prebuilt-apks.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  [[ -f "$1" ]] || die "expected file to exist: $1"
}

assert_file_missing() {
  [[ ! -e "$1" ]] || die "expected file to be absent: $1"
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  grep -Fq -- "$pattern" "$file" || die "expected $file to contain: $pattern"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"

  if grep -Fq -- "$pattern" "$file"; then
    die "did not expect $file to contain: $pattern"
  fi
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/prebuilt-apks-test.XXXXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

bin_dir="$tmp_root/bin"
dl_dir="$tmp_root/dl"
mkdir -p "$bin_dir" "$dl_dir"

cat >"$bin_dir/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_CURL_LOG:?}"
payload_file="${FAKE_CURL_PAYLOAD:?}"
output=''
headers=()

while [[ $# -gt 0 ]]; do
  printf 'arg=%s\n' "$1" >>"$log_file"
  case "$1" in
    -H)
      headers+=("$2")
      shift 2
      ;;
    -o)
      output="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      printf 'url=%s\n' "$1" >>"$log_file"
      shift
      ;;
  esac
done

printf 'headers=%s\n' "${headers[*]}" >>"$log_file"
[[ -f "$output" && ! -L "$output" ]] || {
  printf 'expected curl output path to be an existing non-symlink temp file: %s\n' "$output" >&2
  exit 1
}
cp "$payload_file" "$output"
SH
chmod +x "$bin_dir/curl"

cat >"$bin_dir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == 'auth' && "${2:-}" == 'token' ]] || exit 1
case "${FAKE_GH_TOKEN_MODE:-missing}" in
  token)
    printf '%s\n' "${FAKE_GH_TOKEN:?}"
    ;;
  empty)
    ;;
  missing)
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$bin_dir/gh"

export PATH="$bin_dir:$PATH"
export FAKE_CURL_LOG="$tmp_root/curl.log"
payload="$tmp_root/payload.apk"
json_payload="$tmp_root/payload.json"
printf 'valid apk bytes\n' >"$payload"
printf '{"message":"metadata, not an asset"}\n' >"$json_payload"
valid_sha="$(sha256sum "$payload" | awk '{ print $1 }')"
entry="usteer|usteer.apk|https://api.github.com/repos/owner/repo/releases/assets/1|$valid_sha"

unset GITHUB_TOKEN
export FAKE_GH_TOKEN_MODE='missing'
export FAKE_CURL_PAYLOAD="$json_payload"
if prebuilt_apk_download_one "$dl_dir" "$entry" >/dev/null 2>&1; then
  die 'JSON API response unexpectedly passed checksum validation'
fi
assert_file_missing "$dl_dir/usteer.apk"
if compgen -G "$dl_dir/usteer.apk.tmp.*" >/dev/null; then
  die 'temporary APK download file was not cleaned after checksum failure'
fi
assert_contains "$FAKE_CURL_LOG" 'Accept: application/octet-stream'
assert_contains "$FAKE_CURL_LOG" 'arg=--proto'
assert_contains "$FAKE_CURL_LOG" 'arg==https'
assert_contains "$FAKE_CURL_LOG" 'arg=--proto-redir'
assert_contains "$FAKE_CURL_LOG" 'arg=--connect-timeout'
assert_contains "$FAKE_CURL_LOG" 'arg=10'
assert_contains "$FAKE_CURL_LOG" 'arg=--max-time'
assert_contains "$FAKE_CURL_LOG" 'arg=300'
assert_contains "$FAKE_CURL_LOG" 'arg=--retry'
assert_contains "$FAKE_CURL_LOG" 'arg=3'
assert_contains "$FAKE_CURL_LOG" 'arg=--retry-connrefused'
assert_not_contains "$FAKE_CURL_LOG" 'Authorization: Bearer'

printf 'corrupt cached apk\n' >"$dl_dir/usteer.apk"
: >"$FAKE_CURL_LOG"
export FAKE_CURL_PAYLOAD="$payload"
prebuilt_apk_download_one "$dl_dir" "$entry" 2>/dev/null
assert_file_exists "$dl_dir/usteer.apk"
[[ "$(sha256sum "$dl_dir/usteer.apk" | awk '{ print $1 }')" == "$valid_sha" ]] ||
  die 'expected corrupt cached APK to be replaced with valid payload'
assert_contains "$FAKE_CURL_LOG" 'Accept: application/octet-stream'

: >"$FAKE_CURL_LOG"
export FAKE_GH_TOKEN_MODE='empty'
export GITHUB_TOKEN='env-token'
rm -f "$dl_dir/usteer.apk"
prebuilt_apk_download_one "$dl_dir" "$entry"
assert_contains "$FAKE_CURL_LOG" 'Authorization: Bearer env-token'

: >"$FAKE_CURL_LOG"
export FAKE_GH_TOKEN_MODE='token'
export FAKE_GH_TOKEN='gh-token'
export GITHUB_TOKEN='env-token'
rm -f "$dl_dir/usteer.apk"
prebuilt_apk_download_one "$dl_dir" "$entry"
assert_contains "$FAKE_CURL_LOG" 'Authorization: Bearer gh-token'
assert_not_contains "$FAKE_CURL_LOG" 'Authorization: Bearer env-token'
