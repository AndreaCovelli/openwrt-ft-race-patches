#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/lib/builder-image.sh
source "$repo_root/scripts/lib/builder-image.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

builder_image_is_digest_pinned "$DEFAULT_BUILDER_IMAGE" ||
  die "DEFAULT_BUILDER_IMAGE must be pinned by sha256 digest: $DEFAULT_BUILDER_IMAGE"

grep -Fq "\`$DEFAULT_BUILDER_IMAGE\`" "$repo_root/README.md" ||
  die 'README.md does not name DEFAULT_BUILDER_IMAGE from scripts/lib/builder-image.sh'

# Other copies would silently drift from the shared default.
mapfile -t stale_refs < <(
  git -C "$repo_root" grep --untracked -n -F "${DEFAULT_BUILDER_IMAGE%%:*}:" -- 'scripts/*.sh' 'scripts/**/*.sh' |
    grep -v '^scripts/lib/builder-image\.sh:' || true
)
if ((${#stale_refs[@]} > 0)); then
  printf '%s\n' "${stale_refs[@]}" >&2
  die 'builder image references must use DEFAULT_BUILDER_IMAGE'
fi

base_image_line="$(grep -E '^ARG BUILDER_BASE_IMAGE=' "$repo_root/docker/Dockerfile.ec2")" ||
  die 'docker/Dockerfile.ec2 is missing ARG BUILDER_BASE_IMAGE'
builder_image_is_digest_pinned "${base_image_line#ARG BUILDER_BASE_IMAGE=}" ||
  die "docker/Dockerfile.ec2 base image must be pinned by sha256 digest: $base_image_line"

printf 'builder image references are consistent\n'
