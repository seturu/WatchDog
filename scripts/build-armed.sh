#!/bin/bash
# Local install: scripts/build-armed.sh
# Downloadable ZIP: scripts/build-armed.sh --distribute
# On the signing Mac, install the team's Developer ID Application identity
# (certificate and private key) and configure notarytool once with:
#   xcrun notarytool store-credentials WatchDog-Notary
# Set NOTARY_PROFILE to use an existing keychain profile with a different name.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$#:${1:-}" in
    0:) distribute=false ;;
    1:--distribute) distribute=true ;;
    *) echo "Usage: $0 [--distribute]" >&2; exit 2 ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as yourself (signing uses your keychain)." >&2
    exit 1
fi

derived="$PWD/build-armed"
mkdir -p "$derived"
work=$(mktemp -d "$derived/.release.XXXXXX")
trap 'rm -rf "$work"' EXIT
signing=(-allowProvisioningUpdates)
if "$distribute"; then
    team=$(awk '/^DEVELOPMENT_TEAM *=/ { print $3 }' Config/Distribution.xcconfig)
    if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "Set DEVELOPMENT_TEAM in Config/Distribution.xcconfig." >&2
        exit 1
    fi
    identities=$(security find-identity -v -p codesigning)
    if ! grep -Eq "\"Developer ID Application: .* \\($team\\)\"" <<< "$identities"; then
        echo "A valid Developer ID Application certificate and private key for team $team are required." >&2
        exit 1
    fi
    profile=${NOTARY_PROFILE:-WatchDog-Notary}
    derived="$work/DerivedData"
    signing=(-xcconfig Config/Distribution.xcconfig)
elif [ ! -f Config/Local.xcconfig ]; then
    echo "Copy Config/Local.example.xcconfig to Config/Local.xcconfig and set your team ID." >&2
    exit 1
fi

swift test --package-path Packages/WatchDogCore
xcodegen generate
xcodebuild -project WatchDog.xcodeproj -scheme WatchDog -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" "${signing[@]}" build

app="$derived/Build/Products/Release/WatchDog.app"
verify_executable() {
    local binary="$1" identifier="$2" arch details entitlements automation
    local requirement="identifier \"$identifier\""
    if "$distribute"; then
        requirement+=" and anchor apple generic and certificate leaf[subject.OU] = \"$team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    fi
    codesign --verify --strict --all-architectures -R="$requirement" "$binary"
    local architectures
    architectures=$(lipo -archs "$binary")
    for arch in $architectures; do
        details=$(codesign -d --arch "$arch" --verbose=4 "$binary" 2>&1)
        if ! grep -Eq '^CodeDirectory .*flags=.*[(,]runtime[,)]' <<< "$details"; then
            echo "Hardened Runtime missing on $binary ($arch)." >&2; return 1
        fi
        if "$distribute" && ! grep -q '^Timestamp=' <<< "$details"; then
            echo "Secure timestamp missing on $binary ($arch)." >&2; return 1
        fi
        entitlements="$work/entitlements.plist"
        codesign -d --arch "$arch" --entitlements - --xml "$binary" > "$entitlements"
        automation=false
        if [ -s "$entitlements" ]; then
            plutil -lint "$entitlements" >/dev/null
            automation=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$entitlements" 2>/dev/null) || automation=false
            if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null)" = true ]; then
                echo "Unexpected debugger entitlement on $binary ($arch)." >&2; return 1
            fi
        fi
        if [ "$identifier" = local.watchdog ]; then
            [ "$automation" = true ] || { echo "GUI Apple Events entitlement missing." >&2; return 1; }
        else
            [ "$automation" = false ] || { echo "Unexpected Apple Events entitlement on $identifier." >&2; return 1; }
        fi
        # WidgetKit only loads sandboxed extensions; the sandbox is also what
        # keeps the widget away from the usage history.
        if [ "$identifier" = local.watchdog.widgets ] &&
            [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements" 2>/dev/null)" != true ]; then
            echo "Widget extension is not sandboxed." >&2; return 1
        fi
    done
}

codesign --verify --deep --strict --all-architectures "$app"
verify_executable "$app/Contents/MacOS/WatchDog" local.watchdog
verify_executable "$app/Contents/MacOS/WatchDogDaemon" local.watchdog.daemon
verify_executable "$app/Contents/PlugIns/WatchDogWidgets.appex/Contents/MacOS/WatchDogWidgets" local.watchdog.widgets

if ! "$distribute"; then
    echo "Built and verified: $app"
    echo "Next: sudo scripts/install-armed.sh"
    exit 0
fi

ditto -c -k --keepParent "$app" "$work/submission.zip"
receipt="$work/notarization.plist"
if ! xcrun notarytool submit "$work/submission.zip" --keychain-profile "$profile" \
        --wait --output-format plist > "$receipt" ||
        [ "$(plutil -extract status raw -o - "$receipt")" != Accepted ]; then
    submission=$(plutil -extract id raw -o - "$receipt" 2>/dev/null) || submission=""
    if [ -n "$submission" ]; then
        echo "Notarization submission: $submission" >&2
        xcrun notarytool log "$submission" --keychain-profile "$profile" >&2 || true
    fi
    echo "Apple notarization did not complete successfully." >&2
    exit 1
fi
xcrun stapler staple "$app"
ditto -c -k --keepParent "$app" "$work/WatchDog.zip"
ditto -x -k "$work/WatchDog.zip" "$work/check"
download="$work/check/WatchDog.app"
codesign --verify --deep --strict --all-architectures "$download"
xcrun stapler validate "$download"
spctl --assess --type execute --verbose=2 "$download"

mv -f "$work/WatchDog.zip" build-armed/WatchDog.zip
echo "Notarized download: build-armed/WatchDog.zip"
