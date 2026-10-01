#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
deployment_target=${PRIVATE_PODCAST_ACCESS_DEPLOYMENT_TARGET:-26.0}

cd "$repo_root"

check_platform() {
    sdk_name=$1
    target_platform=$2
    sdk_path=$(xcrun --sdk "$sdk_name" --show-sdk-path)

    echo "Checking private podcast access for $sdk_name"
    xcrun swiftc \
        -typecheck \
        -module-name PrivatePodcastAccessCheck \
        -target "arm64-apple-${target_platform}${deployment_target}" \
        -sdk "$sdk_path" \
        Raul/Shared/Extensions/DateExtensions.swift \
        Raul/Shared/Extensions/URLextension.swift \
        Raul/Shared/Services/PodcastAccess.swift
}

case "${1:-all}" in
all)
    check_platform iphoneos ios
    check_platform macosx macosx
    check_platform watchos watchos
    check_platform appletvos tvos
    ;;
iphoneos)
    check_platform iphoneos ios
    ;;
macosx)
    check_platform macosx macosx
    ;;
watchos)
    check_platform watchos watchos
    ;;
appletvos)
    check_platform appletvos tvos
    ;;
*)
    echo "usage: $0 [all|iphoneos|macosx|watchos|appletvos]" >&2
    exit 2
    ;;
esac
