#!/bin/sh
set -eu

if [ -n "${CONTAINER_APP_PATH:-}" ]; then
    plist="${CONTAINER_APP_PATH}/PlugIns/UpNextWatchComplications.appex/Info.plist"
else
    plist="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Info.plist"
fi
if [ ! -f "$plist" ]; then
    echo "error: watch complication Info.plist was not produced: $plist" >&2
    exit 1
fi

raw() {
    /usr/bin/plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true
}

bundle_id="$(raw CFBundleIdentifier)"
executable="$(raw CFBundleExecutable)"
package_type="$(raw CFBundlePackageType)"
short_version="$(raw CFBundleShortVersionString)"
build_version="$(raw CFBundleVersion)"
extension_point="$(raw NSExtension.NSExtensionPointIdentifier)"

for value_name in bundle_id executable package_type short_version build_version extension_point; do
    eval "value=\${$value_name}"
    if [ -z "$value" ] || echo "$value" | grep -q '\$('; then
        echo "error: unresolved watch complication Info.plist value: $value_name" >&2
        exit 1
    fi
done

if [ "$package_type" != "XPC!" ]; then
    echo "error: unexpected watch complication package type: $package_type" >&2
    exit 1
fi
if [ "$extension_point" != "com.apple.widgetkit-extension" ]; then
    echo "error: unexpected watch complication extension point: $extension_point" >&2
    exit 1
fi

watch_plist="${CONTAINER_APP_PATH:-}"
if [ -n "$watch_plist" ]; then
    watch_plist="$watch_plist/Info.plist"
fi
if [ -f "$watch_plist" ]; then
    watch_short_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$watch_plist" 2>/dev/null || true)"
    watch_build_version="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$watch_plist" 2>/dev/null || true)"
    if [ "$short_version" != "$watch_short_version" ] || [ "$build_version" != "$watch_build_version" ]; then
        echo "error: complication version $short_version ($build_version) does not match watch app $watch_short_version ($watch_build_version)" >&2
        exit 1
    fi
fi

echo "validated watch complication bundle $bundle_id $short_version ($build_version)"
