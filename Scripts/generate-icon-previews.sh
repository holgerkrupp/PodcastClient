#!/bin/bash
#
# Generates Raul/Assets.xcassets/iconPreviews from the .icon bundles in Raul.
#
# The app icon picker in Settings cannot draw the real app icon assets: icons compile into
# the asset catalog as multi-size icon stacks, and UIImage(named:) does not merely fail on
# those, it raises "Need an imageRef". So each icon gets a flat light/dark preview here,
# which AlternateAppIcon.previewAssetName points at.
#
# Runs as the first build phase of the Up Next target, and can also be run by hand:
#
#     ./Scripts/generate-icon-previews.sh                            # fill in missing previews
#     ./Scripts/generate-icon-previews.sh --force AppIcon-blue AppIcon # regenerate these
#     ./Scripts/generate-icon-previews.sh --force                    # regenerate every preview
#
# Previews are only generated for icons that do not have an imageset yet. An existing
# imageset is never touched, so you can replace a generated preview with one exported from
# Icon Composer and it stays. To refresh a preview after redesigning its icon, delete the
# imageset or pass the icon name to --force.
#
# Adding an icon is three steps, and this script warns about the two it cannot do itself:
#   1. Drop AppIcon-foo.icon into Raul. It is a synchronized folder, so that is all the
#      target membership it needs.
#   2. Add it to ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES in the project.
#   3. Add an AlternateAppIcon entry (title, colors) in PodcastSettingsView.swift.
# The preview image is generated for you.
#
# Extraction reads composited renditions out of a compiled Assets.car through CoreUI, a
# private framework. That is fine for a tool that only runs on a Mac at build time; it is
# not shipped in the app. If a future Xcode breaks it the build fails with a clear message,
# and you can export from Icon Composer by hand until it is fixed.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

ICONS_DIR="$ROOT/Raul"
PRIMARY_NAME="AppIcon"
PREVIEWS="$ROOT/Raul/Assets.xcassets/iconPreviews"
PROJECT="$ROOT/Up Next.xcodeproj/project.pbxproj"
SETTINGS_VIEW="$ROOT/Raul/Features/Settings/Views/PodcastSettingsView.swift"

PREVIEW_SIZE=384

FORCE_ALL=0
FORCE_NAMES=()
if [ "${1:-}" = "--force" ]; then
    shift
    if [ $# -eq 0 ]; then FORCE_ALL=1; else FORCE_NAMES=("$@"); fi
fi

note() { echo "generate-icon-previews: $*"; }
fail() { echo "error: generate-icon-previews: $*" >&2; exit 1; }

icon_path() { echo "$ICONS_DIR/$1.icon"; }

# --- Which icons are there? ------------------------------------------------------------

ICONS=()
for icon in "$ICONS_DIR"/*.icon; do
    [ -d "$icon" ] || continue
    name="$(basename "$icon" .icon)"
    case "$name" in
        *" "*) fail "icon name \"$name\" contains a space; actool splits those into separate icons. Rename it." ;;
    esac
    ICONS+=("$name")
done

[ ${#ICONS[@]} -gt 0 ] || { note "no .icon bundles in Raul; nothing to do"; exit 0; }

for name in "${FORCE_NAMES[@]+"${FORCE_NAMES[@]}"}"; do
    [ -d "$(icon_path "$name")" ] || fail "--force $name: there is no $name.icon"
done

# --- 1. Warn about the wiring this script cannot do for you ------------------------------

# Raul is a synchronized folder, so a .icon dropped in there is already a target member.
for name in "${ICONS[@]}"; do
    [ "$name" = "$PRIMARY_NAME" ] && continue

    if ! grep -q "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = .*$name" "$PROJECT"; then
        echo "warning: $name is missing from ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES; it cannot be selected"
    fi
    if ! grep -q "\"$name\"" "$SETTINGS_VIEW"; then
        echo "warning: $name has no AlternateAppIcon entry in PodcastSettingsView.swift; it will not appear in Settings"
    fi
done

# --- 2. Which previews need generating? --------------------------------------------------

forced() {
    [ "$FORCE_ALL" -eq 1 ] && return 0
    local name
    for name in "${FORCE_NAMES[@]+"${FORCE_NAMES[@]}"}"; do [ "$name" = "$1" ] && return 0; done
    return 1
}

PENDING=()
for name in "${ICONS[@]}"; do
    if forced "$name" || [ ! -d "$PREVIEWS/$name.imageset" ]; then
        PENDING+=("$name")
    fi
done

# Previews whose icon is gone are left alone, but worth knowing about.
for set in "$PREVIEWS"/*.imageset; do
    [ -d "$set" ] || continue
    name="$(basename "$set" .imageset)"
    [ -d "$(icon_path "$name")" ] || echo "warning: iconPreviews/$name has no matching .icon; delete it if the icon was removed"
done

[ ${#PENDING[@]} -gt 0 ] || exit 0

note "generating previews for: ${PENDING[*]}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 3. Composite the pending icons, then pull the renditions back out --------------------

mkdir -p "$WORK/car"
ICON_ARGS=()
for name in "${PENDING[@]}"; do ICON_ARGS+=("$(icon_path "$name")"); done

env -u SDKROOT -u PLATFORM_NAME xcrun actool "${ICON_ARGS[@]}" \
    --compile "$WORK/car" \
    --app-icon "${PENDING[0]}" \
    --include-all-app-icons \
    --output-partial-info-plist "$WORK/partial.plist" \
    --target-device iphone \
    --minimum-deployment-target 18.0 \
    --platform iphoneos \
    --output-format human-readable-text >/dev/null \
    || fail "actool could not compile the icon bundles"

cat > "$WORK/extract.m" <<'OBJC'
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>

// Writes <name>~light.png and <name>~dark.png for each named icon in the catalog.
int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: extract <Assets.car> <outDir> <name>...\n"); return 2; }
    if (!dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY)) return 1;
    Class CUICatalog = NSClassFromString(@"CUICatalog");
    Class CUINamedImage = NSClassFromString(@"CUINamedImage");
    if (!CUICatalog || !CUINamedImage) return 1;

    NSError *error = nil;
    SEL initSel = NSSelectorFromString(@"initWithURL:error:");
    id allocated = [CUICatalog alloc];
    typedef id (*InitFn)(id, SEL, NSURL *, NSError **);
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    id catalog = ((InitFn)[allocated methodForSelector:initSel])(allocated, initSel, url, &error);
    if (!catalog) return 1;

    NSString *outDir = [NSString stringWithUTF8String:argv[2]];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    // Each icon comes back as several renditions: per idiom (phone, pad) and per appearance
    // (any, dark, tintable). Their order is not something to rely on - phone-light is followed
    // by pad-light, not by dark - so pick by the appearance each rendition reports.
    NSDictionary *wanted = @{ @"UIAppearanceAny": @"light", @"UIAppearanceDark": @"dark" };
    const long phoneIdiom = 1;

    for (int i = 3; i < argc; i++) {
        NSString *name = [NSString stringWithUTF8String:argv[i]];
        NSMutableDictionary *best = [NSMutableDictionary dictionary];

        for (id rep in [catalog performSelector:@selector(imagesWithName:) withObject:name]) {
            if (![rep isKindOfClass:CUINamedImage]) continue;
            CGImageRef image = (__bridge CGImageRef)[rep performSelector:@selector(image)];
            if (!image || CGImageGetWidth(image) < 512) continue;

            NSString *suffix = wanted[[[rep valueForKey:@"appearance"] description]];
            if (!suffix) continue;

            // Prefer the phone rendition; take another idiom only if there is no phone one.
            long idiom = (long)[rep performSelector:@selector(idiom)];
            if (best[suffix] && idiom != phoneIdiom) continue;
            best[suffix] = rep;
        }

        for (NSString *suffix in best) {
            CGImageRef image = (__bridge CGImageRef)[best[suffix] performSelector:@selector(image)];
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:[NSString stringWithFormat:@"%@/%@~%@.png", outDir, name, suffix]
                  atomically:YES];
        }
    }
    return 0;
}
OBJC

# Xcode exports a target-SDK environment that leaks into clang and breaks a host compile,
# so build the helper in a scrubbed environment.
MAC_SDK="$(env -i PATH=/usr/bin:/bin DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    /usr/bin/xcrun --sdk macosx --show-sdk-path)"
env -i PATH=/usr/bin:/bin DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    /usr/bin/xcrun --sdk macosx clang -isysroot "$MAC_SDK" \
    -fno-objc-arc -framework Foundation -framework AppKit -framework CoreGraphics \
    -o "$WORK/extract" "$WORK/extract.m" -Wno-objc-method-access -Wno-deprecated-declarations \
    || fail "could not build the rendition extractor"

"$WORK/extract" "$WORK/car/Assets.car" "$WORK/png" "${PENDING[@]}" \
    || fail "could not read composited icons out of Assets.car (CoreUI may have changed)"

# --- 4. One namespaced imageset per pending icon -----------------------------------------

mkdir -p "$PREVIEWS"
if [ ! -f "$PREVIEWS/Contents.json" ]; then
    cat > "$PREVIEWS/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "provides-namespace" : true
  }
}
JSON
fi

for name in "${PENDING[@]}"; do
    light="$WORK/png/$name~light.png"
    dark="$WORK/png/$name~dark.png"
    [ -f "$light" ] || fail "no composited artwork came back for \"$name\""
    if [ ! -f "$dark" ]; then
        echo "warning: $name.icon has no dark rendition; its preview uses the light artwork in dark mode"
        dark="$light"
    fi

    # Each imageset is built aside and moved into place, so a failure cannot leave a
    # half-written imageset that breaks the asset catalog. The iconPreviews namespace set up
    # above matters: without it a preview named AppIcon-blue would collide with the app icon.
    set="$WORK/stage/$name.imageset"
    mkdir -p "$set"
    sips -Z "$PREVIEW_SIZE" "$light" --out "$set/$name-light.png" >/dev/null
    sips -Z "$PREVIEW_SIZE" "$dark" --out "$set/$name-dark.png" >/dev/null

    cat > "$set/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$name-light.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "$name-dark.png",
      "idiom" : "universal",
      "scale" : "1x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

    rm -rf "$PREVIEWS/$name.imageset"
    mv "$set" "$PREVIEWS/$name.imageset"
done

note "generated ${#PENDING[@]} preview(s)"
