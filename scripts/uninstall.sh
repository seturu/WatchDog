#!/bin/bash
# Removes everything WatchDog has put on this Mac.
#
#   sudo scripts/uninstall.sh            the development build
#   sudo scripts/uninstall.sh --armed    the armed build in /Applications
#
# This is the rescue path: it works when the app cannot run, and it does not
# ask the daemon's permission. That also makes it the one deliberate way
# around WatchDog. It needs your password and a terminal on purpose.
#
# Rule: whenever the app or daemon learns to change something new on the
# system, the undo for it is added here in the same change.
#
# Footprint: a launchd daemon and a login agent; a marked section in /etc/hosts
# while something is blocked; a Brave policy file while enforcing; firewall
# rules while a block runs with the firewall layer on; the daemon's state
# folder (rules, block, audit log, hosts backup); privacy permissions.
#
# Order matters: the daemon is stopped FIRST, or it would put back whatever
# is removed after it.
#
# Every delete below names a fixed path written out in full. Nothing is
# deleted through a variable, so an empty variable can never widen a delete.

set -u
# Root runs this: use only the system's own tools, whatever PATH sudo kept.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

case "${1:-}" in
    --armed) MODE=armed; APP_ID="local.watchdog";     TAG="WatchDog" ;;
    "")      MODE=dev;   APP_ID="local.watchdog.dev"; TAG="WatchDog-dev" ;;
    *)       echo "usage: sudo $0 [--armed]" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "Needs root. Run: sudo $0 ${1:-}" >&2
    exit 1
fi

# The user who ran sudo; privacy grants and the menu-bar app belong to them.
REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
REAL_UID=$(id -u "$REAL_USER")

step() { printf '• %s\n' "$1"; }

step "Removing the login agent and quitting the app"
# The agent must go first, or launchd would start the app again.
if launchctl print "gui/$REAL_UID/$APP_ID.agent" >/dev/null 2>&1; then
    launchctl bootout "gui/$REAL_UID/$APP_ID.agent" && echo "  agent removed"
else
    echo "  no agent loaded"
fi
# Only this build's app, recognised by its bundle ID. The command line cannot
# tell (launchd starts the app as plain "Contents/MacOS/WatchDog", and both
# builds are called WatchDog.app), so look up each process's executable.
for pid in $(pgrep -x WatchDog 2>/dev/null); do
    exe=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | grep -m1 '/Contents/MacOS/WatchDog$')
    [ -n "$exe" ] || continue
    id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${exe%/MacOS/WatchDog}/Info.plist" 2>/dev/null)
    if [ "$id" = "$APP_ID" ]; then kill "$pid" 2>/dev/null && echo "  app quit"; fi
done

step "Stopping the daemon"
if launchctl print "system/$APP_ID.daemon" >/dev/null 2>&1; then
    launchctl bootout "system/$APP_ID.daemon" && echo "  stopped"
    sleep 1
    # A daemon still running would put back everything removed below.
    if launchctl print "system/$APP_ID.daemon" >/dev/null 2>&1; then
        echo "The daemon is still running, so nothing else was removed. Run this again; if it keeps" >&2
        echo "failing, restart in Safe Mode (it does not load WatchDog) and run it there." >&2
        exit 1
    fi
else
    echo "  not loaded"
fi

if [ "$MODE" = dev ]; then
    step "Removing early test blocks (spike script)"
    "$(dirname "$0")/spike-brave.sh" revert 2>&1 | sed 's/^/  /'
fi

step "Removing the block list from /etc/hosts"
HOSTS_BEGIN="# >>> $TAG (managed block list; edits here are reverted)"
HOSTS_END="# <<< $TAG"
if grep -qxF "$HOSTS_BEGIN" /etc/hosts; then
    tmp=$(mktemp /tmp/watchdog-hosts.XXXXXX)
    # Same rule as the daemon: inside the section only WatchDog's own kind of
    # line goes, and the first other line ends it. If the end marker has been
    # deleted, whatever follows the block lines is kept, not swallowed.
    awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
        $0==b { s=1; next }
        s && $0==e { s=0; next }
        s && /^(0\.0\.0\.0|::) / { next }
        { s=0; print }' /etc/hosts > "$tmp"
    if grep -q "localhost" "$tmp"; then
        cat "$tmp" > /etc/hosts && echo "  removed"
        dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
    else
        echo "  cleaned file looks wrong (no localhost line); NOT written." >&2
        echo "  The daemon's copy of the original is hosts.backup in its state folder." >&2
    fi
    # The temporary copy is left in /tmp; macOS clears that folder by itself.
else
    echo "  none"
fi

step "Removing browser policy files written by WatchDog"
# A policy file is ours only if our marker sits beside it AND the policy is
# still what WatchDog wrote: the marker holds a copy of it (older builds left
# the marker empty; WatchDog's one policy is exactly {"TorDisabled":true}).
# A policy changed since then belongs to someone else and is kept.
remove_policy() {   # $1 = marker path, $2 = policy path; both passed as literals below
    [ -e "$1" ] || return 0
    if [ ! -e "$2" ]; then
        unlink "$1"
    elif { [ -s "$1" ] && cmp -s "$1" "$2"; } ||
         [ "$(plutil -convert json -o - "$2" 2>/dev/null)" = '{"TorDisabled":true}' ]; then
        unlink "$2"
        unlink "$1" && echo "  removed $(basename "$2")"
    else
        unlink "$1"
        echo "  kept $(basename "$2"): it was changed since WatchDog wrote it, so another program manages it"
    fi
}
if [ "$MODE" = armed ]; then
    remove_policy "/Library/Managed Preferences/.watchdog.com.brave.Browser"     "/Library/Managed Preferences/com.brave.Browser.plist"
    remove_policy "/Library/Managed Preferences/.watchdog.com.google.Chrome"     "/Library/Managed Preferences/com.google.Chrome.plist"
    remove_policy "/Library/Managed Preferences/.watchdog.com.microsoft.edgemac" "/Library/Managed Preferences/com.microsoft.edgemac.plist"
else
    remove_policy "/Library/Managed Preferences/.watchdog-dev.com.brave.Browser"     "/Library/Managed Preferences/com.brave.Browser.plist"
    remove_policy "/Library/Managed Preferences/.watchdog-dev.com.google.Chrome"     "/Library/Managed Preferences/com.google.Chrome.plist"
    remove_policy "/Library/Managed Preferences/.watchdog-dev.com.microsoft.edgemac" "/Library/Managed Preferences/com.microsoft.edgemac.plist"
fi
echo "  (a running browser drops the policy the next time it is restarted)"

step "Removing firewall rules"
# The daemon removes its rules when it stops; this covers a daemon that could
# not. Our rules live in their own anchor, named after the app, so emptying it
# cannot affect anyone else's. The main ruleset is not touched.
pfctl -a "$APP_ID" -F rules >/dev/null 2>&1 || true
pfctl -a "$APP_ID" -F Tables >/dev/null 2>&1 || true
echo "  emptied the $APP_ID anchor"
if [ -e "/Library/Application Support/$TAG/pf.token" ]; then
    # Its hold on the firewall is not released here: the saved number may be
    # from an earlier boot and belong to someone else by now.
    echo "  The daemon did not finish its own cleanup. The firewall may stay switched on"
    echo "  (with no WatchDog rules in it) until the next restart. That is harmless."
fi

step "Removing daemon state"
if [ "$MODE" = armed ]; then
    if [ -d "/Library/Application Support/WatchDog" ]; then
        rm -rf "/Library/Application Support/WatchDog" && echo "  removed /Library/Application Support/WatchDog"
    else
        echo "  none"
    fi
else
    if [ -d "/Library/Application Support/WatchDog-dev" ]; then
        rm -rf "/Library/Application Support/WatchDog-dev" && echo "  removed /Library/Application Support/WatchDog-dev"
    else
        echo "  none"
    fi
fi

if [ "$MODE" = armed ]; then
    rm -f /Library/Preferences/local.watchdog.owner-uid
else
    rm -f /Library/Preferences/local.watchdog.dev.owner-uid
fi

step "Resetting privacy grants (Accessibility, Automation)"
sudo -u "$REAL_USER" tccutil reset All "$APP_ID" >/dev/null 2>&1 && echo "  reset" || echo "  nothing to reset"

echo
echo "Done. Left for you:"
echo "  1. Delete WatchDog.app (from /Applications or your build folder)."
echo "  2. The entry under System Settings > General > Login Items disappears"
echo "     once the app is deleted; you can also switch it off there."
echo "  3. Your usage history is kept in ~/Library/Group Containers/<team>.$APP_ID.private/$TAG"
echo "     (builds before the private container: ~/Library/Application Support/$TAG)."
