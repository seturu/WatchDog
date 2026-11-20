#!/bin/bash
# Regenerates the README illustrations in docs/images from mockups.html.
#
#   docs/images/source/render.sh            all frames
#   docs/images/source/render.sh today rules only these
#
# The mockups are hand-built copies of the SwiftUI layouts (App/UI, Widgets)
# with sample data, not screenshots: no personal history ends up in the repo.
# When a screen changes, change its frame in mockups.html to match.
#
# Needs Google Chrome (headless) and Python 3. SF Symbols, app icons and the
# SF Rounded font are exported into a temporary folder at run time and never
# committed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(cd "$here/.." && pwd)
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$chrome" ] || { echo "Google Chrome is required." >&2; exit 1; }

work=$(mktemp -d)
server=""
cleanup() {
  if [ -n "$server" ]; then kill "$server" 2>/dev/null; wait "$server" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/site/sym" "$work/site/apps"
swift "$here/export-assets.swift" "$work/site" >/dev/null
cp "$here/../../../App/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" "$work/site/apps/watchdog.png"
cp /System/Library/Fonts/SFNSRounded.ttf "$work/site/"
cp "$here/mockups.html" "$work/site/mock.html"

port=8765
(cd "$work/site" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf "http://127.0.0.1:$port/mock.html" >/dev/null && break; sleep 0.3; done

# frame : canvas size in points : scale
specs=(today:1120x960:2 popover:640x470:2 focus:1120x770:2 rules:1120x900:2 setup:1120x670:2
       widgets:1074x300:2 arch:1200x680:2 uninstall:1200x400:2)
for spec in "${specs[@]}"; do
  IFS=: read -r frame size scale <<<"$spec"
  if [ $# -gt 0 ] && [[ ! " $* " == *" $frame "* ]]; then continue; fi
  for theme in light dark; do
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$work/chrome" \
      --force-device-scale-factor="$scale" --window-size="${size/x/,}" --default-background-color=00000000 \
      --virtual-time-budget=1500 --screenshot="$out/$frame-$theme.png" \
      "http://127.0.0.1:$port/mock.html?frame=$frame&theme=$theme" >/dev/null 2>&1
    echo "  $frame-$theme.png"
  done
done
