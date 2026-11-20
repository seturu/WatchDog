#!/bin/bash
# Milestone 0, spike B: does Brave obey (1) the hosts file while secure DNS is
# on, and (2) a managed-policy file on a Mac with no MDM?
#
#   sudo scripts/spike-brave.sh apply     add the two test blocks
#        scripts/spike-brave.sh check     load both test sites in Brave, report
#   sudo scripts/spike-brave.sh revert    remove everything apply added
#
# Test targets are reserved example domains, so nothing you use is affected:
#   example.com  -> blocked through /etc/hosts
#   example.org  -> blocked through Brave policy (URLBlocklist)

set -u

HOSTS=/etc/hosts
BACKUP=/etc/hosts.watchdog-spike.bak
BEGIN="# >>> WatchDog-dev spike (safe to delete with: sudo scripts/spike-brave.sh revert)"
END="# <<< WatchDog-dev spike"
POLICY_DIR="/Library/Managed Preferences"
POLICY="$POLICY_DIR/com.brave.Browser.plist"
MARKER="$POLICY_DIR/.watchdog-spike"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then echo "Needs root: sudo $0 $1" >&2; exit 1; fi
}

flush_dns() {
    dscacheutil -flushcache
    killall -HUP mDNSResponder 2>/dev/null || true
}

apply() {
    need_root apply

    if grep -qxF "$BEGIN" "$HOSTS"; then
        echo "hosts: test section already present, leaving it"
    else
        cp -p "$HOSTS" "$BACKUP"
        # Append only. Existing lines are never rewritten.
        {
            # Make sure we start on a fresh line even if the file lacks a final newline.
            [ -n "$(tail -c1 "$HOSTS")" ] && echo
            echo "$BEGIN"
            echo "0.0.0.0 example.com"
            echo "0.0.0.0 www.example.com"
            echo ":: example.com"
            echo ":: www.example.com"
            echo "$END"
        } >> "$HOSTS"
        flush_dns
        echo "hosts: added test section (backup at $BACKUP)"
    fi

    if [ -e "$POLICY" ] && [ ! -e "$MARKER" ]; then
        echo "policy: $POLICY already exists and is not ours — not touching it" >&2
    else
        /usr/libexec/PlistBuddy -c "Clear dict" "$POLICY" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy \
            -c "Add :URLBlocklist array" \
            -c "Add :URLBlocklist:0 string example.org" \
            -c "Add :TorDisabled bool true" \
            "$POLICY" >/dev/null
        chown root:wheel "$POLICY"; chmod 644 "$POLICY"
        touch "$MARKER"
        echo "policy: wrote $POLICY (URLBlocklist=example.org, TorDisabled=true)"
    fi

    echo
    echo "Now quit and reopen Brave so it reads the policy, then run:"
    echo "  scripts/spike-brave.sh check"
}

revert() {
    need_root revert

    if grep -qxF "$BEGIN" "$HOSTS"; then
        tmp=$(mktemp)
        # Inside the section only its own kind of line goes: if the end marker
        # was lost, the first other line ends it, instead of everything after
        # it being deleted.
        awk -v b="$BEGIN" -v e="$END" '$0==b{s=1;next} s&&$0==e{s=0;next} s&&/^(0\.0\.0\.0|::) /{next} {s=0;print}' "$HOSTS" > "$tmp"
        # If the appended section started with a blank separator line, drop it
        # so the file ends exactly as it did before.
        if [ -f "$BACKUP" ] && ! cmp -s "$tmp" "$BACKUP"; then
            sed -e '$ { /^$/d; }' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
        fi
        if ! grep -q "localhost" "$tmp"; then
            echo "hosts: cleaned file looks wrong (no localhost line) — NOT written. Restore manually from $BACKUP" >&2
            rm -f "$tmp"; exit 1
        fi
        cat "$tmp" > "$HOSTS"      # keeps the file's owner and permissions
        if [ -f "$BACKUP" ] && cmp -s "$tmp" "$BACKUP"; then
            echo "hosts: test section removed; file is byte-identical to the backup"
            rm -f "$BACKUP"
        else
            echo "hosts: test section removed (file differs from the backup, which is kept at $BACKUP)"
        fi
        rm -f "$tmp"
        flush_dns
    else
        echo "hosts: no test section"
    fi

    if [ -e "$MARKER" ]; then
        # Remove the policy only if it is still the one apply wrote (it blocks
        # example.org); the daemon or another tool may have replaced it since.
        if [ "$(/usr/libexec/PlistBuddy -c "Print :URLBlocklist:0" "$POLICY" 2>/dev/null)" = "example.org" ]; then
            rm -f "$POLICY"
            echo "policy: removed"
        else
            echo "policy: no longer the test policy, kept"
        fi
        rm -f "$MARKER"
    else
        echo "policy: none of ours"
    fi
    echo "Quit and reopen Brave to drop the policy."
}

# Opens a URL in a new Brave tab, waits, prints "title | url", closes the tab.
load_in_brave() {
    osascript <<EOF
tell application id "com.brave.Browser"
    if (count of windows) is 0 then return "no Brave window open"
    set w to front window
    make new tab at end of tabs of w with properties {URL:"$1"}
    delay 6
    -- Find the tab again by address: a blocked page can replace the tab
    -- object, so a saved reference to it is not reliable.
    set r to ""
    repeat with t in tabs of w
        if (URL of t) contains "example." then
            set r to (title of t) & " | " & (URL of t)
            close t
        end if
    end repeat
    if r is "" then set r to "tab not found"
    return r
end tell
EOF
}

check() {
    echo "state on disk:"
    grep -qxF "$BEGIN" "$HOSTS" && echo "  hosts section: present" || echo "  hosts section: absent"
    [ -e "$POLICY" ] && echo "  policy file:   present" || echo "  policy file:   absent"
    echo "  system resolver, example.com: $(dscacheutil -q host -a name example.com | awk '/ip_address/{print $2}' | head -1)"
    pgrep -qx "Brave Browser" || { echo "Brave is not running"; exit 1; }
    echo "in Brave (a page titled 'Example Domain' means it loaded):"
    # The query string defeats Brave's page cache, which otherwise shows a
    # previously loaded copy and makes a working block look broken.
    local t; t=$(date +%s)
    echo "  example.com (hosts):   $(load_in_brave "https://example.com/?wd=$t")"
    echo "  example.org (policy):  $(load_in_brave "https://example.org/?wd=$t")"
    echo "  example.net (control): $(load_in_brave "https://example.net/?wd=$t")"
}

case "${1:-}" in
    apply) apply ;;
    revert) revert ;;
    check) check ;;
    *) echo "usage: $0 apply|check|revert" >&2; exit 2 ;;
esac
