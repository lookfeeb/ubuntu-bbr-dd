#!/usr/bin/env bash
set -Eeuo pipefail
# Keep unchanged file mtimes, but give changed content a new mtime so Make
# cannot reuse an object newer than an old timestamp in the upstream archive.
rsync -a --no-times --checksum "${1:?Source tree}/" "${2:?Build tree}/"
