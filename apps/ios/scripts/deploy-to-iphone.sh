#!/bin/bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Values pasted into GitHub variables can carry stray whitespace or newlines.
trim() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; printf '%s' "${value%"${value##*[![:space:]]}"}"; }
# Comma-separated device identifiers from `xcrun devicectl list devices`, or "all" (the default) for every paired iPhone.
IPHONE_ID="$(trim "${IPHONE_ID:-}")"
IPHONE_ID="${IPHONE_ID:-all}"
IOS_SIGNING_CONFIG="$(trim "${IOS_SIGNING_CONFIG:-}")"
SIGNING_CONFIG="${IOS_SIGNING_CONFIG:-$IOS_DIR/Signing.local.xcconfig}"
DERIVED_DATA="${IOS_DERIVED_DATA:-$IOS_DIR/build/wireless}"
LAUNCH_APP="$(trim "${LAUNCH_APP:-}")"
LAUNCH_APP="${LAUNCH_APP:-false}"
# Optional push notification through ntfy (https://ntfy.sh): the topic comes from NTFY_TOPIC or a file on the
# runner Mac, kept out of this public repo because anyone who knows a topic can read and post to it.
NTFY_TOPIC="$(trim "${NTFY_TOPIC:-$(cat "$HOME/.config/receipt-divider/ntfy-topic" 2>/dev/null || true)}")"
notify() {
  [[ -n "$NTFY_TOPIC" ]] || return 0
  curl -fsS -m 15 -H "Title: $1" -H "Tags: $2" -d "$3" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
}
CHANGE="$(git -C "$IOS_DIR" log -1 --format=%s 2>/dev/null || true)"
trap 'status=$?; (( status == 0 )) || notify "Receipt Divider install failed" "x" "${CHANGE:-Build or install failed}"' EXIT

if [[ "$LAUNCH_APP" != true && "$LAUNCH_APP" != false ]]; then
  echo 'LAUNCH_APP must be true or false.' >&2
  exit 1
fi
if [[ ! -f "$SIGNING_CONFIG" ]]; then
  echo "Missing signing config: $SIGNING_CONFIG. See apps/ios/WIRELESS_DEPLOYMENT.md." >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen on the runner Mac.' >&2; exit 1; }
xcrun --find devicectl >/dev/null

if [[ "$IPHONE_ID" == all ]]; then
  DEVICE_LIST="$(mktemp)"
  xcrun devicectl list devices --json-output "$DEVICE_LIST" >/dev/null
  CANDIDATES=($(/usr/bin/python3 -c 'import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") == "iOS" and d["connectionProperties"].get("pairingState") == "paired": print(d["identifier"])' "$DEVICE_LIST"))
  rm -f "$DEVICE_LIST"
else
  IFS=', ' read -r -a CANDIDATES <<< "$IPHONE_ID"
fi
# Check reachability before spending time building. An offline phone is skipped rather than failing the others.
DEVICES=()
for device in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  if xcrun devicectl --timeout 60 device info details --device "$device" >/dev/null 2>&1; then DEVICES+=("$device")
  else echo "::warning::Skipping unreachable device $device. Unlock it and check it's on the same network."; fi
done
(( ${#DEVICES[@]} > 0 )) || { echo 'No paired iPhone is reachable. Unlock one and check its network and pairing in Xcode.' >&2; exit 1; }
echo "Installing on: ${DEVICES[*]}"
cd "$IOS_DIR"
# Signing.xcconfig includes Signing.local.xcconfig, which is how a blank setting there (such as dropping the
# entitlements on a Personal Team) takes effect; an empty value passed with -xcconfig doesn't clear it.
if [[ "$SIGNING_CONFIG" -ef "$IOS_DIR/Signing.local.xcconfig" ]]; then :; else cp "$SIGNING_CONFIG" "$IOS_DIR/Signing.local.xcconfig"; fi
xcodegen generate
xcodebuild \
  -project ReceiptDivider.xcodeproj \
  -scheme ReceiptDivider \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -xcconfig "$SIGNING_CONFIG" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Receipt Divider.app"
[[ -d "$APP_PATH" ]] || { echo "Build did not produce $APP_PATH" >&2; exit 1; }
INSTALLED=()
for device in "${DEVICES[@]}"; do
  if ! xcrun devicectl --timeout 120 device install app --device "$device" "$APP_PATH"; then
    echo "::warning::Install failed on $device; it may have gone to sleep or left the network."; continue
  fi
  INSTALLED+=("$device")
  if [[ "$LAUNCH_APP" == true ]]; then
    xcrun devicectl --timeout 60 device process launch --device "$device" --terminate-existing com.receiptdivider.app || true
  fi
done
(( ${#INSTALLED[@]} > 0 )) || { echo 'Install failed on every reachable iPhone.' >&2; exit 1; }
notify "Receipt Divider update installed" "iphone" "${CHANGE:+$CHANGE — }installed on ${#INSTALLED[@]} of ${#CANDIDATES[@]} iPhones"
