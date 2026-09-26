# Receipt Divider for iOS

This native iPhone reference client is written in SwiftUI and targets iOS 17 or later.

Use `TabView`, `NavigationStack`, toolbars, sheets, and standard buttons. Do not recreate Liquid Glass with custom materials or blur layers: current iOS automatically gives standard components its system treatment.

On a Mac, install [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `xcodegen generate` in this folder, and open `ReceiptDivider.xcodeproj` in the newest Xcode. Xcode resolves the Supabase Swift package within the 2.x release line. Test on a current iPhone to validate authentication, Sign in with Apple, and the system Liquid Glass behavior.

The app opens through a custom SwiftUI authentication gate. Email one-time codes are the primary sign-in/create-account method, with native Sign in with Apple below. Supabase restores and refreshes a saved device session automatically; Settings provides sign out. Once authenticated, the app provisions the account profile and prototype people, loads the canonical ledger from the deployed Edge Function, and posts expenses, optional receipt evidence, and repayments with the current access token. An account-scoped device cache supports display continuity, but Supabase is canonical. Camera/photo intake and Vision receipt extraction remain on-device, and receipt reading remains a draft generator that users must review.

## Supabase setup

1. Create a Supabase project and enable Email and Apple under Authentication providers.
2. In the email magic-link template, show `{{ .Token }}` instead of relying only on `{{ .ConfirmationURL }}` so the custom screen receives a six-digit code.
3. The current project URL, publishable client key, and Supabase Edge Function base URL are configured in `project.yml`. Never place a database URL or Supabase secret/service-role key in the app; update only the client-safe values there if the project changes.
4. In the Apple Developer portal, enable Sign in with Apple for `com.receiptdivider.app`. Configure that bundle identifier as an accepted Apple client ID in Supabase.
5. Regenerate the Xcode project after changing `project.yml`.
6. Deploy `supabase/functions/ledger-api`; the app will send its restored Supabase access token to that function for every protected ledger request.

## Live ledger integration

- `LedgerAPIClient.swift` owns authenticated HTTP requests to the Edge Function configured by `API_BASE_URL`.
- Authenticated launch upserts the profile, creates any missing prototype people (`Alex`, `Jamie`, `Morgan`, and `Taylor`), and replaces the displayed ledger with the server snapshot.
- Pull to refresh in Summary reloads the server snapshot.
- Saving an expense uploads its optional JPEG evidence first and then posts one idempotent expense command. Recording a payment follows the same server-first pattern.
- The fixed `Person` enum is a temporary UI bridge. Replace it with server-driven people before shipping people management or arbitrary contacts.

The central API exists but is not yet connected to the iPhone ledger screens. Group invitations, profile onboarding, API synchronization, account linking, and account deletion remain to be implemented.
