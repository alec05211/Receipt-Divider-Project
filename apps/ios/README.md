# Receipt Divider for iOS

This native iPhone reference client is written in SwiftUI and targets iOS 17 or later.

Use `TabView`, `NavigationStack`, toolbars, sheets, and standard buttons. Do not recreate Liquid Glass with custom materials or blur layers: current iOS automatically gives standard components its system treatment.

On a Mac, install [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `xcodegen generate` in this folder, and open `ReceiptDivider.xcodeproj` in the newest Xcode. Test on a current iPhone to validate the system Liquid Glass behavior.

The current local foundation supports camera or photo-library receipt intake, on-device Vision text extraction, editable items, equal/custom splits, transaction-date history, repayments, and device-local persistence. Receipt reading is a draft generator: users must review all extracted rows and amounts.

The central ledger, authentication, group invitations, shared receipt storage, and server-side validation will follow.
