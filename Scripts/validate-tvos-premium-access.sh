#!/bin/sh

set -eu

# Keep this compatibility entry point for CI and existing documentation. The
# shared gate also checks iOS/iPadOS, macOS, and watchOS when invoked with its
# default `all` argument.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PRIVATE_PODCAST_ACCESS_DEPLOYMENT_TARGET="${TVOS_DEPLOYMENT_TARGET:-26.0}" \
    exec sh "$script_dir/validate-private-podcast-access.sh" appletvos
