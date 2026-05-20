#!/usr/bin/env bash

local_feed_digest() {
  local feed_path="$1"

  (
    cd "$feed_path" || exit
    find . -type f -print0 |
      sort -z |
      xargs -0 -r sha256sum |
      sha256sum |
      awk '{ print $1 }'
  )
}
