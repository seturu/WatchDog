#!/bin/bash
# Installs the ARMED WatchDog into /Applications, owned by root.
#
#   scripts/build-armed.sh          (first, as yourself)
#   sudo scripts/install-armed.sh
#   sudo scripts/install-armed.sh --download /path/to/extracted/WatchDog.app
#
# READ THIS BEFORE RUNNING. The armed build is the real thing:
#   - Blocks can last up to 4 hours and cannot be cancelled.
#   - Any site can be blocked, except the short never-block list.
#   - Enforcing cannot be switched off again. Rules that are on cannot be
#     removed, changed or switched off; you can only add sites and rules.
#     WatchDog cannot be quit.
#   - There is no 15-minute self-reset as in the development build.
# The way out is scripts/uninstall.sh --armed (see docs/RESCUE.md). Print that
# page before you switch enforcement on.
#
# Installing does not start enforcing. It only puts the app in place; you then
# open it, go through Setup, add rules, and switch to Enforcing when ready.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

die() { echo "$*" >&2; exit 1; }
project=$(cd "$(dirname "$0")/.." && pwd -P)
destination=/Applications/WatchDog.app
download=false
case "$#:${1:-}" in
    0:)
        src="$project/build-armed/Build/Products/Release/WatchDog.app"
        config="$project/Config/Signing.xcconfig"
        ;;
    2:--download)
        src=$2
        [[ "$src" = /* ]] || src="$PWD/$src"
        config="$project/Config/Distribution.xcconfig"
        download=true
        ;;
    *) die "Usage: sudo $0 [--download /path/to/WatchDog.app]" ;;
esac
[ "$(id -u)" = 0 ] || die "Run the installer with sudo."
[ -d "$src" ] && [ ! -L "$src" ] && [ -f "$src/Contents/Info.plist" ] ||
    die "Expected an extracted app bundle at $src."

check_destination() {
    if launchctl print system/local.watchdog.daemon >/dev/null 2>&1; then
        die "The armed daemon is running. Uninstall before replacing WatchDog."
    fi
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        die "$destination already exists. Uninstall or move it aside first."
    fi
}
check_destination

# Read literal Xcode settings from the trusted checkout as data. The candidate
# app, its signature metadata, and the caller's environment cannot choose a team.
# A self-build reads Signing.xcconfig and then the builder's Local.xcconfig,
# whose values win, as they do in Xcode. A download uses the publisher's file only.
configs=("$config")
if ! "$download" && [ -f "$project/Config/Local.xcconfig" ]; then
    configs+=("$project/Config/Local.xcconfig")
fi
setting() {
    awk -v key="$1" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*\/\/.*/, ""); sub(/[[:space:]]+$/, ""); value = $0; found = 1
    } END { if (found) print value }' "${configs[@]}"
}
team=$(setting DEVELOPMENT_TEAM)
if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    if "$download"; then die "Invalid DEVELOPMENT_TEAM in $config."; fi
    die "Set DEVELOPMENT_TEAM in Config/Local.xcconfig (copy Config/Local.example.xcconfig)."
fi
identity=$(setting CODE_SIGN_IDENTITY)
signer="anchor apple generic and certificate leaf[subject.OU] = \"$team\""
if "$download" || [ "$identity" = "Developer ID Application" ]; then
    signer+=" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
elif [ "$identity" = "Apple Development" ]; then
    signer+=' and certificate leaf[subject.CN] = "Apple Development: "*'
elif [[ "$identity" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    signer+=" and certificate leaf = H\"$identity\""
elif [[ "$identity" = "Apple Development: "* || "$identity" = "Developer ID Application: "* ]]; then
    # Escape the literal common name before inserting it into a requirement.
    escaped=$(printf '%s' "$identity" | sed 's/[\\"]/\\&/g')
    signer+=" and certificate leaf[subject.CN] = \"$escaped\""
else
    die "Unsupported CODE_SIGN_IDENTITY in $config: $identity"
fi

# /Applications can be writable by members of admin. Keep the staging parent
# under root's home so another account cannot rename or replace it by pathname.
stage=$(mktemp -d /private/var/root/watchdog-install.XXXXXXXX)
app="$stage/WatchDog.app"
lock=/private/var/root/watchdog-install.lock
locked=false
owner_tmp=""
record=/Library/Preferences/local.watchdog.owner-uid
cleanup() {
    if [ -n "$owner_tmp" ]; then
        if [ -d "$app" ] && [ "$owner_tmp" -ef "$record" ]; then rm -f "$record"; fi
        rm -f "$owner_tmp"
    fi
    if "$locked"; then rm -f "$lock"; fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

ditto -X --noacl "$src" "$app"
# Both shipping layouts contain plain files and directories, plus the standard
# version links of an embedded framework (SQLCipher). Reject every other link
# and all special files before any recursive ownership change or signature check.
unexpected=$(find -P "$app" ! -type f ! -type d ! -type l -print -quit)
[ -z "$unexpected" ] || die "Unexpected special file in staged app."
while IFS= read -r -d '' link; do
    inside=${link#"$app"/}
    target=$(readlink "$link")
    # Versions/Current -> A, and top-level names -> Versions/Current/<same name>.
    if [[ "$inside" =~ ^Contents/Frameworks/[^/]+\.framework/Versions/Current$ ]] &&
       [[ "$target" =~ ^[A-Za-z0-9]+$ ]]; then
        continue
    fi
    if [[ "$inside" =~ ^Contents/Frameworks/[^/]+\.framework/([^/]+)$ ]] &&
       [ "$target" = "Versions/Current/${BASH_REMATCH[1]}" ]; then
        continue
    fi
    die "Unexpected link in staged app: $inside"
done < <(find -P "$app" -type l -print0)
chown -Rh root:wheel "$app"
chmod -RN "$app"
chmod -R a-s,a-t,u+rwX,go+rX,go-w "$app"

[ -f "$app/Contents/MacOS/WatchDogDaemon" ] && [ -x "$app/Contents/MacOS/WatchDogDaemon" ] ||
    die "Embedded daemon executable is missing."
codesign --verify --deep --strict --all-architectures "$app"
codesign --verify --strict --all-architectures -R="identifier \"local.watchdog\" and $signer" "$app"
codesign --verify --strict --all-architectures -R="identifier \"local.watchdog.daemon\" and $signer" "$app/Contents/MacOS/WatchDogDaemon"
# The widget extension (builds before the widgets have none).
widgets="$app/Contents/PlugIns/WatchDogWidgets.appex"
if [ -e "$widgets" ]; then
    codesign --verify --strict --all-architectures -R="identifier \"local.watchdog.widgets\" and $signer" "$widgets"
fi
if "$download"; then
    /usr/sbin/spctl --assess --type execute "$app"
fi

# Serialize owner enrollment and publication. shlock recovers dead process locks.
shlock -p "$$" -f "$lock" || die "Another WatchDog install is in progress."
locked=true
check_destination
# A direct root install leaves enrollment for the user to approve in Setup.
# sudo supplies the original UID independently of the current console login.
if [ -n "${SUDO_UID:-}" ] && [ "$SUDO_UID" != 0 ]; then
    if ! [[ "$SUDO_UID" =~ ^[1-9][0-9]{0,9}$ ]] || [ "$SUDO_UID" -ge 4294967295 ] ||
       [ "$(/usr/bin/id -u "$SUDO_UID")" != "$SUDO_UID" ]; then
        echo "Invalid sudo user ID." >&2
        exit 1
    fi
    owner_tmp=$(mktemp "$record.XXXXXX")
    printf '%s\n' "$SUDO_UID" > "$owner_tmp"
    /bin/chmod 644 "$owner_tmp"

    # Atomic creation; an existing record must already designate this account.
    if [ -L "$record" ] || [ -d "$record" ] || ! /bin/ln -h "$owner_tmp" "$record" 2>/dev/null; then
        if [ -L "$record" ] || [ ! -f "$record" ] ||
           [ "$(/usr/bin/stat -f '%u:%Lp' "$record")" != "0:644" ] || ! /usr/bin/cmp -s "$record" "$owner_tmp"; then
            echo "A different or invalid WatchDog owner record already exists." >&2
            exit 1
        fi
    fi
fi

# Darwin's exclusive rename publishes precisely this directory in one syscall.
# EEXIST and EXDEV both fail without touching the destination. JXA ships with
# macOS and lets this path work on Macs without Xcode Command Line Tools.
osascript -l JavaScript -e '
    ObjC.bindFunction("renamex_np", ["int", ["char *", "char *", "unsigned int"]]);
    function run(paths) {
        const RENAME_EXCL = 4;
        if ($.renamex_np(paths[0], paths[1], RENAME_EXCL) !== 0)
            throw Error("Could not install WatchDog. Check that the destination is free and on the staging volume.");
    }' -- "$app" "$destination"

echo
echo "Installed. Nothing is enforcing yet."
echo "  1. Open WatchDog from /Applications."
echo "  2. Sidebar > Setup: install the background service and grant the permissions."
echo "  3. Add your rules, then switch to Enforcing in the toolbar when you mean it."
echo
echo "The development build keeps its own separate rules, history and daemon."
echo "To avoid two WatchDogs tracking at once, switch off its start at login:"
echo "  build/Build/Products/Debug/WatchDog.app/Contents/MacOS/WatchDog --login-agent off"
