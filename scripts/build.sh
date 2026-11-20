#!/bin/bash
# Build WatchDog on your Mac with one command.
#
#   scripts/build.sh           the development build, safe to try: blocks of
#                              5 minutes at most, only example.com/.org/.net,
#                              and a daemon that resets itself every 15 minutes
#   scripts/build.sh --armed   the real thing (then: sudo scripts/install-armed.sh)
#
# It checks for Xcode and XcodeGen, finds your Apple team ID and saves it in
# Config/Local.xcconfig (once; git ignores that file), generates the Xcode
# project and builds. Nothing is installed, registered or started.
#
# WATCHDOG_BUILD_DIR changes where the development build goes (default: build/).
set -euo pipefail
cd "$(dirname "$0")/.."

die() { printf '\n%s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

case "$#:${1:-}" in
    0:) armed=false ;;
    1:--armed) armed=true ;;
    *) die "Usage: $0 [--armed]" ;;
esac
[ "$(id -u)" -ne 0 ] || die "Run this as yourself, not with sudo: signing uses your keychain."

# --- Tools -------------------------------------------------------------------

macos=$(sw_vers -productVersion)
[ "${macos%%.*}" -ge 26 ] || die "WatchDog needs macOS 26 or later. This Mac runs $macos."

if ! xcode=$(xcodebuild -version 2>&1); then
    die "Xcode is not ready:
$xcode

Install Xcode from the App Store and open it once. If it is installed, select it:
  sudo xcode-select -s /Applications/Xcode.app"
fi
sdk=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null) || sdk=0
[ "${sdk%%.*}" -ge 26 ] || die "WatchDog needs the macOS 26 SDK; this Xcode has ${sdk}. Update Xcode."
say "$(head -1 <<< "$xcode"), macOS SDK $sdk"

if ! command -v xcodegen >/dev/null; then
    if command -v brew >/dev/null && [ -t 0 ]; then
        read -r -p "XcodeGen makes the Xcode project and is missing. Install it with Homebrew now? [y/N] " answer
        [[ "$answer" = [yY]* ]] || die "Install it with: brew install xcodegen"
        brew install xcodegen
    else
        die "XcodeGen makes the Xcode project and is missing. Install it with:
  brew install xcodegen
(or see https://github.com/yonaskolb/XcodeGen)"
    fi
fi

# --- Team ID -----------------------------------------------------------------
# The app and its daemon only trust code signed by the same team, so every
# build needs one. A free Personal Team (any Apple ID added to Xcode) is enough.

local_config=Config/Local.xcconfig

setting_in() {
    awk -v key="$1" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*\/\/.*/, ""); sub(/[[:space:]]+$/, ""); value = $0
    } END { print value }' "$2"
}

# "TEAMID<tab>name" for each valid Apple Development certificate with its key.
keychain_teams() {
    local hash pem subject team name
    for hash in $(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{ print $2 }'); do
        pem=$(security find-certificate -a -c "Apple Development" -Z -p 2>/dev/null |
            awk -v h="$hash" '/^SHA-(1|256) hash:/ { keep = ($1 == "SHA-1" && $3 == h); next } keep')
        [ -n "$pem" ] || continue
        subject=$(/usr/bin/openssl x509 -noout -subject -nameopt sep_multiline <<< "$pem" 2>/dev/null) || continue
        team=$(sed -n 's/^[[:space:]]*OU=\([A-Z0-9]\{10\}\)$/\1/p' <<< "$subject" | head -1)
        name=$(sed -n 's/^[[:space:]]*O=//p' <<< "$subject" | head -1)
        [ -n "$team" ] && printf '%s\t%s\n' "$team" "${name:-Apple Development certificate}"
    done
    return 0
}

# "TEAMID<tab>name" for each team of the accounts in Xcode > Settings > Apple Accounts.
xcode_teams() {
    defaults export com.apple.dt.Xcode - 2>/dev/null |
        plutil -extract IDEProvisioningTeamByIdentifier xml1 -o - - 2>/dev/null |
        awk '/<key>teamID<\/key>/ { getline; gsub(/^[[:space:]]*<string>|<\/string>[[:space:]]*$/, ""); id = $0 }
             /<key>teamName<\/key>/ { getline; gsub(/^[[:space:]]*<string>|<\/string>[[:space:]]*$/, ""); name = $0 }
             /<\/dict>/ { if (id != "") printf "%s\t%s\n", id, name; id = ""; name = "" }' || true
}

if [ -f "$local_config" ]; then
    team=$(setting_in DEVELOPMENT_TEAM "$local_config")
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] ||
        die "$local_config has no valid DEVELOPMENT_TEAM (it says \"$team\").
Fix it, or delete the file and run this again to detect your team."
    say "Team $team, from $local_config"
else
    # Neither source is required; finding nothing is handled just below.
    teams=$({ keychain_teams; xcode_teams; } | awk -F '\t' '$1 ~ /^[A-Z0-9]{10}$/ && !seen[$1]++') || teams=""
    count=$(grep -c . <<< "$teams" || true)
    if [ "$count" -eq 0 ]; then
        die "No Apple team found on this Mac. A free Apple ID is enough:
  1. Open Xcode > Settings > Apple Accounts and add your Apple ID.
  2. Run this script again.
Or copy Config/Local.example.xcconfig to $local_config and fill it in by hand."
    elif [ "$count" -eq 1 ]; then
        team=$(cut -f1 <<< "$teams")
    elif [ -t 0 ]; then
        echo "Several Apple teams are available:"
        awk -F '\t' '{ printf "  %d) %s  %s\n", NR, $1, $2 }' <<< "$teams"
        read -r -p "Which one should sign WatchDog? [1-$count] " pick
        [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ] || die "No team chosen."
        team=$(sed -n "${pick}p" <<< "$teams" | cut -f1)
    else
        die "Several Apple teams are available; put the one to use in $local_config:
$(awk -F '\t' '{ printf "  %s  %s\n", $1, $2 }' <<< "$teams")"
    fi
    cat > "$local_config" <<EOF
// Written by scripts/build.sh. Your own signing settings; git ignores this file.
// Config/Local.example.xcconfig lists the other settings you can put here.
DEVELOPMENT_TEAM = $team
EOF
    say "Team $team ($(awk -F '\t' -v t="$team" '$1 == t { print $2; exit }' <<< "$teams")), saved in $local_config"
fi

# --- Build -------------------------------------------------------------------

if "$armed"; then
    say "Building the armed (Release) build"
    exec scripts/build-armed.sh
fi

derived=${WATCHDOG_BUILD_DIR:-$PWD/build}
say "Generating the Xcode project"
xcodegen generate --quiet
say "Building the development build (a few minutes the first time)"
xcodebuild -quiet -project WatchDog.xcodeproj -scheme WatchDog -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -allowProvisioningUpdates build
app="$derived/Build/Products/Debug/WatchDog.app"
codesign --verify --deep --strict "$app" || die "The build finished but its signature does not verify."

cat <<EOF

Built the development build:
  $app

Start it:
  open "$app"

Then open Setup in WatchDog's sidebar and work down the list. When you are ready
for real blocking, print docs/RESCUE.md and run: scripts/build.sh --armed
EOF
