#!/usr/bin/env bash
#
# Print a local image's unpacked and compressed sizes in bytes, as
# "unpacked=<bytes>" and "compressed=<bytes>" lines (GITHUB_OUTPUT format).
#
#   Usage: scripts/image-size.sh <image>
#
# `docker images` and `docker image inspect` report different things depending
# on the image store: with the containerd store (GitHub runners), `docker images`
# shows unpacked plus compressed bytes and `inspect` shows only compressed
# bytes. Measure both directly instead, so every runner reports the same
# numbers. Unpacked is the sum of the layer sizes; compressed is the gzipped
# `docker save` output, close to what `docker pull` downloads.
set -euo pipefail

IMAGE="${1:?usage: image-size.sh <image>}"

unpacked="$(docker history --human=false --format '{{.Size}}' "$IMAGE" | awk '{ total += $1 } END { print total }')"
compressed="$(docker save "$IMAGE" | gzip -6 | wc -c | tr -d ' ')"

echo "unpacked=${unpacked}"
echo "compressed=${compressed}"
