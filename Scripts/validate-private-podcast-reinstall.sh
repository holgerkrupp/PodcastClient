#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIMULATOR_ID=${1:-A7365E70-AC92-4325-88F7-C7549894BB57}
DERIVED_DATA_DIR=${TMPDIR:-/tmp}/PodcastClient/private-podcast-reinstall-$(date +%Y%m%d-%H%M%S)
PROJECT="$ROOT_DIR/Up Next.xcodeproj"
SCHEME=UpNext
TEST_BUNDLE_ID=de.holgerkrupp.PodcastClient

cleanup() {
    if [ -d "$DERIVED_DATA_DIR" ]; then
        /usr/bin/find "$DERIVED_DATA_DIR" -depth -delete
    fi
}
trap cleanup EXIT INT TERM

run_phase() {
    phase=$1
    case "$phase" in
        write)
            test_name=testCredentialPersistenceWritePhase
            swift_conditions='DEBUG REINSTALL_WRITE'
            ;;
        read)
            test_name=testCredentialPersistenceReadPhase
            swift_conditions='DEBUG REINSTALL_READ'
            ;;
        *) echo "Unknown reinstall phase: $phase" >&2; exit 2 ;;
    esac
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        -parallel-testing-enabled NO \
        -only-testing:UpNextTests/PodcastCredentialPersistenceTests/$test_name \
        test CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_IDENTITY=- \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS="$swift_conditions"
}

run_phase write
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null
xcrun simctl uninstall "$SIMULATOR_ID" "$TEST_BUNDLE_ID"
run_phase read

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -parallel-testing-enabled NO \
    -only-testing:UpNextTests/PodcastCredentialPersistenceTests/testPrivateCredentialUsesDeviceOnlyKeychainAttributes \
    test CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=-

echo "Private podcast Keychain credential survived simulator app reinstall."
