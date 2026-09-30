# Receipt Divider for iOS

This native iPhone reference client is written in SwiftUI and targets iOS 17 or later.

For automatic builds and wireless iPhone installation after pushes to `main`, see [Wireless deployment](WIRELESS_DEPLOYMENT.md).

Use `TabView`, `NavigationStack`, toolbars, sheets, and standard buttons. Do not recreate Liquid Glass with custom materials or blur layers: current iOS automatically gives standard components its system treatment.

On a Mac, install [XcodeGen](https://github.com/yonaskolb/XcodeGen), copy `Signing.local.xcconfig.example` to `Signing.local.xcconfig` and set your Apple Developer team ID (the copy is gitignored), run `xcodegen generate` in this folder, and open `ReceiptDivider.xcodeproj` in the newest Xcode. Xcode resolves the Supabase Swift package within the 2.x release line. Test on a current iPhone to validate authentication, Sign in with Apple, and the system Liquid Glass behavior.

The app opens through a custom SwiftUI authentication gate. Email and password is the primary sign-in/create-account method, with iOS Password AutoFill, emailed password reset, and native Sign in with Apple. New accounts also collect real first name, real last name, and a unique username. Supabase restores and refreshes a saved device session automatically; Settings provides sign out. Once authenticated, the app provisions the account profile, loads the canonical ledger from the deployed Edge Function, and posts expenses, optional receipt evidence, repayments, and friend requests with the current access token. An account-scoped device cache supports display continuity, but Supabase is canonical. Camera/photo intake and Vision receipt extraction remain on-device.

## Supabase setup

1. Create a Supabase project and enable Email and Apple under Authentication providers.
2. Turn off Authentication → Sign In / Providers → Email → Confirm email so account creation immediately returns a session, and add `receiptdivider://reset-password` under Authentication → URL Configuration → Redirect URLs.
3. The current project URL, publishable client key, and Supabase Edge Function base URL are configured in `project.yml`. Never place a database URL or Supabase secret/service-role key in the app; update only the client-safe values there if the project changes.
4. In the Apple Developer portal, enable Sign in with Apple for `com.receiptdivider.app`. Configure that bundle identifier as an accepted Apple client ID in Supabase.
5. Regenerate the Xcode project after changing `project.yml`.
6. Deploy `supabase/functions/ledger-api`; the app will send its restored Supabase access token to that function for every protected ledger request.

## Live ledger integration

- `LedgerAPIClient.swift` owns authenticated HTTP requests to the Edge Function configured by `API_BASE_URL`.
- Authenticated launch upserts the profile and replaces the displayed ledger with the server snapshot. Summary reloads it whenever it appears and on pull to refresh, so expenses friends add that include you show up.
- Everyone in the ledger is an app account identified by user ID (`LedgerPerson`). The split flow offers you plus your accepted friends; Summary shows your overall balance and your balance with each person.
- Saving an expense inserts it into local history and balances immediately, identified by its client request ID, while its optional JPEG evidence and idempotent expense command upload. A later snapshot replaces that pending row with the canonical database expense without duplication. Recording a payment remains server-first.
- New account entry collects real first name, real last name, a unique username, and private authentication email. Profile editing groups the three identity fields and provides a draggable, pinch-to-zoom circular crop before a new profile photo uploads. Profile presents a system Liquid Glass Friends control on current iOS, with a bordered fallback on older supported releases.
- Friends supports searching by name or username, invitations, incoming acceptance, pending requests, accepted lists with profile photos, and press-and-hold to remove a friend. The open screen refreshes every 5 seconds.
- Settings keeps device preferences for participant self-reference and the Assign Items control style. Assign Items can use a wide press-and-hold popover or a person-first, single-line scrolling selector with All plus one compact dark pill per participant above the item rows.

Editing or voiding transactions, saved-group filters in the UI, and account deletion remain to be implemented.
