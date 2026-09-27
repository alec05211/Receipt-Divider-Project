# Automatic wireless iPhone deployment

The workflow `.github/workflows/deploy-ios.yml` runs after every push to `main`
or a manual run on `main`. It builds the Debug app on your Mac and installs it
on the configured paired iPhone. Launching is optional and disabled by default.
No certificate or private signing key is uploaded to GitHub.

## Prepare the Mac and phone

1. Install Xcode and XcodeGen (`brew install xcodegen`), open Xcode, accept its
   license/install components, and sign in to your Apple account. Select Xcode
   as the active developer directory.
2. Pair your phone with Xcode, enable Developer Mode, and verify Xcode can run
   this app with the cable disconnected. Keep the phone reachable over Wi-Fi.
3. Store the signing configuration **outside the runner checkout**, for example
   at `/Users/ben/.config/receipt-divider/Signing.xcconfig`. Start from
   `Signing.local.xcconfig.example`, set your team ID, and retain
   `CODE_SIGN_ENTITLEMENTS =` if using a free Personal Team. Paid teams can keep
   the project's Sign in with Apple entitlement after configuring that capability.
4. Run the local script once before enabling automation:

   ```sh
   export IPHONE_ID='identifier-from-devicectl'
   export IOS_SIGNING_CONFIG='/absolute/path/to/Signing.xcconfig'
   bash apps/ios/scripts/deploy-to-iphone.sh
   ```

   Get the identifier with `xcrun devicectl list devices`. To also launch the app,
   set `LAUNCH_APP=true`. The phone may need to be unlocked for installation or
   launch. A successful install followed by a failed launch still leaves the new
   app installed. Personal Team provisioning expires and may require refreshing.

## Register the GitHub runner

A repository admin must open **Settings → Actions → Runners → New self-hosted
runner**, choose macOS and the Mac's architecture, and follow the generated
download and registration commands. Install it outside this source checkout.
Add the custom label `receipt-divider-ios` during registration (`--labels
receipt-divider-ios`). Use the same macOS user that owns the Xcode account and
signing identity. Start with `./run.sh` to validate the setup; then `./svc.sh
install` and `./svc.sh start` can run it as a login service.

Under **Settings → Secrets and variables → Actions → Variables**, set:

| Variable | Value |
| --- | --- |
| `IPHONE_ID` | Paired device identifier from `devicectl list devices` |
| `IOS_SIGNING_CONFIG` | Absolute path to the signing config on the Mac |
| `IOS_LAUNCH_APP` | Optional `true`; defaults to `false` |

The checkout does not include your ignored `Signing.local.xcconfig`, so the
external config path is required for Actions. Keep the Mac awake, logged in,
connected to the internet, and its signing Keychain available. `caffeinate`
prevents idle sleep during a job; it cannot wake a sleeping Mac to receive one.

## Public repository considerations

This repository is public. The workflow deliberately has no pull-request
trigger, checks out without persisting credentials, and runs only on `main`.
Still, anyone who can modify `main` can execute code as your Mac user. Protect
`main`, review workflow/script changes, and use a dedicated development Mac or
account if that access is unsuitable for your personal Mac. Never add a
pull-request trigger to this runner for untrusted contributions.

## Verify and troubleshoot

Push the workflow to `main`, then check **Actions → Deploy iOS to iPhone**.
Verify installation on the actual phone with its cable disconnected. An offline
phone fails the job; reconnect it and rerun the workflow. Jobs queue while the
Mac is offline. Deployments run serially to avoid overlapping installs.

- Missing runner: check its label, online status, and service login session.
- Signing failure: run the script in Terminal as the runner user; resolve the
  Xcode account/profile or Keychain access prompt there first.
- Missing device: unlock the phone, check Developer Mode, network and pairing
  in Xcode, then rerun `xcrun devicectl list devices`.

References: [GitHub runner setup](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners),
[GitHub runner security](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners),
[Apple command-line tools](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference).
