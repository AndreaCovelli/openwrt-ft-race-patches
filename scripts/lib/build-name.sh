#!/usr/bin/env bash

openwrt_build_name_die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

openwrt_build_name_require_component() {
  local name="$1"
  local value="$2"

  [[ -n "$value" ]] ||
    openwrt_build_name_die "$name must not be empty" ||
    return 1

  case "$value" in
    *[!A-Za-z0-9._-]*)
      openwrt_build_name_die "$name contains unsupported characters: $value" ||
        return 1
      ;;
  esac
}

openwrt_build_name_version() {
  local openwrt_tag="${OPENWRT_TAG:-}"
  local openwrt_ref="${OPENWRT_REF:-}"

  if [[ -n "$openwrt_tag" ]]; then
    printf '%s\n' "${openwrt_tag#v}"
    return 0
  fi

  [[ "$openwrt_ref" =~ ^[0-9a-f]{40}$ ]] ||
    openwrt_build_name_die "OPENWRT_REF must be a full 40-character lowercase hex commit when OPENWRT_TAG is empty" ||
    return 1

  printf 'ref-%s\n' "${openwrt_ref:0:12}"
}

openwrt_default_build_name() {
  local timestamp="${1:-}"
  local device_id="${DEVICE_ID:-}"
  local artifact_variant="${ARTIFACT_VARIANT:-}"
  local openwrt_version

  if [[ -z "$timestamp" ]]; then
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  fi

  openwrt_build_name_require_component DEVICE_ID "$device_id" || return 1
  openwrt_build_name_require_component ARTIFACT_VARIANT "$artifact_variant" || return 1
  openwrt_build_name_require_component timestamp "$timestamp" || return 1

  openwrt_version="$(openwrt_build_name_version)" || return 1
  openwrt_build_name_require_component openwrt_version "$openwrt_version" || return 1

  printf 'openwrt-ft-%s-%s-%s-%s\n' \
    "$device_id" \
    "$openwrt_version" \
    "$artifact_variant" \
    "$timestamp"
}

openwrt_default_build_name_from_lock() {
  local lock_file="$1"
  local timestamp="${2:-}"
  local line name value

  (
    unset OPENWRT_TAG OPENWRT_REF DEVICE_ID ARTIFACT_VARIANT

    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]+(OPENWRT_TAG|OPENWRT_REF|DEVICE_ID|ARTIFACT_VARIANT)= ]]; then
        openwrt_build_name_die "unsupported indented lock assignment for build-name field: $line" ||
          exit 1
      fi

      case "$line" in
        OPENWRT_TAG=\'*\'|OPENWRT_REF=\'*\'|DEVICE_ID=\'*\'|ARTIFACT_VARIANT=\'*\')
          name="${line%%=*}"
          value="${line#*=}"
          value="${value#\'}"
          value="${value%\'}"
          case "$name" in
            OPENWRT_TAG|OPENWRT_REF|DEVICE_ID|ARTIFACT_VARIANT)
              printf -v "$name" '%s' "$value"
              ;;
          esac
          ;;
        OPENWRT_TAG=*|OPENWRT_REF=*|DEVICE_ID=*|ARTIFACT_VARIANT=*)
          openwrt_build_name_die "unsupported lock assignment for build-name field: $line" ||
            exit 1
          ;;
      esac
    done <"$lock_file"

    openwrt_default_build_name "$timestamp"
  )
}
