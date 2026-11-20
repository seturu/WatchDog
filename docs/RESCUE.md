# WatchDog rescue sheet

Print this before switching the armed build to Enforcing. If WatchDog has
locked you out of something you need, your browser may be part of the problem,
so this page should not live only on the Mac.

## What can lock you out, and how each ends by itself

| Situation | Ends when |
|---|---|
| A block is running | Its timer runs out (4 hours at most). A restart does not shorten it; sleep counts as time passing. |
| "Blocked because WatchDog could not watch" | WatchDog is running again with its permissions (Accessibility, and Automation for your browser). Open WatchDog, then Sidebar > Setup. |
| A change is waiting | 2 hours after you asked for it. Asking again for the same thing does not restart the wait. |
| WatchDog will not quit | Enforcement is on. Switch to dry run in the toolbar; it takes effect after the wait. Logging out, restarting and shutting down always work. |

Never blocked, whatever a rule says: apple.com, icloud.com, cdn-apple.com,
mzstatic.com, anthropic.com, claude.ai.

## Removing WatchDog completely

This is the deliberate way out. It needs a terminal and your password.

1. Open Terminal (Spotlight: type Terminal).
2. Go to the project folder and run the uninstaller:

       cd ~/Server/WatchDog
       sudo scripts/uninstall.sh --armed

   (Without `--armed` it removes the development build instead.)
3. Restart Brave so it drops the "managed" setting.
4. Move /Applications/WatchDog.app to the Trash (it asks for your password).

## If the project folder is gone

The same steps by hand, one line at a time in Terminal. First stop WatchDog:

    sudo launchctl bootout gui/$(id -u)/local.watchdog.agent
    sudo launchctl bootout system/local.watchdog.daemon

Remove WatchDog's lines from the hosts file. The first line makes a private
temporary file (never a fixed name in /tmp, which another account could
prepare); the second writes a cleaned copy into it; `diff` shows what would go
(only WatchDog's marker and `0.0.0.0` / `::` lines); the fourth puts it in
place. Run them in the same Terminal window:

    t=$(mktemp)
    awk '/^# >>> WatchDog \(managed/{s=1;next} s&&/^# <<< WatchDog$/{s=0;next} s&&/^(0\.0\.0\.0|::) /{next} {s=0;print}' /etc/hosts > "$t"
    diff /etc/hosts "$t"
    sudo tee /etc/hosts < "$t" > /dev/null; rm -f "$t"
    sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

Check Brave's policy file before removing it:

    plutil -p "/Library/Managed Preferences/com.brave.Browser.plist"

If that prints only `"TorDisabled" => true`, the file is WatchDog's: remove it
with the first line below. If it prints anything else, another program manages
Brave, so keep the file. Either way, remove WatchDog's marker with the second:

    sudo unlink "/Library/Managed Preferences/com.brave.Browser.plist"
    sudo unlink "/Library/Managed Preferences/.watchdog.com.brave.Browser"

Empty WatchDog's firewall anchor:

    sudo pfctl -a local.watchdog -F rules
    sudo pfctl -a local.watchdog -F Tables

The two `pfctl` lines empty WatchDog's own firewall anchor and nothing else.
They print an error if it has nothing loaded, which is fine. If the state folder
still contains `pf.token`, the firewall may stay switched on, with no WatchDog
rules in it, until the next restart. That is harmless.

Then check the hosts file: `tail /etc/hosts` should show no WatchDog lines.
The daemon's leftover folder is `/Library/Application Support/WatchDog`. It
is readable by root only. It holds `hosts.backup`, a copy of the hosts file as
it was before the first edit. If the hosts file seems wrong, look at it with
`sudo cat "/Library/Application Support/WatchDog/hosts.backup"`, then remove
the folder with `sudo rm -rf "/Library/Application Support/WatchDog"`.

## If the Mac will not start normally

Start in Safe Mode: shut down, hold the power button until "Loading startup
options" appears, select your disk, hold Shift and click "Continue in Safe
Mode". Third-party background services, WatchDog's included, are not started
there. Then follow "Removing WatchDog completely".

## Where to look when something seems wrong

- What the daemon did, and every attempt to loosen things:
  `sudo tail -50 "/Library/Application Support/WatchDog/audit.log"`
- What is blocked right now: the end of `/etc/hosts`
- Your usage history and rules cache: `~/Library/Group Containers/<team ID>.local.watchdog.private/WatchDog`
  (before the private container existed: `~/Library/Application Support/WatchDog`)

## Owner enrollment

For an extracted public download, use the installer in a trusted checkout:
`sudo scripts/install-armed.sh --download "/absolute/path/to/WatchDog.app"`.
For a local build, use `sudo scripts/install-armed.sh`.

The armed installer enrolls the account that invoked sudo. For a development
build, an install performed directly as root, or an older installation, open
Setup from the intended account. Install and approve the updated background
service, then choose **Enroll This Account…**. An
administrator can approve a standard user's enrollment. Existing rules, timers,
and history are kept. An existing owner cannot be replaced through Setup.
When upgrading a registered development build, re-register the rebuilt daemon
with the development app's `--daemon restart` command so launchd picks up the
enrollment service in its updated job definition.

The uninstall script also removes the owner record. When following the manual
armed removal above, remove `/Library/Preferences/local.watchdog.owner-uid`
with administrator privileges after stopping the daemon.
