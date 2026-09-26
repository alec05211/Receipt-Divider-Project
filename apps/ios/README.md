# Receipt Divider for iOS

This native iPhone reference client is written in SwiftUI and targets iOS 17 or later.

Use `TabView`, `NavigationStack`, toolbars, sheets, and standard buttons. Do not recreate Liquid Glass with custom materials or blur layers: current iOS automatically gives standard components its system treatment.

On a Mac, install [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `xcodegen generate` in this folder, and open `ReceiptDivider.xcodeproj` in the newest Xcode. Xcode resolves the Supabase Swift package within the 2.x release line. Test on a current iPhone to validate authentication, Sign in with Apple, and the system Liquid Glass behavior.

The app now opens through a custom SwiftUI authentication gate. Email one-time codes are the primary sign-in/create-account method, with native Sign in with Apple below. Supabase restores and refreshes a saved device session automatically; Settings provides sign out. Once authenticated, the current local foundation supports camera or photo-library receipt intake, on-device Vision text extraction, editable items, equal/custom splits, transaction-date history, repayments, and device-local persistence. Receipt reading is a draft generator: users must review all extracted rows and amounts.

## Supabase setup

1. Create a Supabase project and enable Email and Apple under Authentication providers.
2. In the email magic-link template, show `{{ .Token }}` instead of relying only on `{{ .ConfirmationURL }}` so the custom screen receives a six-digit code.
3. Replace `YOUR_PROJECT` and `YOUR_PUBLISHABLE_KEY` in `project.yml` with the project URL and publishable client key. Never place a Supabase secret/service-role key in the app.
4. In the Apple Developer portal, enable Sign in with Apple for `com.receiptdivider.app`. Configure that bundle identifier as an accepted Apple client ID in Supabase.
5. Regenerate the Xcode project after changing `project.yml`.
6. Configure the backend with the same `SUPABASE_URL` and an asymmetric Supabase signing key so it can verify access tokens through JWKS.

The central API exists but is not yet connected to the iPhone ledger screens. Group invitations, profile onboarding, API synchronization, account linking, and account deletion remain to be implemented.
