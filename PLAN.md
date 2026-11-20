# WatchDog — plan

A native macOS focus enforcer for one Mac and one user. Planning only; no code yet.
Written 2026-11-17 against the machine it will run on.

## 1. What I found on your machine

| Item | Value | Why it matters |
|---|---|---|
| macOS | 26.7 (Tahoe), Apple silicon | All APIs below (SMAppService, MenuBarExtra, Swift Charts, XPC peer validation) need macOS 13+, so the deployment target can simply be 26. |
| Xcode / Swift | 27.2 / 6.4.2 | Fine. |
| Code-signing identities | **0** | You have never signed from Xcode on this Mac. The first setup step is adding your Apple ID in Xcode → Settings → Accounts, which creates a free "Personal Team" and an *Apple Development* certificate. |
| SIP | enabled | Keep it. Nothing in this plan needs it off. |
| Browsers | Brave, plus Chrome, Firefox, Safari | The other three are bypass routes; rules must cover them. |
| `/etc/hosts` | hundreds of live entries: local dev sites, a vendor blocklist, LAN hosts | The blocker must own a marked section only and never rewrite the rest. A bug here breaks your dev sites. |
| `/etc/resolver/test` | present (a local `.test` resolver, as dev-server tools install) | Rules out "replace system DNS with our own proxy" as a cheap blocking strategy. |
| pf | stock `pf.conf`, only `com.apple` anchors | Clean starting point. |
| MDM | not enrolled; `/Library/Managed Preferences` exists | Relevant to browser-policy blocking (section 4). |

## 2. The four claims you asked me to verify

### 2.1 "Now playing" is closed to ordinary apps since 15.4 — **correct**

The private MediaRemote framework still accepts playback *commands*, but reads return nothing unless the caller is an Apple-signed process. Still the case on macOS 26.

Alternatives, in the order I recommend them:

1. **Browser tab URL and title.** For a focus app, "what media is playing" mostly means "is the front tab YouTube/Netflix/Twitch". You are collecting that anyway.
2. **Per-app signals for Spotify and Music.** Both have AppleScript dictionaries (needs Automation permission per app). Both also post distributed notifications on track change, which need no permission; I believe these still work on 26 but did not verify it.
3. **CoreAudio process list.** macOS 14.2+ exposes which processes are currently producing audio output, without capturing audio. This answers "is something making sound and which app". From my knowledge of the API, not verified on 26.7.
4. **`ungive/mediaremote-adapter`** (BSD-3). Loads a helper framework into Apple's own `/usr/bin/perl`, which passes the check. Gives real system-wide now-playing. Risks: private API, Apple can close it in any update, and one downstream project reports that an ad-hoc-signed build returns empty data on 26 (the upstream README does not mention this).

Recommendation: build 1–3, put all of it behind one `MediaSource` protocol, and treat 4 as an optional spike.

### 2.2 SMAppService daemon with a free Apple ID — **unconfirmed, must be tested first**

I found no authoritative statement either way. What is known:

- SMAppService needs a real (non-ad-hoc) signature on app and daemon, the same identity on both, and one user approval in System Settings → Login Items. A Personal Team certificate is a real identity, and a plain daemon needs no restricted entitlement, so it *should* work.
- Reports of `Operation not permitted` from `register()` are common and usually mean "awaiting approval" or "app not in `/Applications`", not a signing problem.
- **Definitely not available on a free account:** anything in the Network Extension family (DNS proxy, content filter). Apple DTS confirms this; the only free route is disabling SIP, which I do not recommend.

So this is spike #1 in milestone 0. Fallback if it fails: the app installs a classic plist into `/Library/LaunchDaemons` with one admin password prompt. Still no terminal for you, slightly more install code.

One more free-signing fact: the certificate lasts a year. After renewal you may need to re-approve the daemon and re-grant Accessibility once.

### 2.3 Permissions per feature

| Feature | API | Permission |
|---|---|---|
| Frontmost app | `NSWorkspace` notifications | none |
| Idle time | `CGEventSource.secondsSinceLastEventType` | none |
| Window title | Accessibility (`AXFocusedWindow` → `AXTitle`) | **Accessibility** |
| Window title, other route | `CGWindowListCopyWindowInfo` | Screen Recording — avoid |
| Brave URL | AppleScript to Brave (`URL of active tab of front window`) | **Automation** (one prompt per target app) |
| Spotify / Music track | AppleScript | Automation, per app |
| Close a tab, quit an app gracefully | AppleScript / `NSRunningApplication.terminate` | Automation for tabs; none for quit |

**Window titles do not need Screen Recording.** The Accessibility route returns them; only the CoreGraphics window-list route is gated. So the app needs exactly two kinds of grant: Accessibility (once) and Automation (once per scripted app). The onboarding screen can deep-link to the right System Settings pane and poll until granted.

Two platform notes. Permissions are tied to the app's signature, so a stable signing identity matters: ad-hoc builds lose Accessibility on every rebuild. And there is a reported Tahoe issue with bare background executables and TCC, which is one more reason to keep all tracking inside the GUI app bundle rather than a helper tool.

### 2.4 hosts, pf, secure DNS, caching, changing IPs

- **Secure DNS (DoH) vs hosts.** From my knowledge of Chromium's resolver, it reads `/etc/hosts` itself and answers from it before going to DoH, so a hosts entry wins in Brave even with secure DNS on. Firefox has a pref that does the same. My searches did not confirm either, so this is a 5-minute test in milestone 0 (`brave://net-internals/#dns`).
- **What does bypass hosts:** anything that resolves names remotely. Brave's Tor windows, Brave VPN, proxy/VPN extensions, system VPNs, web proxies. Safari with iCloud Private Relay is a maybe.
- **hosts has no wildcards.** `youtube.com` does not cover `m.youtube.com`. Each rule needs an explicit subdomain list; ship curated lists for the usual suspects.
- **Caching.** After editing hosts, flush the system cache (`dscacheutil -flushcache`, `killall -HUP mDNSResponder`). Brave also keeps its own host cache (about a minute) and, more importantly, keeps existing connections open: a YouTube tab that is already loaded keeps working. Fix: when a block starts, the agent closes or reloads matching tabs and the daemon kills existing pf states.
- **pf and changing IPs.** This is the weak part of the design; see section 7, item 1. Short version: IP blocking either overblocks (YouTube shares addresses with Google Search and Gmail) or underblocks (CDN addresses rotate faster than you can resolve them).
- **A third layer you did not list: Brave managed policy.** Chromium honours a `URLBlocklist` policy that blocks by URL pattern with wildcards, inside the browser, regardless of DNS. Policies can also turn off Tor windows, Brave VPN and incognito. Brave's support page says writing `/Library/Managed Preferences/com.brave.Browser.plist` works on an unmanaged Mac, but one report says macOS may clear such files at reboot, and Brave says some policies need real MDM. A daemon that re-applies state already handles deletion. Spike in milestone 0.

## 3. Architecture

### Processes

```
┌─ WatchDog.app (you, GUI session) ──────────┐        ┌─ WatchDogDaemon (root)    ─────────┐
│ Tracker: app, title, URL, media, idle      │        │ Owns: rules, active block, timer     │
│ Rule evaluator: usage + rules → verdicts   │  XPC   │ Applies: hosts section, pf anchor,   │
│ Soft enforcement: warn, close tab, quit    │◄──────►│   Brave policy, kills blocked apps   │
│ UI: menu bar, popover, main window         │        │ Reconciles on file change + timer    │
│ Usage DB (SQLite, yours)                   │        │ State files (root-owned)             │
└────────────────────────────────────────────┘        └──────────────────────────────────────┘
```

- **The app is also the agent.** It runs as a menu-bar app (no Dock icon unless the main window is open) and is registered as a login item so launchd restarts it if it is quit.
- **The daemon is the authority.** Anything that must survive you quitting the app lives there: rule definitions, the active block, the timer. During a block it only accepts requests that make things stricter.
- **Rule evaluation is split.** The daemon stores the rules; the agent has the usage data, so it evaluates thresholds and tells the daemon "start block X". The agent is the less trusted half, so the daemon checks its heartbeat: no heartbeat, or a report that Accessibility was revoked, during a focus session counts as a violation and triggers the session's block.
- **App killing is done by both.** The agent asks nicely (so you get a save dialog); the daemon force-kills by bundle path if the app is still alive after a grace period, and keeps killing relaunches.

### Communication

`NSXPCConnection` to a Mach service declared in the daemon's launchd plist. XPC is macOS's built-in typed IPC: no ports, no sockets to manage. The daemon checks the caller's code signature (`setCodeSigningRequirement`, macOS 13+) so only your signed app can talk to it.

Interface, in outline: `status()`, `startBlock(spec)`, `extendBlock(seconds)`, `saveRules(rules)` (rejected if it loosens anything mid-block), `heartbeat(health)`, `reportViolation(ruleID)`, `uninstall()` (rejected mid-block).

### Where data lives

| Data | Location | Owner | Format |
|---|---|---|---|
| Usage history | `~/Library/Group Containers/<team>.local.watchdog.private/WatchDog/usage.sqlite` (app-only App Group; macOS keeps other developers' programs out) | you | SQLite (GRDB library), encrypted with SQLCipher; the key is in the login keychain |
| Rules, categories | `/Library/Application Support/WatchDog/rules.json` | root | JSON, atomic write |
| Active block + timer | `/Library/Application Support/WatchDog/state.json` | root | JSON, atomic write |
| Audit log | same folder, `audit.log` | root | append-only lines |
| hosts entries | `/etc/hosts`, between `# >>> WatchDog` / `# <<< WatchDog` | root | — |
| pf rules | anchor `com.watchdog`, loaded in memory | root | — |

SQLite through GRDB rather than SwiftData: you already think in SQL, and it is easy to inspect.

### Storage schema, in outline

Usage DB (agent). Interval rows, not samples: if the new sample equals the open row, extend its `ended_at`.

- `spans(id, started_at, ended_at, bundle_id, app_name, window_title, url, domain, category_id, is_idle)`
- `media_spans(id, started_at, ended_at, source_bundle_id, title, artist, url)`
- `verdicts(id, at, rule_id, action, detail)` — every warning, close and block, for the charts
- `sessions(id, started_at, planned_seconds, kind, ended_at)` — mirror of daemon blocks for display (built in §19 for pomodoro sessions, `kind = 'focus'`)
- `daily_rollup(day, category_id, domain, bundle_id, seconds)` — keeps charts fast

Daemon state.

- `rules.json`: `categories[]` (name, apps, domain lists) and `rules[]`: *match* (category / app / domain / title pattern), *when* (always, schedule, during focus session), *threshold* (continuous or cumulative seconds in a window), *escalation* (warn → close → block for N minutes).
- `state.json`: `block{id, domains, apps, remaining_seconds, checkpointed_at_uptime}`, `session{...}`, `tamper_count`.

### The timer

Kept as `remaining_seconds`, decremented from the continuous clock (which keeps counting during sleep) and checkpointed every 10 seconds. The wall clock is never consulted, so changing the date does nothing. After a reboot the daemon resumes from the last checkpoint: time spent powered off does not count, and a hard power-off costs at most 10 seconds.

Schedules ("weekdays 9–17") necessarily use the wall clock. The daemon compares wall-clock and continuous-clock deltas and treats a jump as tampering: schedules stay in their previous state until the next reboot or the jump is undone.

### Project layout

One Xcode project, three targets: `WatchDog` (app), `WatchDogDaemon` (daemon, embedded in the app bundle with its launchd plist), and `WatchDogCore` (a Swift package holding the XPC protocol, models, rule engine and timer logic, so the logic can be unit-tested with `swift test` without touching the system).

## 4. Milestones

Each ends in something you can run.

**M0 — Skeleton and spikes (de-risking).** Add Apple ID in Xcode. Empty menu-bar app. Then four throwaway spikes, each a go/no-go:
- A. Register a do-nothing daemon with SMAppService under the Personal Team; an XPC ping returns "running as root". *Fail → classic LaunchDaemon install.*
- B. Brave hosts test with secure DNS on; managed-policy test (`brave://policy` shows `URLBlocklist`, still there after reboot). *Fail → hosts only for Brave, see bypass table.*
- C. Read title via Accessibility and URL via AppleScript from a signed build.
- D. Media: CoreAudio process list, Spotify notification, optionally the MediaRemote adapter.
- Also in M0: `uninstall.sh`, written and tested before anything it needs to undo exists.

*Runs:* menu-bar icon; a debug window printing spike results.

**M1 — Tracking.** Sampler (event-driven for app switches, 2–5 s poll for title/URL, idle detection), SQLite storage, permissions onboarding screen, a plain "today" table.
*Runs:* leave it on for a day, see your real timeline.

**M2 — Rules, dry run.** Rule engine in `WatchDogCore` with unit tests; basic rule editor; engine runs against live tracking but only sends notifications ("would have closed YouTube"). Run this for several days to tune thresholds before anything can bite.
*Runs:* notifications when rules trip; verdict log.

**M3 — Enforcement,** in four steps, all under the dev safety caps of section 5:
- 3a. Daemon + XPC + hosts section + cache flush + tab closing. *Runs:* start a 2-minute block of `example.com`.
- 3b. Timer persistence. *Runs:* reboot and change the date mid-block; block survives.
- 3c. App closing, agent heartbeat, tamper handling. *Runs:* quit the agent mid-block; it comes back.
- 3d. pf anchor and Brave policy, per the M0 results.

**M4 — UI polish.** Menu-bar state and countdown, start-session popover, rules window, Swift Charts usage views, in-app uninstall, onboarding that walks through daemon approval and each permission.

**M5 — Arming.** Remove the dev caps, install to `/Applications` owned by root, switch to the release identifiers, write down the rescue procedure on paper.

## 5. Development safety

The dangerous period is M3, when a root process with bugs edits your network config.

1. **Two identities.** Debug builds use `com.<you>.watchdog.dev` for bundle ID, daemon label, state folder, hosts markers and pf anchor. A dev build cannot touch the armed install's state, and vice versa.
2. **Hard caps compiled into debug builds.** Maximum block 5 minutes. Blockable domains limited to a test list (`example.com`, `example.org`). Dead-man switch: the dev daemon removes everything it applied and exits 15 minutes after start, whatever its state says.
3. **hosts hygiene.** Only the marked section is ever touched. Write to a temp file, verify the result still contains every line outside the markers byte-for-byte, then rename atomically. Back up the original once at install. Refuse to write if the file fails to parse. Your existing entries make this non-negotiable.
4. **pf hygiene.** Never edit `/etc/pf.conf`. Load rules into a private anchor; enable pf with `pfctl -E`, which returns a token so disabling later does not turn off pf for anyone else. Rules are outbound-only blocks to a named table: nothing that can touch loopback, LAN, or local dev servers.
5. **Fail-open on daemon crash in dev, fail-closed when armed.** In dev, a crash-loop detector clears everything. Armed, state persists.
6. **`uninstall.sh` exists from M0** and lives outside the app: boots out the daemon, strips the hosts section, flushes the anchor, removes the Brave policy file, deletes state, unregisters the login item. Every time enforcement gains a new mechanism, the script gains its undo in the same change.
7. **A VM for M3 is worth an hour.** Apple silicon runs macOS guests for free (UTM). A broken pf rule in a VM costs nothing.
8. **Last resort,** if the Mac is unusable: Safe Mode (hold power at boot → Shift-click the volume) does not load third-party launch daemons; from there run the uninstall script.

**Clean uninstall** (M4, in-app): refuses during a block; otherwise calls the daemon's `uninstall()`, which undoes its own changes and unregisters itself, then the app removes its login item and offers to delete usage history. TCC grants are removed with `tccutil reset` for the bundle ID. The script from item 6 is the same procedure for when the app cannot run.

The honest part: item 6 is also the bypass. Anything that can rescue you can release you.

## 6. Bypasses the design leaves open

| Bypass | Effort for you | Cost to close |
|---|---|---|
| Run the uninstall script / `sudo launchctl bootout` | ~1 min, needs password and a terminal | Cannot close without MDM. Mitigation: hosts entries stay in place when the daemon dies (fail-closed), and the agent nags full-screen while the daemon is missing. |
| Switch the daemon off in System Settings → Login Items | 3 clicks | Cannot close without MDM. Same mitigation. This is the cheapest bypass in the design. |
| Edit hosts / `pfctl -d` | seconds, reverted in seconds | Already closed by reconciliation. |
| Use Chrome, Firefox or Safari | trivial | Cheap: hosts is system-wide; rules also close non-approved browsers during a block. |
| Brave Tor window, Brave VPN, proxy extension | trivial if not handled | Cheap if spike B passes (policy disables them). Otherwise medium: agent detects Tor/VPN windows and closes them. |
| System VPN or web proxy site | 1–2 min | Medium: agent detects VPN interfaces and proxy-site URLs and treats them as violations. Whack-a-mole. |
| Alternative front-ends, embeds, unlisted subdomains | minutes of searching | Ongoing list maintenance. The URL tracker catches what DNS misses. |
| Quit the agent | seconds | Cheap: launchd restarts it; daemon heartbeat check. |
| Revoke Accessibility / Automation | 30 s | Cheap: agent reports it, daemon treats it as a violation. |
| Delete the app | 10 s | Cheap: install root-owned in `/Applications` so deletion needs a password. |
| Change the clock | 30 s | Timer immune; schedules handled by jump detection. |
| Second user account | 1 min | hosts/pf still apply. App closing does not. Cheap to extend, probably not worth it. |
| Reboot | 1 min | pf is empty for a few seconds at boot; hosts and the timer persist. |
| Recovery mode, phone, another computer | — | Out of scope, as you said. |

The two that cannot be closed (rows 1 and 2) set the ceiling: **a determined you is out in under a minute, with a password prompt.** Everything else is about making the easy routes unavailable so that the only way out is a deliberate act.

## 7. Where I think your decisions are wrong

1. **pf as a co-equal blocking layer.** IP blocking does not fit domain blocking. YouTube shares addresses with Google Search, Gmail and Maps, so a pf block on resolved YouTube IPs breaks things you need; and for CDN-fronted sites the addresses rotate, so the block leaks. Recommendation: hosts plus Brave policy as the blocking layers, and pf in two narrow roles only: blocking DNS-over-TLS (port 853) and known DoH resolver addresses, and killing live connections when a block starts. The correct tool for per-domain network blocking is a Network Extension DNS proxy, which costs the $99/year developer programme. Keep the blocker behind one protocol so it can be added later.
2. **"Re-apply every few seconds."** Polling `pfctl` and rewriting hosts on a short timer is wasteful and noisy in logs. Watch the files for changes (kernel file events are instant) and keep a slow 30–60 s timer as a backstop.
3. **"The daemon does the enforcing."** Not all of it can: a root daemon has no access to your GUI session, so it cannot close a tab or quit an app politely. Enforcement has to be split as in section 3. The consequence is that the agent's liveness becomes part of the security model, which your design did not mention.
4. **No early exit, with no limits.** Combined with your own bugs, this can lock you out of documentation you need to fix the lockout. Recommendation: a hard maximum block length (say 4 hours) and a permanent never-block list (Apple, your docs sites, your bank) enforced in the daemon. Neither is an exit.
5. **Rules stored where?** Not stated in your decisions. If rules are a user-owned file, editing them is the bypass. They belong to the daemon.

Decisions I agree with: native Swift, no local server, two processes with XPC, elapsed-time timer in a root-owned file, no sandbox.

## 8. Risks and open questions

| # | Question | Recommendation |
|---|---|---|
| 1 | Does SMAppService accept a Personal Team daemon? | Spike A decides. Fallback is ready and costs about a day. |
| 2 | Pay $99 for the developer programme? | Not yet. Build on free signing; revisit if spike B fails or pf proves as leaky as I expect. It buys the DNS-proxy extension and a stable long-lived identity. |
| 3 | Use the MediaRemote adapter? | Only if spikes show tab URL + Spotify/Music + CoreAudio miss something you care about. It is the part most likely to break on an OS update. |
| 4 | Does Brave honour unmanaged policy files durably on 26.7? | Spike B. If yes, it becomes the primary Brave blocker. |
| 5 | Does sleep count toward the timer? | Yes (continuous clock). Otherwise closing the lid pauses your block forever. |
| 6 | Should a focus session block by allowlist instead of blocklist? | Later. Blocklists first; allowlist mode ("only these apps and domains") is stronger but breaks more. |
| 7 | Swift 6 strict concurrency | Xcode 27 defaults will flag data races as errors. Good for a daemon, steep for a first Swift project. Keep it on for `WatchDogCore`, relax per-target if it stalls you. |
| 8 | Annual certificate renewal | Expect to re-approve the daemon and Accessibility once a year. Put the date in your calendar. |
| 9 | macOS updates | The private or semi-documented parts (TCC behaviour, Login Items, Brave policy path) can change. Keep each behind a small interface with a health check surfaced in the UI. |
| 10 | Local dev servers | `.test` resolution and the existing local hosts entries must keep working. Add "a local dev site loads" to the M3 manual test list. |

## 9. What is verified and what is not

- **Verified from sources this session:** MediaRemote restriction and the adapter's mechanism; Network Extension needs a paid team; CoreGraphics window names need Screen Recording; Brave's documented policy-file path on unmanaged Macs.
- **From my own knowledge, to be confirmed by the M0 spikes:** SMAppService with a Personal Team; Chromium and Firefox honouring hosts under DoH; Accessibility titles on 26.7; CoreAudio process list; Spotify/Music notifications; durability of the Brave policy file.
- **Nothing was built or run** beyond read-only checks of this Mac's configuration.

## 10. Milestone 0 results (2026-11-17)

| Spike | Result |
|---|---|
| A. SMAppService daemon on free signing | **Pass.** Signed with a free Personal Team, registered from the build folder, approved once in Login Items, answered an XPC ping with `uid=0`. Unregister, rebuild and re-register needed no second approval. |
| C. Front app, idle, Brave address | Pass from the command-line probe. |
| C. Window title via Accessibility | Open: needs the Accessibility grant in the app. |
| D. CoreAudio process list | Reads fine; the "is playing" flag is untested with real audio. |
| D. Spotify / Music notifications | Open. |
| B. Brave obeys hosts under secure DNS | **Pass.** With secure DNS in strict mode (`secure`, OpenDNS), `example.com` → `0.0.0.0` in hosts gave "Privacy error" instead of the site. Secure DNS can stay on. |
| B. Brave obeys an unmanaged policy file | **Pass after restart.** `URLBlocklist` blocked `example.org`; the control site loaded. |
| B. Policy file survives a reboot | Open. |

Lessons:

- Xcode 27 does not list accounts in the `DVTDeveloperAccountManagerAppleIDLists` preference; check the keychain identity instead.
- A fresh Apple Development certificate is invalid until the WWDR G3 intermediate is installed. Xcode installs it on the first build with automatic signing.
- macOS has its own `/usr/libexec/watchdogd`. Our daemon binary is `WatchDogDaemon`, and nothing may ever kill by the name `watchdogd`.
- Brave's page cache can show a blocked site as if it loaded. When a block starts, matching tabs must be reloaded or closed, and tests need a cache-busting query string.
- On a Mac that runs a local web server (Valet, Herd and the like), `0.0.0.0` lands on it, so a hosts-blocked HTTPS site shows a certificate warning, not a clean "can't connect". Consider answering blocked names with a small "blocked by WatchDog" page later.
- `register()` throws "Operation not permitted" on first use; that means "awaiting approval", not failure.

## 11. Milestone 1 status (2026-11-17)

Built: `Tracker` (2 s timer plus app-switch events), `UsageStore` (SQLite via GRDB, span merging), a plain Today window, menu-bar status. Unit tests cover merging, gaps, totals and media (7 passing).

Confirmed on real data: front app, Brave address and domain, sound source (Brave playing audio was recorded and credited to the app, not its helper process).

Not yet confirmed: window titles (Accessibility not granted to the app yet), Spotify/Music track titles, away spans (needs 2 minutes without input), the Today window's appearance.

Known gaps, deliberate for now: the app does not start at login; no daily rollup table; history is never pruned.

Database: `usage.sqlite` in the private App Group container (`UserData.folder`) (tables `spans`, `media_spans`).

## 12. Milestone 2 status (2026-11-17)

Built: `Rule` / `Schedule` model, `RuleEngine` (pure logic), `RuleFile` (JSON), a `verdicts` table, `RuleRunner` (evaluates every ~4 s, dry run only, posts notifications), and a Rules tab with an editor, live progress per rule and a log. 21 unit tests pass.

Semantics worth remembering:

- A rule matches a span by app, site (subdomains included) or window-title keyword; any one is enough. Away time never matches.
- "In one sitting" forgives breaks of up to 20 s and resets on longer breaks, away time, or a hole in the history.
- "In total" adds matching time over a look-back period.
- A rule only fires while you are on the activity, then stays quiet for its cooldown. Cooldowns survive an app restart.

Confirmed live: a temporary 10-second rule fired once, was logged as a dry run, and did not re-fire during its cooldown. Away detection was confirmed by accident (the user stepped away mid-test).

Not confirmed: that the notification banner actually appears, and the Rules tab on screen.

Deviation from section 3: rules live in a user-owned `rules.json` for now and move to the daemon in milestone 3. Categories were dropped; each rule carries its own app and site lists.

Dev commands: `WatchDog --rules` prints each rule's current count and whether it would fire.

## 13. Pomodoro-aware rules (2026-11-17)

Rules can now depend on an external pomodoro timer. The tracker reads the Session app's shared preferences file (`RunningSession` in its group container; read-only, no Shortcut or scripting) and stores `timer_state` (`focus`, `break`, `none`) on every span.

- New rule field "Pomodoro timer": any time, except during a break, only during focus, only during a break.
- A limit of zero means "not allowed at all" and fires as soon as the activity is seen.
- "Free at certain hours" needs no rule: outside a rule's schedule nothing applies.
- Current rule set: YouTube, weekdays 09:00 to 19:00, "Pomodoro it" with the classic rhythm, response "close" (dry run).

"Pomodoro it" (a third limit mode): the activity is allowed only during a break, and only while a budget lasts. Focus time (timer on focus, at the keyboard, not on the activity itself) earns break time at the rhythm's own ratio: classic 25/5/15/every 4 gives 0.3, i.e. 18 min per hour of focus. Time on the activity during breaks spends it. One break is capped at the long-break length. The budget starts at zero when the day's schedule period begins. All four numbers are settable per rule, as are the days and hours.

Known limits: Session's state names are `session` (focus) and `rest` (break), both observed live; a paused focus session still counts as focus; an endless break no longer helps: it earns nothing.

## 14. Milestone 4, first pass: interface (2026-11-17)

Design approach: standard Mac structure and system materials, so the app inherits Liquid Glass, light/dark mode, accent colour and accessibility settings. Glass is left to the navigation layer (sidebar, toolbar, popover buttons); content sits on plain filled cards.

- Main window: `NavigationSplitView` with Today, Rules, History and a Developer section. It shows a Dock icon while open and returns to menu-bar only when closed.
- Today: a "now" strip, four headline tiles, a stacked per-hour chart (Swift Charts), apps and sites with real app icons and proportional bars, and a recent-activity timeline.
- Rules: list with live status per rule, an editor that states the rule as one sentence, a break-budget gauge, clear weekday chips.
- History: rule firings grouped by day.
- Menu bar: the symbol changes with the timer state and shows the number that matters (focus time left, or break budget left). The popover is a glance: now, timer, budget, three figures, Open and Quit.
- App icon generated by `scripts/make-icon.swift`.
- `DaySummary` (pure, tested) computes everything the dashboard shows. 48 unit tests pass.

Looked at on screen: Today and Rules, dark mode. Not yet looked at: the menu-bar popover, History with entries, light mode, narrow window widths.

Dev launch option: `WatchDog --show-window` opens the main window at start.

Still to do in this milestone: start at login, onboarding for first launch, in-app uninstall, Settings window.

## 15. Milestone 3a status: enforcement, first step (2026-11-17)

Built:

- Daemon `BlockManager`: one block at a time (domains + seconds remaining), counted on a clock that ignores the system date and keeps running in sleep, saved every 10 s to a root-owned `state.json`, resumed on start. Every 2 s it makes `/etc/hosts` match the block, touching only its own marked section, via an atomic swap, with a one-time backup.
- XPC: `status` and `startBlock`. There is no stop call. The daemon only accepts connections from the app signed by our team.
- Development caps in the daemon: 5-minute maximum, only `example.com/.org/.net`, strict domain syntax, dead-man switch at 15 minutes of uptime.
- App: `Enforcer` closes matching tabs (Brave, Chrome, Edge, by tab ID) and politely quits matching apps. A "Dry run / Enforcing" switch in the toolbar, off by default, with a confirmation. While enforcing, a reopened tab is closed again within about 6 s. A running block shows as a banner with no cancel button.
- `scripts/uninstall.sh` now stops the daemon, then removes the hosts section.

Verified live: a real domain is refused; a domain string carrying a second hosts line is refused; `example.com` blocked for 40 s resolved to `0.0.0.0`; restarting the daemon mid-block resumed it (from the last checkpoint, so it restarted at 40 s: a restart can lengthen a block by up to 10 s, never shorten it); a shorter request did not shorten it; at expiry the hosts file was byte-identical to before. 58 unit tests pass.

Not verified: tab and app closing (enforcement has not been switched on), reverting a manual edit of the section (needs sudo), rejection of an unsigned XPC caller, a real reboot, the dead-man switch.

Deviations from section 3, to resolve in 3b-3d: rules and the Enforce switch still live in user-owned storage; no agent heartbeat; no pf rules or Brave policy; hosts is polled every 2 s rather than watched.

## 16. Milestone 3b status: timers that survive (2026-11-17)

- The daemon's launchd job now has `RunAtLoad` and `KeepAlive`: it starts at boot without waiting for the app, and launchd restarts it if it exits. (In dev builds the 15-minute dead-man switch therefore acts as a periodic reset.)
- Measured on this Mac: `CLOCK_MONOTONIC_RAW` read 31.86 h since boot against 23.08 h awake, so the block countdown includes sleep.
- `TrustedClock` (pure, tested): wall time and time zone are pinned at app start and advanced by the same non-settable counter. If the system clock strays by more than 30 s plus 0.05% of elapsed time, or the zone changes, schedules keep running on the original timeline and a warning is shown. Undoing the change clears it. The tracker stamps activity with the same clock, so setting the clock back cannot make history look stale and silence the rules.

Verified live: launchd reports `keepalive | runatload`; the daemon was running before any client connected; a 30-second block ended and cleaned up with nothing connected. 65 unit tests pass.

Not verified: an actual reboot mid-block, and changing the real system date or zone (both need the user). The trusted clock re-anchors when the app restarts, so restarting the app after changing the date still dodges schedules until rules move into the daemon (3c).

## 17. Milestone 3c status: ownership, heartbeat, staying alive (2026-11-18)

Built:

- **The daemon owns the rules and the Enforcing switch** (`config.json`, root-owned). The app edits a draft and proposes it. `ConfigPolicy` (pure, tested) decides: in dry run everything applies at once; while enforcing, a change that only tightens applies at once, anything else waits out a cooling-off delay (2 minutes in dev builds), and is refused while a block runs. A pending change can be discarded. Any edit to an active rule counts as loosening, even a stricter one; only renames are exempt.
- **Heartbeat.** The app reports every ~8 s whether it can see (Accessibility, browser automation). While enforcing with a user logged in, if the heartbeat is older than 45 s of awake time or reports blindness, the daemon blocks every site named by an enabled rule until the app is healthy.
- **Trusted clock in the daemon**, pinned at boot; the app adopts it at start, so restarting the app no longer resets it.
- **Start at login and keep running** (Settings): an `SMAppService` login agent. Switching it on hands the app over to launchd; a force-kill brings it back. Switching it off reopens it as an ordinary app, and is disabled while enforcing. Quitting is refused while enforcing. Opening the app while it runs shows the main window.
- **Audit log** at `/Library/Application Support/WatchDog-dev/audit.log`.
- Settings screen; notices for pending changes, refusals, penalty blocks and an unreachable daemon.

Verified live against the daemon: first save; tightening applied at once; loosening delayed 120 s and discardable; loosening refused during a block while tightening still applied; a silent app and a blind app each triggered the penalty block and a healthy heartbeat lifted it within seconds; the switch to dry run took effect after the delay; hosts file byte-identical afterwards. Login agent: launchd took over, force-kill came back in about 3 s, switch-off reopened the app normally. 73 unit tests pass.

Not verified: the Enforcing switch and pending-change banner driven from the UI (the daemon side was driven from the command line); tab and app closing; the quit refusal dialog; a real reboot.

Left as found: "Start at login" is off, enforcement is off (dry run), the daemon holds the one real rule.

Remaining for 3d: pf rules, Brave managed policy, hosts file watching instead of 2 s polling.

## 18. Milestone 3d, review fixes, setup, uninstall, armed build (2026-11-18)

### 3d: the other blocking layers

- **Browser policy, narrowed after measuring.** A running Brave does not pick up a policy file (still "Privacy error" from the hosts layer 50 s after the file was written, and after restarting the preferences helper) and does not forget a removed one (a test site from the evening before was still blocked six hours later). Policy is therefore not used for timed site blocks. Its one job: while enforcing, `TorDisabled` for Brave, effective from Brave's next launch.
- **Firewall (pf), optional, off by default** (Settings: "Also block by IP address"). Loads stock `/etc/pf.conf` plus one anchor line into memory, never edits the file; rules are outbound-only to a table of the blocked sites' resolved addresses; stands down if pf carries anyone else's rules. Verified live: a direct-to-IP connection to `example.com` went from HTTP 200 to refused in under a millisecond during the block and back to 200 after, with other traffic unaffected and pf restored.
- Hosts remains the primary layer; it was shown earlier to act within seconds, with Brave's secure DNS on.

### Enforcement end to end

- Rules fired with enforcement on and were logged as real (not dry run); a "Block it" rule started a daemon block.
- Tab closing first failed: inside `tell application`, AppleScript reads the word `tab` as the browser's tab object. Fixed, then verified with the rule's own closing code: it closed exactly the five test tabs out of 26.
- Not verified as one uninterrupted sequence (site in front, rule fires, tab closes), because the owner was using the browser.

### Independent review: 14 findings, all addressed

1. Firewall teardown could wipe another program's rules: it now re-checks that pf is still stock (filter and NAT rules) before restoring.
2. Uninstall missed the policy file and firewall state; the daemon now takes the firewall down on SIGTERM.
3. The heartbeat depended on rule evaluation succeeding: it now runs on its own background timer, status refresh on another, and a recovery screen offers "Switch to Dry Run" if the app cannot open its database.
4. DNS lookups ran on the daemon's main queue: moved to their own queue.
5. An unreadable `config.json` looked like "no rules yet" (anything could then be proposed without delay): it is set aside and the daemon comes up enforcing with no rules.
6. One unanswered request dropped the app to local dry run: what is in force now stays in force.
7. Development commands (a fake heartbeat among them) are compiled out of the armed build.
8. An edit saved while a switch was flipped could undo the switch: requests are now sent strictly in order.
9. Penalty-block domains were taken from the raw rule text, not the cleaned form.
10. Deleting the hosts section's end marker made the daemon swallow everything after it: only its own kind of line is now removed.
11. Schedules running past midnight tested the wrong weekday for the small hours.
12. "In one sitting" forgave any number of short interruptions: an interruption is now judged by its total length.
13. A block rule re-requested its block every few seconds while the page stayed in front, so the block never ended: it now leaves a running block alone.
14. The quit refusal could cancel a logout or shutdown: the quit request's reason is now read directly.

Found on my own pass before the review: a stale rules draft after a delayed change landed; the login grace period counted from boot instead of from login.

### Setup, uninstall

- **Setup** screen (sidebar, with a badge for open items): background service, Accessibility, addresses per installed browser, notifications, start at login, Session.
- **Uninstall WatchDog…** in Settings: the daemon undoes its own changes (refused while enforcing or during a block), then the app unregisters it, optionally deletes history, resets its privacy permissions and removes the login agent.

### Armed build (built, NOT installed)

- Xcode's Release configuration defines `ARMED`: identifiers without `.dev`, its own daemon, rules, history, hosts markers and state folder. Nothing is shared with the development build.
- `Limits` replaces the development caps: 4-hour longest block, any site except the never-block list (`apple.com`, `icloud.com`, `cdn-apple.com`, `mzstatic.com`, `anthropic.com`, `claude.ai`), 2-hour delay on loosening, no dead-man switch, no development commands, no Checks pane.
- `scripts/build-armed.sh` (as yourself) then `sudo scripts/install-armed.sh` (root-owned copy in `/Applications`; refuses to replace a running armed install). `sudo scripts/uninstall.sh --armed` removes it. `docs/RESCUE.md` is the sheet to print first.
- Both variants compile and the armed bundle's signature verifies. 87 unit tests pass.

### Written but never run

Everything after the owner asked for no more app restarts was compiled and unit-tested only: all fourteen review fixes on the app and daemon side, the Setup screen, in-app uninstall, the recovery screen, the reworked firewall teardown, and the armed build as a whole. The development daemon restarts itself every 15 minutes, so it is already running the new daemon code (its log shows a clean start); the app is still the earlier build until it is next relaunched.

Also never exercised: the Enforcing switch and pending-change banner from the UI, the quit refusal dialog, a real reboot mid-block, a real system date or time-zone change, the firewall standing down when other software owns pf.

**Update, 01:13:** after one approved relaunch, verified live on the final build: the app tracks and its heartbeat (now on its own timer) keeps it healthy with the daemon; the toolbar switch asks for confirmation, the daemon goes to enforcing and writes the Tor policy; switching back shows "Your change takes effect in…" with Discard, the toolbar reads "Enforcing, ending soon", and after 120 s the daemon returned to dry run and removed the policy. The daemon's scheduled self-restart brought it up cleanly on the latest code with its config intact. Still unseen: the Setup and Settings screens (sidebar clicks do not register while the window is in the background), in-app uninstall, the recovery screen.

Open question for the owner: a system dialog appears each time a new build of the app starts. Its text is unknown; it is probably macOS asking about access to another app's data (the Session timer file) or Automation, re-asked because each build has a new code signature hash.

## 19. Built-in pomodoro timer (2026-11-18)

Settings → Pomodoro chooses the timer: **Built-in** or **Session** (external, read-only, exactly as in §13). Whichever is chosen feeds the same `timer_state` on spans, so the "Pomodoro timer" rule condition and "Pomodoro it" budgets work unchanged with either. If no choice was ever made, Session is used when it is installed, otherwise the built-in timer.

Sources implement `TimerSource` (one method, `read() -> TimerReading`). External apps also implement `ExternalTimerApp` (id, name, bundle ID) and are listed in `TimerSources.external`; adding another app is a reader plus one line there. The app's `PomodoroTimer` is the tracker's source and dispatches to the chosen one.

The built-in timer:

- Focus, short break, long break, focus sessions per long break: 25 / 5 / 15 / 4 by default, the same `PomodoroSettings` type a rule uses. Start breaks automatically and start focus sessions automatically are separate switches.
- Start, pause/resume, skip and stop from the Focus pane (new, in the sidebar) and from the menu-bar popover. The menu bar shows a pause symbol and the time left while paused.
- Categories (name and colour from a fixed set of system colours) are managed in Settings, chosen when a focus session starts, and can be changed while it runs.
- When a focus session ends: rate it neutral, focused or distracted, and add a note, in the popover or the Focus pane. Both, and the category, can be edited later from the history (Focus pane, grouped by day, last 60 days).
- A notification when an interval runs out.

Semantics (`PomodoroMachine`, pure, tested):

- Interval length is measured on the trusted clock's counter (`CLOCK_MONOTONIC_RAW`, runs during sleep). Changing the date or zone does not move it. Sessions are stamped with the tracker's trusted time.
- Pausing never loosens a rule: a paused focus session still counts as focus; a paused break counts as no timer. A finished interval waiting for Start is also no timer.
- Only focus sessions that run their full length count toward the long break. Skip ends the interval and moves on as if it had run out; a skipped focus session leads to a short break. Stop ends the round (the next start is session 1 again). Skipped or stopped focus sessions under a minute are not kept.
- The next interval starts on its own only if the previous one ended at most 60 s before it was noticed. After sleep, or with the app closed, the timer waits instead of running sessions nobody attended.
- Restarting the app carries on. Restarting the Mac pauses a focus session where it was last saved (every 15 s) and ends a break, so a restart is never a longer break.
- Choosing another source stops the built-in timer, keeping a focus session that ran long enough.

Storage: `timer.json` in the private App Group container (source, settings, timer state; user-owned, each part falls back to its default on its own). Usage DB migration `4-sessions` adds `session_categories` and `sessions` (`kind`, start and end, planned and focused seconds, completed, category, rating, note). Removing a category that sessions use hides it instead of deleting it.

Known limits: like Session, the timer belongs to the user. Skipping straight to a break, or editing `timer.json`, gives a break for rules with the "Pomodoro timer" condition. "Pomodoro it" is the rule that holds: its budget is earned by focus time at the rule's own rhythm, which is set per rule and does not follow the timer's lengths.

Verified: 123 unit tests pass (26 new: the machine, the timer file, the store and the migration from an older database); Debug and Release build. **Nothing was run on screen**: the app was not relaunched, at the owner's request. Not yet seen: the Focus pane, the popover controls and rating, the Settings section and colour picker, notifications, light mode, the migration on the real usage database (it runs at next launch), and a Mac restart mid-session.

Dev: `WatchDog --rules` prints the chosen source and its state.

## 20. History privacy and a third security review (2026-11-18)

Built and unit-tested (133 tests), not run live. Details and the open items are in `memory.md`.

- **History keeps less.** New activity stores the site, not the page address. Settings → History → Page addresses can instead keep the full address with sensitive parts removed (passwords, tokens, keys, session IDs, email addresses, card numbers and generated-looking strings, by pattern; best effort) or the full address as is; choosing less also tidies what is already stored at the next expiry pass. Window titles, addresses and track names are cleared after 30 days and activity is deleted after a year, both settable with floors of 7 and 30 days (rules look back at most a day); pomodoro sessions are kept. The database file is now private to the account (0600), and cleared rows are overwritten. The owner approved these defaults; all of them can be changed in Settings.
- **A span can no longer run backwards** when the clock steps back (the app adopting the daemon's clock after starting with a moved system clock). Such a span subtracted from rule totals and gave "Pomodoro it" budget back.
- **Review fixes:** duplicate rule IDs refused; audit lines escaped; firewall addresses validated on their bytes (no multicast, mapped, documentation or shared ranges); IPv6 connections killed at block start; RESCUE.md and the scripts hardened (private temp file, fixed `PATH`, uninstall stops if the daemon survives `bootout`, quits only its own build's app, spike revert cannot delete past its section).
- **Open, for the owner:** the daemon trusts any team-signed build (pin the installed app); dev and armed share the Brave policy; the firewall can still hit never-block sites through shared addresses; two items need a live test (enrollment's admin check under `allow-root`, renaming the bundle in an admin-writable `/Applications`).
- The per-build prompt is macOS's "access data from other apps", caused by reading Session's group container; the built-in timer avoids it.

## 21. Widgets (2026-11-19)

Two desktop and Notification Center widgets, in a WidgetKit extension embedded in the app (`Widgets/`, target `WatchDogWidgets`, bundle ID `$(WD_ID).widgets`, so `local.watchdog.dev.widgets` in Debug and `local.watchdog.widgets` in the armed build):

- **Focus & Breaks** (small, medium, large): focus today (at the keyboard with the timer on focus, the Today screen's "Focus"), focus intervals, breaks earned (the first enabled "Pomodoro it" rule's budget: what is left of what was earned; without such a rule, focus time at the built-in timer's rhythm), and breaks taken (count, and time with the timer on a break, away included). Large adds focus and break time for the last seven days.
- **Pomodoro** (small, medium): what runs and the time left (a ring and a live countdown), category and round, and the Focus screen's buttons for that moment: Start Focus / Start Break / Skip Break when idle, Pause / Skip / Stop while running, Resume / Skip / Stop while paused. With Session as the source it shows Session's interval read-only and says where to choose WatchDog's timer.

How it works. A widget extension must be sandboxed and the usage database is private to the app, so the widget never opens it:

- Both targets claim one App Group, `<team ID>.<app bundle ID>` (`<team ID>.local.watchdog.dev`). A macOS-style group needs no registration and no provisioning profile, and macOS 15+ lets code signed by that team open the container without the "access data from other apps" prompt. Checked: both configurations build and sign with the free Personal Team, nothing is provisioned, `codesign --verify --deep --strict` passes, and the Release extension has the hardened runtime, the sandbox and no debugger entitlement. The group ID reaches the code through `WDAppGroup` in each Info.plist (`WD.appGroupID`); a build without a team has no widgets.
- The app (`App/WidgetBridge.swift`) writes `WatchDog/snapshot.json` in the container at once when the timer changes and every minute otherwise: numbers and timer state only, no titles, addresses, apps or notes. It asks WidgetKit to redraw only when the timer changed or a command was handled (redraws are rationed); the widgets fetch the day's totals themselves every 15 minutes and draw the countdown on their own. A snapshot more than 3 minutes old means the app is not running: the widgets say so and offer no buttons.
- A button runs `TimerControlIntent` in the extension. It cannot reach the timer: it writes `WatchDog/commands/<id>.json`, posts a Darwin notification, waits up to 2.5 s for the app's receipt in the snapshot, and takes the command back if none comes (the app also looks every 2 s). The app takes the command and `WidgetCommandPolicy` carries it out only if it is under 30 s old, the built-in timer is the source, the timer is still the one the button was drawn for (a token of status, interval and start), and the Focus screen offers that button now. It then calls the same `PomodoroTimer` methods as the Focus screen, so pausing still never loosens a rule and the widget cannot change rules, enforcement, settings or the source. Linked folders in the container are refused (the app removes the files it takes).
- `scripts/build-armed.sh` also checks the extension's signature, hardened runtime, sandbox and lack of Apple Events; `install-armed.sh` checks its signer when present.

Pure parts in WatchDogCore (`Widgets/WidgetSnapshot.swift`, `Widgets/WidgetChannel.swift`): `FocusTally`, `WidgetBreaks`, `WidgetTimer`, `WidgetSnapshot`, `WidgetCommandPolicy`, `WidgetChannel`. 36 new tests (core suite 184).

Decided (owner, 2026-11-19): the Pomodoro widget's buttons work only with Built-in chosen in Settings → Pomodoro. The widget never switches the source; with Session (or another external app) chosen it shows that timer read-only and points to the setting. Seen live after one relaunch (2026-11-19, owner): both widgets added from the gallery show live numbers, and the Pomodoro widget's buttons start and pause the built-in timer. The extension links all of WatchDogCore (13 MB in Release); splitting the shared types into a small module would shrink it.

## Sources

- [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
- [BetterTouchTool forum: Now Playing broken on 15.4](https://community.folivora.ai/t/now-playing-is-no-longer-working-on-macos-15-4/42802)
- [cmux PR: bundle the MediaRemote adapter](https://github.com/manaflow-ai/cmux/pull/21695)
- [Apple forums: testing a Network Extension without a paid account](https://developer.apple.com/forums/thread/825136)
- [Apple forums: SMAppService sample code](https://developer.apple.com/forums/thread/799910)
- [Apple forums: window name not available since 10.15](https://developer.apple.com/forums/thread/126860)
- [Apple forums: Screen Recording and background executables on Tahoe 26.1](https://developer.apple.com/forums/thread/807323)
- [Brave support: Group Policy](https://support.brave.app/hc/en-us/articles/360039248271)
- [Chromium net/dns source docs](https://chromium.googlesource.com/chromium/src/+/HEAD/net/dns)
- [Mozilla bug 1453207: DoH and /etc/hosts](https://bugzilla.mozilla.org/show_bug.cgi?id=1453207)
- [Apple forums (Quinn): App Groups, macOS vs iOS, and app group container protection](https://developer.apple.com/forums/thread/721701)
- [Apple forums: macOS widgets won't launch with an app group set](https://developer.apple.com/forums/thread/758478)
