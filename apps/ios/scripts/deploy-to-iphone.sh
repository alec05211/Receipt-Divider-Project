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
RUN_URL=""
[[ -n "${GITHUB_RUN_ID:-}" ]] && RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
notify() {
  [[ -n "$NTFY_TOPIC" ]] || return 0
  curl -fsS -m 15 -H "Title: $1" -H "Tags: $2" ${RUN_URL:+-H "Click: $RUN_URL"} -d "$3" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
}
CHANGE="$(git -C "$IOS_DIR" log -1 --format=%s 2>/dev/null || true)"
# STEP names what was running, so an unexpected failure still says where it stopped; fail() gives a specific reason.
STEP="starting the deploy"
FAILURE=""
fail() { FAILURE="$1"; echo "$1" >&2; exit 1; }
trap 'status=$?; (( status == 0 )) || notify "Receipt Divider install failed" "x" "${CHANGE:+$CHANGE
}${FAILURE:-Stopped while $STEP. See the GitHub Actions log.}"' EXIT

[[ "$LAUNCH_APP" == true || "$LAUNCH_APP" == false ]] || fail 'LAUNCH_APP must be true or false.'
[[ -f "$SIGNING_CONFIG" ]] || fail "Missing signing config: $SIGNING_CONFIG. See apps/ios/WIRELESS_DEPLOYMENT.md."
command -v xcodegen >/dev/null || fail 'XcodeGen is not installed on the runner Mac.'
xcrun --find devicectl >/dev/null 2>&1 || fail 'devicectl is missing. Check the Xcode install on the runner Mac.'

STEP="listing paired iPhones"
DEVICE_LIST="$(mktemp)"
xcrun devicectl list devices --json-output "$DEVICE_LIST" >/dev/null 2>&1 || fail 'Could not list paired iPhones with devicectl.'
# One "identifier<TAB>name" line per iPhone; with "all", only paired ones.
DEVICE_ROWS="$(/usr/bin/python3 -c 'import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") != "iOS": continue
    if sys.argv[2] == "all" and d["connectionProperties"].get("pairingState") != "paired": continue
    print(d["identifier"] + "\t" + d["deviceProperties"].get("name", d["identifier"]))' "$DEVICE_LIST" "$IPHONE_ID")"
rm -f "$DEVICE_LIST"
if [[ "$IPHONE_ID" == all ]]; then
  CANDIDATES=()
  while IFS=$'\t' read -r id _; do [[ -n "$id" ]] && CANDIDATES+=("$id"); done <<< "$DEVICE_ROWS"
else
  IFS=', ' read -r -a CANDIDATES <<< "$IPHONE_ID"
fi
(( ${#CANDIDATES[@]} > 0 )) || fail 'No paired iPhone found. Pair one in Xcode (Window > Devices and Simulators).'
# Parallel to CANDIDATES: display name, whether it's installed, and why the last attempt failed.
NAMES=(); DONE=(); REASONS=()
for device in "${CANDIDATES[@]}"; do
  name="$(awk -F'\t' -v id="$device" '$1 == id { print $2; exit }' <<< "$DEVICE_ROWS")"
  NAMES+=("${name:-$device}"); DONE+=(false); REASONS+=("")
done
echo "Installing on: ${NAMES[*]}"
cd "$IOS_DIR"
# Signing.xcconfig includes Signing.local.xcconfig, which is how a blank setting there (such as dropping the
# entitlements on a Personal Team) takes effect; an empty value passed with -xcconfig doesn't clear it.
if [[ "$SIGNING_CONFIG" -ef "$IOS_DIR/Signing.local.xcconfig" ]]; then :; else cp "$SIGNING_CONFIG" "$IOS_DIR/Signing.local.xcconfig"; fi
STEP="generating the Xcode project"
xcodegen generate
STEP="building the app"
BUILD_LOG="$(mktemp)"
if ! xcodebuild \
  -project ReceiptDivider.xcodeproj \
  -scheme ReceiptDivider \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -xcconfig "$SIGNING_CONFIG" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build 2>&1 | tee "$BUILD_LOG"; then
  error="$(grep -m 1 -E '(^| )error: ' "$BUILD_LOG" | sed -E 's/^.*error: //' | cut -c1-200 || true)"
  rm -f "$BUILD_LOG"
  fail "Build failed${error:+: $error}"
fi
rm -f "$BUILD_LOG"

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Receipt Divider.app"
[[ -d "$APP_PATH" ]] || fail "The build finished but produced no app at $APP_PATH."
STEP="installing on the iPhones"
# Turns devicectl output into a short reason for the notification.
install_error() {
  case "$1" in
    *"unable to locate a device"*) echo "went offline during the install." ;;
    *[Tt]imed\ out* | *[Tt]imeout*) echo "timed out during the install." ;;
    *[Ll]ocked*) echo "locked. Unlock it and keep it awake." ;;
    *[Dd]eveloper\ [Mm]ode*) echo "needs Developer Mode turned on." ;;
    *) local line; line="$(grep -m 1 'ERROR:' <<< "$1" | sed -E 's/^.*ERROR: *//; s/ \(com\.apple[^)]*\)//' | cut -c1-160 || true)"
       echo "install failed${line:+: $line}" ;;
  esac
}
# Phones that are asleep or off the network are retried until the deadline, so the latest push still lands once
# they come back. A newer push to main takes over instead, since its run installs a newer app on every phone.
RETRY_MINUTES="$(trim "${RETRY_MINUTES:-}")"
RETRY_MINUTES="${RETRY_MINUTES:-20}"
RETRY_DEADLINE=$(( SECONDS + RETRY_MINUTES * 60 ))
main_moved_on() {
  [[ "${GITHUB_ACTIONS:-}" == true && -n "${GITHUB_SHA:-}" ]] || return 1
  local latest
  latest="$(git -C "$IOS_DIR" ls-remote origin refs/heads/main 2>/dev/null | cut -f1)"
  [[ -n "$latest" && "$latest" != "$GITHUB_SHA" ]]
}
installed=0
while :; do
  for i in "${!CANDIDATES[@]}"; do
    [[ "${DONE[$i]}" == true ]] && continue
    device="${CANDIDATES[$i]}"
    if ! xcrun devicectl --timeout 60 device info details --device "$device" >/dev/null 2>&1; then
      REASONS[$i]="not reachable. Unlock it and check it's on the same Wi-Fi as the Mac."
      echo "${NAMES[$i]}: ${REASONS[$i]}"; continue
    fi
    if ! output="$(xcrun devicectl --timeout 120 device install app --device "$device" "$APP_PATH" 2>&1)"; then
      echo "$output"
      REASONS[$i]="$(install_error "$output")"
      echo "${NAMES[$i]}: ${REASONS[$i]}"; continue
    fi
    echo "$output"
    DONE[$i]=true; installed=$(( installed + 1 ))
    echo "Installed on ${NAMES[$i]}."
    if [[ "$LAUNCH_APP" == true ]]; then
      xcrun devicectl --timeout 60 device process launch --device "$device" --terminate-existing com.receiptdivider.app || true
    fi
  done
  (( installed < ${#CANDIDATES[@]} && SECONDS < RETRY_DEADLINE )) || break
  if main_moved_on; then
    echo "::notice::Stopped retrying: a newer commit on main will be installed instead."
    exit 0
  fi
  echo "Retrying $(( ${#CANDIDATES[@]} - installed )) iPhone(s) in 60 seconds."
  sleep 60
done
SUMMARY=""
for i in "${!CANDIDATES[@]}"; do
  [[ "${DONE[$i]}" == true ]] && continue
  echo "::warning::Not installed on ${NAMES[$i]} after $RETRY_MINUTES minutes: ${REASONS[$i]}"
  SUMMARY+="${SUMMARY:+
}${NAMES[$i]}: ${REASONS[$i]}"
done
(( installed > 0 )) || fail "Not installed on any iPhone after $RETRY_MINUTES minutes.
$SUMMARY"
if (( installed == ${#CANDIDATES[@]} )); then
  notify "Receipt Divider update installed" "iphone" "${CHANGE:+$CHANGE
}Installed on all ${#CANDIDATES[@]} iPhones."
else
  notify "Receipt Divider installed on $installed of ${#CANDIDATES[@]} iPhones" "warning" "${CHANGE:+$CHANGE
}$SUMMARY"
fi
