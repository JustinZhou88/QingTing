#!/bin/bash
# Install QingTing on an iPhone: ./install-ios.sh
# Apps signed with a free Apple ID expire after 7 days; just run this again. Settings are kept.
# No cable needed after the first time: once the phone has been paired over USB, it only has to be on a network where the Mac can discover it (unlocked, screen on)
# and this script installs over Wi-Fi. Networks that isolate clients (e.g. campus Wi-Fi) do not work; the iPhone's Personal Hotspot (with the Mac joined) or your own router does.
# Before the first run: ./setup-deps.sh to prepare the third-party libraries, and sign in with your Apple ID under Xcode > Settings > Accounts.
set -euo pipefail
cd "$(dirname "$0")"
# Machine-local configuration such as the developer team ID (not in the repository)
[[ -f local.env ]] && source local.env
export QINGTING_TEAM_ID="${QINGTING_TEAM_ID:?put QINGTING_TEAM_ID=<your developer team ID> in local.env}"
# A local proxy configured in the shell but not running keeps Xcode from reaching Apple's servers
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy

# Only iPhones that are really reachable: state "connected" (cable) or "available (paired)" (wireless).
# Note that "unavailable" also contains "available" and must be excluded first.
UDIDS=$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -i "iphone" | grep -v "unavailable" \
    | grep -E "connected|available" | grep -oE "[0-9A-F]{8}-[0-9A-F]{16}" || true)
if [[ -z "$UDIDS" ]]; then
    echo "No reachable iPhone found: unlock the phone and connect it with a cable, or put the Mac and the phone on the same hotspot"
    exit 1
fi

xcodegen generate >/dev/null
APP=build/DerivedData/Build/Products/Debug-iphoneos/QingTing.app
# Install on every phone that is connected
for UDID in $UDIDS; do
    NAME=$(xcrun devicectl list devices 2>/dev/null | grep "$UDID" | sed -E 's/ {2,}.*//')
    echo "→ $NAME"
    xcodebuild -project QingTing.xcodeproj -scheme QingTingPhone -configuration Debug \
        -destination "id=$UDID" -derivedDataPath build/DerivedData -allowProvisioningUpdates build 2>/dev/null \
        | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
    xcrun devicectl device install app --device "$UDID" "$APP" | grep -E "bundleID|error" || true
    if xcrun devicectl device process launch --device "$UDID" com.zhoujingxuan.qingting >/dev/null 2>&1; then
        echo "  ✅ Installed and launched QingTing (if it was listening it was stopped; tap Start again)"
    else
        echo "  ✅ Installed. If it will not open: unlock the phone; on first install trust the developer under Settings > General > VPN & Device Management"
    fi
done
