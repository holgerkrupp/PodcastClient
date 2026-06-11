#!/bin/sh

set -eu

if [ "${SKIP_BUILD_NUMBER_INCREMENT:-0}" = "1" ]; then
    echo "Skipping build number increment."
    exit 0
fi

project_root="${SRCROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
version_file="${project_root}/Config/Version.xcconfig"

current_version="$(
    sed -nE \
        's/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' \
        "${version_file}"
)"

case "${current_version}" in
    ''|*[!0-9]*)
        echo "error: Could not read CURRENT_PROJECT_VERSION from ${version_file}" >&2
        exit 1
        ;;
esac

next_version=$((current_version + 1))
temporary_file="$(mktemp "${TMPDIR:-/tmp}/upnext-version.XXXXXX")"
trap 'rm -f "${temporary_file}"' EXIT HUP INT TERM

awk -v next_version="${next_version}" '
    /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/ {
        print "CURRENT_PROJECT_VERSION = " next_version
        next
    }
    { print }
' "${version_file}" > "${temporary_file}"

chmod "$(stat -f '%Lp' "${version_file}")" "${temporary_file}"
mv "${temporary_file}" "${version_file}"
trap - EXIT HUP INT TERM

echo "Incremented build number from ${current_version} to ${next_version}."
