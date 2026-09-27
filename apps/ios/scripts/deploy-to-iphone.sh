#!/bin/bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Values pasted into GitHub variables can carry stray whitespace or newlines.
trim() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; printf '%s' "${value%"${value##*[![:space:]]}"}"; }
IPHONE_ID="$(trim "${IPHONE_ID:-}")"
: "${IPHONE_ID:?Set IPHONE_ID to the paired iPhone identifier from xcrun devicectl list devices}"
IOS_SIGNING_CONFIG="$(trim "${IOS_SIGNING_CONFIG:-}")"
SIGNING_CONFIG="${IOS_SIGNING_CONFIG:-$IOS_DIR/Signing.local.xcconfig}"
DERIVED_DATA="${IOS_DERIVED_DATA:-$IOS_DIR/build/wireless}"
LAUNCH_APP="$(trim "${LAUNCH_APP:-}")"
LAUNCH_APP="${LAUNCH_APP:-false}"

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

# Check reachability before spending time building. This also gives a useful
# failure when the phone is offline or the pairing needs attention.
xcrun devicectl --timeout 60 device info details --device "$IPHONE_ID"
cd "$IOS_DIR"
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
xcrun devicectl --timeout 120 device install app --device "$IPHONE_ID" "$APP_PATH"
if [[ "$LAUNCH_APP" == true ]]; then
  xcrun devicectl --timeout 60 device process launch \
    --device "$IPHONE_ID" --terminate-existing com.receiptdivider.app
fi
