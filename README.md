# Receipt Divider

Receipt Divider is a mobile-first general expense-sharing app. Receipt capture is its primary fast-entry path, but a transaction can also come from a restaurant check, ticket-confirmation image, other evidence, or fully manual entry. Images are optional evidence; reviewed costs, dates, participants, and allocations are the financial record.

## Current direction

The native iPhone app is the product reference client. It uses SwiftUI system components so current iOS can provide its native navigation, Liquid Glass treatment, and haptic feedback. A custom Supabase authentication gate makes email and password the primary sign-in/create-account flow, provides native Sign in with Apple, and restores prior device sessions. The existing web prototype remains a workflow reference only.

The main navigation is:

- **Summary:** your overall balance, a one-line adaptive summary of who owes you or whom you owe, and a chronological expense list with participant photos. The whole balance card opens every per-person balance, and each row opens Settle Up for that person.
- **Add expense:** camera-first receipt flow.
- **Settings:** your profile and account, Friends, Payments, and app settings.

Saved groups are personal named collections of people used only as transaction filters. Each transaction has its own participant list and never enters a group pool. A “Roommates” filter, for example, shows transactions involving any person in that saved collection; creating it sends no invitations and changes no balances or access rights.

Everyone in a transaction is an app user: you split expenses with yourself and your friends, and each expense appears for everyone on it and counts toward both sides' balances. Friends are separate from saved groups. Accounts use a real first and last name for display and a unique username; email remains private. Profile editing keeps those three identity fields together and lets a selected profile photo be repositioned and zoomed in a circular crop before upload. Settings opens a Friends list where you can search by name or username, accept requests, and press and hold a friend to remove them. Removing a friend keeps your shared history.

## Main receipt flow

1. Tap **Add expense** and capture a receipt with the camera.
2. The app reads likely item names and prices on-device and suggests a short name, category, and split layout.
3. Review the total, purchase date, **Split Total** or **Assign Items** recommendation, and payer on one fixed page. Search sits above the largest-possible friends region, which scrolls internally when needed, and the receipt warning remains at the bottom. The top-right action is **Split**.
4. A single recognized charge goes directly to final review; multiple recognized rows open Assign Items. Choose All or one participant from the bottom icon-and-first-name filter row and tap their items; five filters fit before scrolling. Confirming fills untouched rows to the payer before Continue becomes available. Back after confirmation restores the exact unlocked assignments from before the checkmark.
5. Review the suggested category and identifying name together, followed by payer, date, layout, and total. Receipt text and merchant cues suggest Restaurant, Movie, Groceries, or Concert when possible. Open **Edit Contributions** only when the suggested shares need adjustment; percentages are the default input unit and the equivalent dollar amount appears beside them in parentheses.
6. Save from the top-right action to see the expense in Summary immediately while its evidence and canonical database row finish uploading.

Opening an expense shows its name followed by one continuous fit-to-width reading of the amount, payer avatar, payer first name, and purchase date (the payer can press and hold the card to edit the name or date), then the split, the receipt image and its items with the avatars of who had each, followed by recent expenses involving the same people. The Balances screen uses first-name-only relationship sentences and every row opens Settle Up for that person. Settings can label the signed-in participant by full name, “Me,” or “You.”

## Project layout

```text
apps/ios/                 Native SwiftUI iPhone client
apps/ios/ReceiptDivider/  App source code
apps/api/                 Stateless TypeScript ledger API and PostgreSQL schema
supabase/                 Production Edge Function configuration and entry point
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
2. Configure the Supabase project URL and publishable key in `apps/ios/project.yml` as described in `apps/ios/README.md`.
3. Copy `apps/ios/Signing.local.xcconfig.example` to `apps/ios/Signing.local.xcconfig` and set your Apple Developer team ID. This file is gitignored. On a free Personal Team, also uncomment `CODE_SIGN_ENTITLEMENTS =` there, since Sign in with Apple needs a paid membership.
4. Open Terminal in `apps/ios` and run `xcodegen generate`.
5. Open `ReceiptDivider.xcodeproj` in Xcode.
6. Select an iPhone running a current iOS release and run the app.
7. Allow Camera and Photo Library access when prompted.

The native app now restores a Supabase session, provisions its account, downloads canonical transactions and balances from the deployed Edge Function, and posts new expenses, optional receipt evidence, and repayments back to Supabase. It retains an account-scoped device cache for display continuity. Receipt cropping, text recognition, item/total/date extraction, and category/name/layout suggestions remain on-device. Current devices use Vision's structured document recognition, while older releases use an adaptive text-recognition fallback that retries only weak scans. Review opens as soon as deterministic extraction finishes; on Apple Intelligence-capable devices running iOS 26 or later, the system Foundation Model refines merchant and item wording plus category and expense-name suggestions without blocking entry. Model-proposed financial fields are accepted only when grounded in recognized receipt text. Expense creation is optimistic: the client-generated idempotency key identifies the pending history row until a server snapshot replaces it with the canonical expense.

A Supabase-only backend foundation lives in `apps/api` and `supabase/functions/ledger-api`. It implements account-owned ledgers, local people, saved people filters, optional database-backed evidence and avatar images, atomic expense and repayment writes, idempotency, audit versions, authorization boundaries, derived balances, and Supabase access-token verification. Supabase Edge Functions are the selected production runtime; the Node entry point remains a local test harness. The iPhone client is wired to this live API. Multi-account sharing, dynamic people management, and extraction providers remain deliberately undecided.

## Test the backend

```powershell
cd apps/api
npm install
npm test
npm run typecheck
npm run smoke:postgres
```

The PostgreSQL smoke test requires the Git-ignored `apps/api/.env.local`; it creates and then removes an isolated test ledger. See [`apps/api/README.md`](apps/api/README.md) for local startup, PostgreSQL migration, image limits, authentication, and Supabase Edge Function deployment.

## Key documents

- [Product specification](PRODUCT_SPEC.md)
- [iOS implementation notes](apps/ios/README.md)
- [Backend implementation notes](apps/api/README.md)
- [Repository maintenance skill](skills/receipt-divider-maintenance/SKILL.md)
