# Receipt Divider

Receipt Divider is a mobile-first expense-sharing app for splitting a mixed receipt with the specific friends involved in each purchase. It treats the receipt image as evidence, stores individual selected items, and keeps a chronological transaction history based on the purchase date.

## Current direction

The native iPhone app is the product reference client. It uses SwiftUI system components so current iOS can provide its native navigation, Liquid Glass treatment, and haptic feedback. The existing web prototype remains a workflow reference only.

The main navigation is:

- **Transactions:** chronological activity list with participant avatars.
- **Add expense:** camera-first receipt flow.
- **Profile:** personal balance, repayment, and people management.
- **Settings:** the `gearshape` button in Transactions.

Saved groups are not the main navigation model. Each transaction has its own participant list; future saved groups will be optional shortcuts for repeat rosters.

## Main receipt flow

1. Tap **Add expense** and capture a receipt with the camera.
2. The app reads likely item names and prices from the image.
3. Review a multi-select list of receipt rows and confirm the items to share.
4. Tag the friends involved, with recent people first.
5. Confirm an equal split or enter exact contributions.
6. Save and return to Transactions.

Opening a transaction shows the cost breakdown first, then the receipt image and selected items as evidence, followed by recent transactions involving the same people.

## Project layout

```text
apps/ios/                 Native SwiftUI iPhone client
apps/ios/ReceiptDivider/  App source code
dist/                     Original web workflow prototype
PRODUCT_SPEC.md           Living product requirements and decisions
skills/                   Repository-local Codex guidance
```

## Start the web prototype on Windows

The web prototype is useful for reviewing the workflow, but it does not test native iOS Liquid Glass, haptics, or camera behavior.

```powershell
cd C:\Users\avuil\Desktop\Receipt-Divider-Project
python -m http.server 4173 --bind 127.0.0.1 --directory dist
```

Open `http://127.0.0.1:4173` in a browser.

## Build the native iPhone app on a Mac

1. Install the newest Xcode and XcodeGen.
2. Open Terminal in `apps/ios`.
3. Run `xcodegen generate`.
4. Open `ReceiptDivider.xcodeproj` in Xcode.
5. Select an iPhone running a current iOS release and run the app.
6. Allow Camera and Photo Library access when prompted.

The initial native app is local-device only. It already covers capture, on-device text recognition, editable receipt items, exact-cent splits, local persistence, payment recording, and transaction detail evidence. The shared backend, accounts, invitations, cloud receipt storage, and server-side validation are the next major implementation phase.

## Key documents

- [Product specification](PRODUCT_SPEC.md)
- [iOS implementation notes](apps/ios/README.md)
- [Repository maintenance skill](skills/receipt-divider-maintenance/SKILL.md)

