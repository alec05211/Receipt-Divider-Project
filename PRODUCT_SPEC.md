# Receipt Divider — Living Product Specification

Status: Draft for refinement; local interaction prototype started  
Last updated: 2026-09-26
Working name: Receipt Divider

## 1. Purpose and how to use this document

This document is the source of truth for the product vision and future implementation. Update the relevant sections as decisions change. Keep unresolved questions in section 12 rather than silently turning assumptions into requirements.

Requirement labels distinguish intent from recommendations:

- **Confirmed:** Explicitly requested by the product owner.
- **Proposed:** Recommended starting behavior; subject to refinement.
- **Deferred:** Outside the proposed first release.
- **Open:** A decision remains unresolved.

Requirement IDs are stable so implementation work and acceptance checks can reference them. When implementation is requested, use this document to define scope, resolve consequential open decisions, and track delivered behavior. This document does not authorize deployment, purchases, or external integrations by itself.

## 2. Product vision

**Confirmed:** Make it easy to record and share general expenses, with receipt capture as the primary fast-entry flow. The app can extract items, costs, and dates from receipts, restaurant checks, ticket confirmations, or similar images, but also supports expenses with no image or itemization. It maintains accurate running totals from reviewed transaction data.

The immediate audience is the product owner and their roommate. The longer-term ambition is a product usable by many independent groups. The intended audience includes both iOS and Android users.

The core experience should answer:

- Which purchases are being shared?
- Who entered and paid for each purchase?
- How much is each person responsible for?
- What does each person currently owe or need to receive?
- What original receipt supports the entry?

### Success criteria

**Proposed:** The first release succeeds when both roommates can independently record real purchases from their phones, verify the receipt details, choose custom contributions, and agree that the resulting balances match their expectations.

Measure scanning corrections, time required to save an expense, failed uploads, and balance discrepancies during household use. Numerical targets should follow real usage rather than be invented now.

## 3. Scope and platform direction

### First release

| ID | Status | Capability |
| --- | --- | --- |
| S-01 | Confirmed | Photograph or upload receipts from a phone. |
| S-02 | Confirmed | Extract individual items and costs into a multi-select interface. |
| S-03 | Confirmed | Combine selected items into an expense total, or accept an explicit total for manual entry. |
| S-04 | Confirmed | Use a subsequent screen to assign individual participant contributions. |
| S-05 | Confirmed | Sum individual responsibilities across ledger entries. |
| S-06 | Confirmed | Maintain an expense log with descriptions, optional items/evidence, attribution, and contribution breakdowns. |
| S-07 | Confirmed | Support users with iOS and Android phones. |
| S-08 | Confirmed | Use a native SwiftUI iPhone app as the reference client, including Apple system navigation, Liquid Glass behavior, and meaningful haptic feedback. |
| S-09 | Confirmed | Every participant is an app account. Expenses are split between the creator and their accepted friends; there are no local or placeholder people. Personal named collections of people are used only as filters; creating one does not invite anyone or create a separate ledger pool. |
| S-10 | Proposed | Track who paid, net balances, and manually recorded repayments. |
| S-11 | Confirmed | Permit manual expense entry with no image or item rows. |
| S-12 | Proposed | Use one payer per expense and one currency per account initially. |
| S-13 | Confirmed | Gate the native app behind a custom SwiftUI Supabase Auth experience, using email and password as the primary sign-in/create-account flow, emailed password reset, and native Sign in with Apple as the secondary option. |
| S-14 | Confirmed | Restore a previously authenticated session on the device and open the main app without requiring sign-in again while the session remains valid and refreshable. |

### Deferred scope

- App Store and Google Play distribution, pending validation of the web experience.
- Bank connections, money transfers, and automatic collection of payments.
- Currency conversion and expenses involving multiple currencies within one group.
- Multiple payers for a single expense.
- Automatic recurring charges, subscriptions, and monetization.
- Complex approval workflows that require every participant to approve an expense before it affects balances.

**Confirmed:** The iPhone app is the reference experience. It uses standard SwiftUI navigation, tabs, toolbars, sheets, and controls so the current iOS system supplies Liquid Glass behavior. Avoid custom recreation of Liquid Glass effects. Use haptics only for meaningful selection and successful completion feedback.

Android remains a required future client. Keep the backend, money rules, API contracts, and data model independent of SwiftUI so an Android implementation can use the same shared ledger without duplicating financial logic.

## 4. Primary user journey

### Navigation model

**Confirmed:** The main view is Summary, aligned toward the top with a compact inline navigation title. Its first element is a full-card balance button with the existing large, signed-color total and a smaller, secondary-colored, full-width, single-line statement such as “Owed by Alec, Willem · Owed to Luke.” Names are comma-separated; when the full statement does not fit, progressively replace hidden names with `+N`. The card has no chevron and does not expand in place. It gives light haptic feedback and opens a Balances view containing every nonzero per-person balance. Each balance row is an explicit button that opens Settle Up with that person selected and uses one first-name-only sentence such as “Alec owes Luke $20.00.” Chronological Expenses follow the card. Each expense visibly shows the people included in it through their avatars and gives subtle selection haptic feedback when opened. Participant selection offers you and your accepted friends, with recently used people first.

**Confirmed terminology:** The interface calls a shared purchase an “expense” and a settle-up a “payment” (stored as a repayment). It does not say “transaction”; “transaction date” remains the data term for when a purchase or payment happened.

**Confirmed native navigation:** The bottom tab bar contains Summary (`clock`), Add expense (`plus.circle.fill`), and Settings (`gearshape`). Settings opens with your profile (tap to edit), your signed-in email, and Sign out, then Friends (search and add friends) and Payments, then the app settings. A device preference controls whether the signed-in participant is labeled by full name, “Me,” or “You,” defaulting to full name. Use SF Symbols and system components rather than custom navigation icon artwork.

**Confirmed authentication entry:** When no valid session exists, show a custom-designed native authentication screen before the tab bar. Default to email/password sign-in, provide a visible Create account mode that also collects real first name, real last name, and unique username, offer emailed password reset, and place the native Sign in with Apple button below the email action. A stored valid session bypasses this screen. Authentication provider screens must not dictate the surrounding visual design, while the Apple button and authorization sheet follow Apple’s required native treatment.

**Confirmed profile editing:** Keep first name, last name, and username in one form section. After choosing a profile image, present a circular crop preview that can be repositioned by dragging and enlarged by pinching before the 512-pixel avatar is uploaded.

Do not make saved groups the primary navigation model. An expense can include any subset of people from the roster without entering a group pool. A saved group is a local, personal name for a collection of people, created in Settings without invitations. It appears as a filter on Summary and uses any-person matching: “Roommates” shows expenses and payments involving at least one saved roommate. It changes only the view, never balances, ownership, or access control.

### Core add-expense flow

**Confirmed:** The central Add action in the native iOS tab bar begins a receipt capture flow:

1. Open the camera. The user may instead choose an existing receipt image or manually enter items.
2. Show a short loading state while the receipt's text is recognized. Cloud vision, started when the photo is taken, then reads the merchant, purchase date, items, subtotal, adjustments, and total in the background while participants are chosen (see **Receipt reading and adjustments** below). Confirming participants before the reading finishes shows the loading state until it does. When cloud vision is unavailable, the on-device Apple Intelligence model reads the receipt, and without it the rule-based parser and keyword suggestions do.
3. Immediately open the **Select participants** screen. This first screen is entirely dedicated to participant selection: the summary descriptor and bottom mismatch warning are removed so the unified friends component expands vertically to reach the top and bottom of the page. The component combines a slightly shorter iOS rounded search bar at the top with an internally scrollable friends list ordered by recent friends. The page itself never scrolls. The centered title is **Select participants** and the top-right confirmation action is a checkmark icon.
4. There is no split layout to choose. A receipt with at most one item gives that item to everyone selected and skips assignment; several items open Assign Items. The assignment screen keeps the current fixed-height rows and centered-or-scrolling bottom participant filters. When no current row has an owner, the top-right action is **Split All**. It gives every row to every selected participant, uses the printed receipt total when available, and changes in place to a checkmark. Manually assigning any row also changes the action to the checkmark. Confirmation continues immediately when every row has an owner; otherwise it visibly gives untouched rows to the current payer, locks the arrangement, and changes to **Continue**. Back restores the exact assignment map from before confirmation. Changing the payer on final review moves only rows that confirmation auto-assigned. A row added after Split All belongs to everyone, while manually changing an assignment returns contributions to item-based amounts.
5. Present final review as a unified component with the categorizer and name field positioned close to the top, followed by Expense total, Paid by, and Date of expense, then one compact row per receipt adjustment in receipt order: Discount, Tax, and Surcharge edited as percents with their amounts beside them, and Tip edited in dollars. Editing one recalculates the rows, total, and starting contributions. The total is directly editable for a single-item expense; multiple-item totals come from the item rows except when Split All uses a recognized printed total. A distinct Assign items section for multiple-item expenses sits between the main controls and contribution sliders. The Contributions header remains omitted so sliders share the same tight spacing. Percent is the account default. Each contribution shows the editable primary unit followed inline by the secondary unit in parentheses, such as `50% ($20.00)` or `$20.00 (50%)`. Starting contributions come from item ownership, with leftover cents settled once across the expense. The slider snaps most strongly to that ownership-derived share, lightly to every whole unit of the chosen unit, and faintly to whole units of the other. Saving requires contributions to equal the expense total. Tapping the description card on an existing expense routes to the same component populated with its fields.
6. The top-right **Save** action gives immediate checkmark feedback with a strong haptic and returns to Summary, where the expense and its balance effect appear optimistically while evidence and the canonical database record finish uploading. The pending row uses the expense's client request ID and is replaced, not duplicated, when a server snapshot contains that request. If creation fails, remove the optimistic effect and present the error. Final review has no additional-save action.

The receipt’s purchase date, rather than time of entry, determines its position in Summary.

#### One item model, no split layouts

**Confirmed:** Every expense is one or more items, each owned by one or more people, while allocations remain the canonical amounts used for balances. There is no split-layout selector. A single item is owned by everyone selected and skips assignment; several items open Assign Items. Category remains an independent suggestion and never changes this navigation.

Ownership is a yes/no relationship rather than an amount. Starting contributions divide each item among its owners and settle leftover cents once across the whole expense. The member may still adjust the resulting contributions before saving. An item with no manually chosen owner belongs to the payer.

### Expense detail and evidence

**Confirmed:** Opening an expense begins with a minimal card: the expense title, then one continuous reading of the amount followed by “paid by,” the payer's profile image, the payer's first name, “on,” and the transaction date. “Paid by” and “on” share the same secondary font treatment; names, dates, and amounts remain primary bill details. The complete line scales down together to fit and never inserts flexible gaps or wraps. Do not prefix the amount with “Total.” The exact assigned share for every tagged person follows, using the chosen self-reference label. Scrolling then reveals the original receipt photo and selected line items as the paper trail. The final section shows recent expenses involving one or more of the same tagged people, with their avatars visible.

### A. Open Summary

**Confirmed:** The primary default view is a chronological account-ledger history organized by when purchases occurred, rather than when entries were added. **Proposed:** Show newest purchase dates first and entries under date headings. Spending, each person’s assigned costs, and proposed net balances remain accessible. Saved people groups appear only as optional filters.

### B. Capture the receipt

The member takes a photo or chooses an existing image. The app shows upload and analysis progress, with recoverable error states.

### C. Review and assign items

The app keeps participant selection on its dedicated first screen. Extracted rows remain editable in Assign Items until the arrangement is confirmed. Each row shows an item description, line total, and owner avatars; the assigned total changes immediately as rows are assigned or corrected. Confirming assigns any untouched row to the payer before continuing.

The original receipt is accessible during review. Rows that do not contribute to the expense are deleted before confirmation; any remaining unassigned row is assigned to the payer. Receipt-level adjustments are shown separately on final review. Each row on Assign Items shows its local total: the printed price plus the item's own discount or tax, without its share of receipt-wide tax, surcharges, or discounts. The tip is not a row on Assign Items; it is edited on final review.

**Confirmed:** Explicitly target the receipt’s purchase date during extraction and use it as the expense’s transaction date. **Proposed:** Display this date prominently for review and correction before saving. If the receipt date is missing, unreadable, or ambiguous, require the member to choose or confirm the transaction date instead of silently using the upload date.

### D. Allocate contributions

The member reviews the category value inline to the left of the suggested short name, followed by total, payer, and date. Initial contributions derive from item ownership. Exact fields and sliders remain in the unified final review component.

The screen displays the expense total, each contribution, and the remaining unallocated amount. Saving is blocked until the allocation matches the expense total.

### E. Save and inspect

The saved entry appears in the group log at its transaction date, even when entered several days later. Opening it shows the original receipt, selected items and adjustments, description, creator, payer, contribution breakdown, transaction date, separate creation timestamp, and any subsequent changes.

### F. Settle up

**Proposed:** A member records an actual repayment. It updates net balances and appears in the history without changing the original expenses. The app records repayments; it does not move money.

## 5. Functional requirements

### Receipt capture and extraction

| ID | Status | Requirement |
| --- | --- | --- |
| R-01 | Confirmed | Accept receipt photos and extract item descriptions and costs. |
| R-02 | Proposed | Treat extraction as an editable draft, never as an automatically posted expense. |
| R-03 | Confirmed | Extract merchant, purchase date, items (price, quantity, item discount, taxed or not), subtotal, discounts, taxes, tip, surcharges, and total when visible; missing information remains missing. |
| R-04 | Confirmed | Show a mismatch when extracted amounts do not reconcile with the receipt subtotal or total, and a warning when no total was found; do not silently invent balancing items. |
| R-10 | Confirmed | Upload diagnostics with each receipt: build, OS and device, every recognized line with its page position, the text the model read, each model attempt's raw output, timing and issues, which reader produced the result and why, and the reading compared with what was saved. Developer accounts see the build and the last scan's reader and time in Settings. |
| R-05 | Proposed | Preserve the original uploaded image independently of corrected extraction data. |
| R-06 | Proposed | Allow retries and manual correction without losing already entered work. |
| R-07 | Confirmed | Specifically extract the receipt’s purchase date and use it as the expense transaction date, independently of when the receipt is uploaded or entered. |
| R-08 | Proposed | Make the extracted transaction date editable and require explicit date selection or confirmation if extraction cannot determine it reliably. |
| R-09 | Confirmed | Treat subtotal, tax, discount, total, and payment evidence as receipt summary data rather than purchasable items. Tolerate common OCR substitutions in these labels, and accept an unlabeled total only when it reconciles with the extracted items and adjustments. |

### Assignment and expense creation

| ID | Status | Requirement |
| --- | --- | --- |
| E-01 | Confirmed | Allow multiple receipt items to be assigned, show a running total, and assign any untouched rows to the payer on confirmation. |
| E-02 | Confirmed | Every expense has one or more items, and each item records its owners as a yes/no many-to-many relationship. Allocations separately record what each person owes. |
| E-03 | Confirmed | Collect a description and optional category on final review, with individual contributions on the separate editor. |
| E-04 | Proposed | Clearly distinguish creator, payer, and members responsible for a share. |
| E-05 | Proposed | Support equal, percentage, and exact-amount allocation, including a zero share. |
| E-06 | Proposed | Save the expense, items, and allocations atomically and prevent duplicate saves caused by retries. |
| E-07 | Proposed | Copy reviewed item values into a saved expense snapshot so later extraction changes cannot silently alter balances. |
| E-08 | Confirmed | Present no split-layout selector. A single item belongs to everyone selected and skips assignment; several items open Assign Items. |
| E-09 | Confirmed | Suggest a category and a short editable identifying expense name from on-device receipt and item analysis when available. Recognize restaurant, movie, grocery, and concert cues and prefer the merchant or a useful item in the name. |
| E-10 | Confirmed | Skip assignment for at most one item and open Assign Items for multiple rows, independently of category. |
| E-11 | Confirmed | Show a saved expense and its balance effect immediately, mark it as uploading, reconcile it by client request ID when the canonical snapshot arrives, and roll it back with an error if creation fails. |
| E-12 | Confirmed | Dedicate the first screen after scan entirely to participant selection under the centered title Select participants, with a top-right checkmark confirmation icon. The unified component combines a compact rounded search field with an internally scrolling friends list and expands vertically to reach the top and bottom of the page, omitting the descriptor card and bottom mismatch warning. |
| E-13 | Confirmed | Default contribution editing to percent at both the account and device fallback levels. Show the editable primary unit and its secondary equivalent inline in parentheses. |

### People filters and history

| ID | Status | Requirement |
| --- | --- | --- |
| G-01 | Confirmed | An expense and its optional evidence are visible to its creator, its payer, and everyone with a share; a repayment is visible to its sender and recipient. Nobody else can see them. |
| G-02 | Confirmed | Show an expense log with description, items, attribution, split, and receipt evidence. |
| G-03 | Confirmed | Show each user their balance with every person they share expenses with, and their overall net balance. |
| G-04 | Proposed | Separately show amounts paid, assigned costs, repayments, and net balances. |
| G-05 | Proposed | Preserve attributable revisions when an expense is edited or voided; recalculate balances from the current effective entries. |
| G-06 | Proposed | Record repayments separately from purchases and allow erroneous repayments to be reversed with history. |
| G-07 | Confirmed | Make chronological expense and payment history the primary default view, ordered by transaction date rather than entry creation time. Backdated purchases appear on the date they occurred. |
| G-09 | Confirmed | Allow named local collections of people to filter Summary by any participant overlap without changing ledger math or access. |
| G-10 | Confirmed | Keep the amount, payer avatar and first name, and date as one continuous metadata reading in saved-expense detail; scale the entire line down together to fit without wrapping or flexible gaps, and give “paid by” and “on” the same secondary treatment. |
| G-11 | Confirmed | Make every individual balance row an explicit Settle Up navigation action and render its relationship as one first-name-only sentence: “Person1 owes Person2 amount.” |
| G-08 | Proposed | Default to newest transaction date first, use date headings, and apply date filters and spending periods to transaction dates. Keep creation timestamps available in entry details for auditing. |

## 6. Financial rules and invariants

These are proposed implementation rules. They should be settled before implementing the financial engine.

### Money representation

- Store money as integer minor units, such as cents for USD, with an explicit currency.
- Use deterministic application logic for calculations. Receipt AI proposes data; it does not determine authoritative arithmetic.
- Use one currency per account ledger in the first release. A receipt in a different currency must be rejected or handled manually under an explicitly decided policy.
- The initial scope is nonnegative purchases and repayments. Refunds and credits need an explicit later policy.

### Receipt reading and adjustments

**Confirmed (2026-10-06):** Reading splits the work between code and a model:

- **Cloud vision first (confirmed 2026-10-07).** The photo is sent to `POST /v1/receipts/parse` (OpenAI `gpt-4o-mini`), which transcribes every printed row and labels each one. Only this step, going from the image to labeled rows, differs from the on-device reading: the rows go through the same row parsing, label rules, totals, checks, re-read, and adjustment math below, and the reading is recorded in the same diagnostics. When cloud vision is unavailable, fails, or finds no items, the device's rows and the on-device model are used.
- **Text.** Document recognition and the accurate OCR pass both run; accurate lines fill in what document recognition drops or merges.
- **Rows and prices (code).** Pieces sharing a printed line, by vertical position on the page, form a row read left to right. A row's price is the amount at its right end; every amount comes from the row's text.
- **Labels (model, cloud or on-device Apple Intelligence on iOS 26).** The model labels each priced row (subtotal, tax, tip, surcharge, order discount, total, cash total, other) and reads taxed items, the merchant, and the date. Priced rows above the subtotal are items whatever their label; a negative row is the discount of the item above it; quantities come only from what is printed ("2 x $3.25", a leading "2", or a "2 @ 3.49" line that multiplies to the item above). An adjustment labeled with the amount of a printed total is treated as that total.
- **Totals.** A tip written in below the printed total (as on a signed card slip) is the tip, and the total after it is final. Two different totals with no tip between them are cash and card prices: the card total is used, with the difference as a final surcharge.
- **Checks.** Every numbered row from the subtotal on must be labeled. If the result doesn't add up, has no total, or has unlabeled rows, the model reads the rows once more with the problem pointed out, and the result with fewer problems is kept; a missing total is shown as a warning. The rule-based parser is the fallback when neither model can read the receipt. Rules are added back only for gaps found on real receipts.

- **Rows.** Each item keeps its printed price. An item printed with a quantity becomes one row per unit, with the price and any item discount split as evenly as the cents allow, so each unit can be assigned separately.
- **Local offset.** What the receipt ties to one item, such as its own discount, is that item's local offset.
- **Global offset.** Receipt-wide discounts, taxes, and surcharges are applied in printed order, each to the running cost of the rows it covers: a discount to items, tax only to taxed items, and a surcharge to every row with a cost by then, including a tip printed before it. Each rate comes from the printed amount and the running cost it applied to, and each amount is shared in proportion with rounding that adds up exactly. An item's share is its global offset. Every price-based step starts from the price plus the local offset.
- **Tip.** The tip is a dollar amount kept with the adjustments, not an item. A surcharge printed after the tip also applies to it, and that part goes with the tip. **Confirmed (2026-10-07):** an account setting, **Split tip**, chooses how starting contributions divide it: **Evenly** (the default) among everyone on the expense, or **By items**, in proportion to each item's total and shared by that item's owners, so someone who had nothing pays no tip. With no owned items, By items splits evenly. Contributions stay editable either way.
- **Display.** Rates are worked out from printed amounts, so one within 0.005 percentage points of a whole number shows as that number (8%, not 8.001%).
- **Partial receipts.** Deleting or editing rows re-applies the same rates to the remaining rows.

`expense total = sum over items of (printed price + local offset + global offset) + tip + surcharge on the tip`, which equals the printed total when every row is kept and the reading is correct. Split All may still use the printed total.

### Allocation

- The sum of member shares must exactly equal the expense total before saving.
- Exact-amount splits show the remaining difference as the member edits.
- Percentage splits must total 100%; convert them to exact monetary shares for storage.
- Equal and percentage splits use a deterministic rounding rule. Proposed rule: distribute leftover cents by largest fractional remainder, breaking ties by stable member order, and show the resulting amounts before saving.
- A payer can have a zero assigned share. A member can have a share without being the payer or creator.

### Ledger balances

For each member:

`net balance = expenses paid − assigned expense shares + repayments sent − repayments received`

- Positive means the member should receive money; negative means they owe money.
- Balances are also shown pairwise: on each expense, every member owes their share to the payer, and a repayment reduces what its sender owes its recipient. A member's net balance is the sum of their pairwise balances.
- Saved people filters do not recalculate a separate group balance.
- Repayments change balances but do not change purchase totals.
- Aggregate balances are derived from saved records, not independently editable totals.

### Worked example

| Entry | Payer | Owner’s share | Roommate’s share |
| --- | --- | ---: | ---: |
| Groceries: $60 | Owner | $20 | $40 |
| Supplies: $30 | Roommate | $15 | $15 |

The owner paid $60 and owes $35 in assigned costs, yielding +$25. The roommate paid $30 and owes $55, yielding −$25. A $25 repayment from the roommate to the owner brings both balances to zero. Purchase spending remains $90.

### Transaction dates and chronology

**Confirmed:** An expense’s transaction date represents the date of the purchase printed on the receipt. The creation timestamp represents when the expense was entered into the app. These are separate fields with separate purposes.

For example, a receipt dated September 18 entered on September 23 belongs under September 18 in the default history. Its details can show “Purchased September 18” and “Added September 23.” Uploading old receipts must not make them appear as new purchases on the upload date.

**Proposed implementation rules:**

- Store the transaction date as a calendar date, without converting it across time zones. Store creation and modification timestamps separately as precise instants.
- Extract the purchase date rather than unrelated printed dates such as return deadlines. Ask for review when multiple dates or regional date formats are ambiguous.
- Manual expenses also require a transaction date. Today may be suggested for manual entry, but the date remains editable.
- Sort the default history by transaction date descending. For entries on the same date, use creation timestamp and a stable record ID as deterministic tie-breakers; this does not imply a known purchase-time ordering.
- Use transaction dates for date filters, period spending totals, and any historical balance views. Use creation timestamps for activity/audit information.
- Correcting a transaction date moves the entry to the appropriate place and reporting period, preserves an audit event, and does not change its monetary amount or current net balance.
- Repayments, if implemented, follow their actual payment date in the transaction history, with recording time retained separately.

## 7. Proposed conceptual data model

This describes the committed initial Supabase PostgreSQL model; sharing and extraction details remain open.

| Entity | Purpose and important fields |
| --- | --- |
| User | Identity, display name, and an optional database-backed profile image. |
| User settings | An account's currency, contribution slider unit (dollars or percent), and tip split (even or proportional), with timestamps. Settings follow the account across devices. |
| Friendship | A request between two Users that becomes an accepted friendship; only friends can be added to each other's expenses. |
| Saved filter | An account's name for a collection of User IDs; it has no ownership, permission, invitation, or balance semantics. |
| Evidence asset | Uploader, private image bytes stored in PostgreSQL, kind, media type, integrity hash, extraction status, and optional extracted data. Evidence is optional and may represent a receipt, restaurant check, ticket confirmation, or other paper trail. |
| Expense | Creator User, payer User, description, optional category (groceries, restaurant, movie, or concert), currency, explicit total, transaction date, zero or more evidence references, effective status, creation timestamp, and modification timestamp. |
| Expense item | Saved description, printed price, local offset (its own discount), global offset (its share of receipt-wide adjustments), kind (item or tip), and whether it is taxed. |
| Expense item ownership | Required mapping from each Expense item to one or more Users. Ownership records who had the item; allocations separately store the exact amounts used for balances. |
| Expense adjustment | Discount, tax, tip, or surcharge in receipt order, with its rate (a fraction of the running cost it applied to; none for a tip) and the amount it came to in the expense. |
| Expense allocation | Expense, User, and exact assigned amount; preserve chosen split mode where useful for editing. |
| Repayment | Sender User, recipient User, amount, transaction date (actual payment date), creation timestamp, recorder, and effective status. |
| Revision/audit event | Actor, time, action, affected record, and sufficient change information to explain balance changes. |

**Confirmed developer reset:** Accounts flagged `is_developer` (set by hand in the database) see a Developer section in Settings that deletes every account's expenses, expense items, allocations, evidence links and images, payments, and revision history. Users, user settings, friendships, saved filters, and Supabase Auth accounts are kept. The action requires typing DELETE, and the server independently checks the flag and the typed confirmation.

## 8. Interface expectations

**Proposed:** Use a clear, touch-friendly interface designed first for phone screens.

- Primary screens: Summary, capture/upload or manual entry, optional evidence review, allocation, expense detail, and payment entry.
- Make the chronological expense and payment list the main view. Show purchase dates prominently and keep “added on” timestamps secondary in entry details.
- Keep receipt item names and monetary amounts readable without horizontal scrolling.
- Make selected states, missing allocation, extraction errors, and save success explicit.
- Preserve draft state when moving between review and allocation.
- Support accessible labels, adequate contrast, keyboard access, and clear validation messages.
- Show upload/scanning/loading states and useful retry actions.
- Explain how a displayed balance was calculated through accessible expense history.

Visual design, naming, and navigation details remain open.

## 9. Architecture and operational requirements

### Proposed architecture

- Native iOS reference client for capture, review, allocation, and expense and payment history; Android remains a future client.
- Supabase Edge Function API for authenticated ledger access, validation, extraction orchestration, and atomic expense writes. Clients do not independently reconcile concurrent snapshots.
- Supabase hosted PostgreSQL for profiles, friendships, saved filters, expenses, allocations, repayments, history, profile images, and optional evidence bytes.
- Keep image access behind authenticated API endpoints and impose conservative size limits. The initial implementation uses 5 MB per profile image and 15 MB per receipt; these are implementation defaults rather than permanent product requirements.
- Replaceable receipt extraction service so provider choices do not define the financial model.

The production API uses the portable TypeScript HTTP handlers inside a Supabase Edge Function, Supabase Auth, and the hosted PostgreSQL database. The Node entry point remains a local verification harness. The extraction provider is not yet selected.

### Trust and reliability

- Enforce account-ledger ownership on the server, including access to original images.
- Keep service credentials on the server.
- Validate file types and upload limits; exact limits are to be selected.
- Require confirmation of reviewed receipt data before posting.
- Handle failed scans and duplicate submissions without corrupting the ledger.
- Back up persistent data before relying on the app for ongoing household records.
- Keep monitoring free of unnecessary receipt contents and sensitive data.
- Establish retention, account deletion, and external processing disclosures before a public launch.

### Growth path

The household release should use durable storage and real access controls. Larger-scale work can later add scan usage limits, cost monitoring, operational alerts, account recovery improvements, support tools, and native clients. Load targets and commercial requirements remain uncommitted until there is evidence of demand.

## 10. Acceptance scenarios for the first release

These scenarios define observable behavior and should guide implementation checks.

| ID | Scenario | Expected result |
| --- | --- | --- |
| A-01 | Upload a readable receipt from an iPhone and an Android phone. | Both can reach an editable item review screen and open the original photo. |
| A-02 | Correct an extracted price and delete a row that does not belong in the expense. | The expense total uses the corrected retained rows; the deleted row does not contribute. |
| A-03 | Select items from a receipt with tax or a discount. | Included adjustments and their calculation are visible and editable, with no double counting. |
| A-04 | Allocate a $60 expense as $20 and $40. | Save succeeds and detail displays those exact shares. |
| A-05 | Allocate only $59 of a $60 expense. | Save is blocked and the remaining $1 is shown. |
| A-06 | Split $10 equally among three members. | Shares total exactly $10 and the extra cent is assigned deterministically. |
| A-07 | Save the two expenses in the worked example. | Balances are +$25 and −$25, with $90 total group spending. |
| A-08 | Record the example’s $25 repayment. | Both balances become zero and purchase history still totals $90. |
| A-09 | Retry a save after a delayed response. | Only one expense and allocation set exist. |
| A-10 | Open another account’s expense or evidence image. | Access is denied on the server. |
| A-11 | Edit or void a saved expense under the chosen permission policy. | Balances update and the actor and change remain explainable through history. |
| A-12 | Receipt analysis fails. | The user can retry or complete a manual expense without a partial ledger entry. |
| A-13 | Enter a September 18 receipt on September 23. | Extraction targets September 18; the saved expense appears under September 18, while details retain the September 23 creation timestamp. |
| A-14 | Open Summary after entering several older receipts in arbitrary order. | The default list follows transaction dates, newest first under the proposed ordering, rather than upload order. |
| A-15 | Upload a receipt with a missing or ambiguous purchase date. | The user must choose or confirm a date; the app does not silently substitute the upload date. |
| A-16 | Correct a saved expense’s transaction date. | Its chronological position and applicable reporting period update, its monetary balance effect remains unchanged, and the change is recorded in history. |
| A-17 | View the same expense from devices in different time zones. | Its stored purchase calendar date remains the same. |
| A-18 | Create a local “Roommates” group containing three people. | No invitations are sent and no ledger pool is created; selecting it shows expenses and payments involving any of those people. |
| A-20 | Finish reviewing an expense and inspect the top-right actions. | Save is the only expense-save action; no plus or add-another action is shown. |
| A-19 | Save a manual expense without items or an image. | It is stored and calculated like an evidence-backed expense using its explicit reviewed total, date, payer, and allocations. |
| A-21 | Add friends on Review expense and change Paid by from the signed-in account to one of them. | The payer choices update immediately and the selected friend remains the payer through final review. |
| A-22 | Confirm Assign Items while one or more retained rows have no owner. | The rows visibly gain the current payer's avatar, the arrangement locks, and Continue becomes available. |
| A-23 | Open the Select participants page on a supported iPhone with enough friends to exceed its available space. | The page is entirely dedicated to participant selection; the unified search and friends list expands vertically to the top and bottom, and only the friends list inside the component scrolls. |
| A-24 | Scan representative restaurant, movie, and grocery receipts. | Final review starts with the matching editable category and a short identifying merchant/item name when recognizable evidence is present. |
| A-25 | Open a saved expense with a long payer name and a full abbreviated date. | The metadata remains on one line, tightens as needed, and ends with the date. |
| A-26 | Tap any individual relationship in Balances. | Settle Up opens with that person selected; the source row uses only first names in one “Person1 owes Person2 amount” line. |
| A-27 | Open Edit Contributions on an account that has not chosen a slider unit. | Percent is selected by default and each value reads inline as percent plus dollar equivalent in parentheses; selecting dollars reverses the two units. |
| A-28 | Press Back after confirming Assign Items, either before or after reaching final review. | Assign Items stays or reopens with the exact pre-checkmark ownership restored, confirmation autofill removed, and all item/filter controls unlocked. Pressing Back before confirmation returns to Select participants. |

## 11. Proposed implementation sequence

1. **Settle remaining core decisions:** Confirm initial currency, mutation permissions, adjustment policy, sharing, and evidence visibility. Choose API hosting and extraction providers.
2. **Build the ledger:** Implement accounts, friends, saved filters, manual expenses, contribution allocation, history, and deterministic balance calculation.
3. **Add evidence-assisted entry:** Implement private uploads, extraction, editable review, item assignment, and preserved optional evidence.
4. **Complete household use:** Add repayments, revision behavior, error recovery, and phone usability checks. Verify section 10 with representative receipts.
5. **Evaluate expansion:** Use real household feedback to refine the flow before public registration, commercial features, or native distribution.

Each phase should produce usable, reviewable behavior. Record implemented requirement IDs here as development progresses; do not mark planned behavior as complete.

## 12. Open decisions

| ID | Decision | Proposed starting point | When needed |
| --- | --- | --- | --- |
| D-01 | Resolved: reference client platform | Confirmed: native SwiftUI iPhone app. The existing web prototype remains a workflow reference; Android follows after the backend and contracts are defined. | Core decision resolved. |
| D-02 | Initial currency? | The backend currently defaults each account's settings to USD; confirm settings and multi-currency behavior before broader use. | Before production use outside the initial household. |
| D-03 | What does “who added what” include? | Show creator, payer, selected items, and each member’s assigned amount. | Before finalizing expense detail. |
| D-04 | Resolved: who can edit expenses? | The payer owns an expense and is the only one who can edit it; who created it doesn't matter. Each change is recorded in history. The payer edits the name and date by pressing and holding the expense's title; editing the total, split, and items comes later from the same menu. Voiding remains open. | Resolved 2026-09-27. |
| D-05 | Resolved: how are tax and receipt-wide discounts allocated? | Applied in receipt order as rates on each row's running cost: discounts on items, tax on taxed items, surcharges on everything charged so far. The tip is split evenly or by items, per the account's setting. Rates are editable on final review. | Resolved 2026-10-06; tip setting 2026-10-07. |
| D-06 | Resolved: can an item be partially selected, such as one of three units? | A quantity line becomes one row per unit, each assignable separately. | Resolved 2026-10-06. |
| D-07 | Resolved: who can see evidence? | Everyone on the expense it's attached to (creator, payer, and members with a share). Unattached uploads stay private to the uploader. | Resolved with shared expenses. |
| D-08 | Resolved: can one receipt produce multiple expense entries in one flow? | No. Final review offers only Save and completes the current flow. A new expense starts from a new capture or manual entry. | Revised 2026-09-30. |
| D-09 | Do members approve allocations or repayments? | Immediate posting with attribution and history; no approval step initially. | Before finalizing posting behavior. |
| D-10 | Resolved: what is a saved group? | A personal local collection of people used as an any-person transaction filter. It has no membership lifecycle, invitations, ledger pool, or access semantics. | Core decision resolved. |
| D-11 | Resolved: which core infrastructure? | Supabase Auth, hosted PostgreSQL, and Supabase Edge Functions are selected so authentication, canonical data, and stateless API compute stay in one platform. The evidence extraction provider remains open. | Core infrastructure resolved; extraction remains open. |
| D-12 | Are refunds or negative line items needed immediately? | Defer refund transactions; explicitly detect unsupported cases. | Before scan validation. |
| D-13 | Resolved: which date places an expense in history? | Confirmed: receipt purchase date determines placement; creation time is separate. Proposed: newest-first ordering, transaction-date reporting, and same-day tie-breakers as specified in section 6. | Core decision resolved; proposed details remain refinable. |
| D-14 | Is a suggested payment plan needed for ledgers with more than two people? | Begin with person net balances; add deterministic settlement suggestions if required. | Before multi-person settlement UI. |
| D-15 | When should images leave PostgreSQL? | Keep receipt and profile image bytes in PostgreSQL initially. Reconsider only if database size, backup duration, bandwidth, or delivery performance creates a demonstrated problem; preserve the API contract if storage changes. | After measured household or beta usage. |
| D-16 | Resolved: primary native authentication flow? | Confirmed: custom SwiftUI email/password sign-in and account creation, emailed password reset, secondary native Sign in with Apple, automatic local session restoration, and explicit sign out in Settings. | Authentication direction resolved; account linking and deletion remain open. |
| D-17 | Resolved: how are expenses shared? | Confirmed: an expense appears for everyone on it and counts toward both sides' balances; you can only split with accepted friends. Removing a friend keeps shared history, and repayments stay possible with anyone you've shared an expense with. Only the payer can edit an expense (D-04). | Resolved 2026-09-27. |
| D-18 | Resolved: how are accounts identified and connected? | Profiles use a real first and last name for display, a unique lowercase username for exact-match discovery, and a private email for authentication. Friends are accepted account relationships and are distinct from saved filter groups. | Core identity and friendship direction resolved. |
| D-19 | Resolved: how does category affect expense entry? | On-device analysis suggests category and a semi-unique identifying name. Restaurant, cinema, grocery, and concert cues include known merchants and generic receipt/item vocabulary; the name prefers a recognized merchant and then a useful item. Category does not affect navigation; only item count determines whether assignment is skipped. | Revised 2026-10-06; deterministic structure-based suggestions remain the universal fallback, and Apple Foundation Models refine OCR item names, merchant, category, and expense name when available. Item ownership is persisted. |
| D-20 | Resolved: how is the signed-in participant named? | A device setting offers Full name, Me, or You and applies to participant labels and balance sentences. Full name is the default. | Resolved and implemented 2026-09-29; account-level sync is not yet implemented. |
| D-21 | Resolved: how are people assigned to receipt rows? | Assign Items retains fixed-height rows and the bottom All/participant filter strip. With no owners yet, the top-right action is Split All; assigning any row changes it to the checkmark. Split All gives every row to everyone and then exposes the checkmark. Confirmation fills untouched rows to the current payer and waits for Continue, or proceeds immediately when every row already has an owner. Back restores the exact pre-confirmation ownership. | Revised and implemented 2026-10-06. |

## 13. Decision and change log

| Date | Change | Status |
| --- | --- | --- |
| 2026-09-23 | Captured the original receipt-to-group vision and proposed household release. | Initial draft; recommendations are not yet confirmed. |
| 2026-09-23 | Confirmed chronological history as the primary default view and receipt purchase date as the expense transaction date, including receipts entered days later. Added date extraction, review, storage, sorting, and acceptance rules. | Core behavior confirmed; ordering direction and fallback details are proposed. |
| 2026-09-25 | Began a dependency-free local interaction prototype in `receipt-divider/dist`. It supports manual receipt item entry, selection, exact/equal splits, transaction-date history, and recorded repayments. It uses device-local browser storage only and does not yet provide shared accounts, server validation, receipt extraction, or private cloud image storage. | Prototype started; production architecture remains pending. |
| 2026-09-25 | Pivoted to a native iPhone reference client in `apps/ios`. The SwiftUI foundation uses system `TabView`, navigation, and toolbars for Liquid Glass behavior on current iOS, plus sensory feedback for selection and successful saves. | Native iOS source scaffold started; requires a Mac with Xcode for generation, compilation, and device validation. |
| 2026-09-25 | Extended the native local foundation with camera/photo receipt intake, Vision text extraction, editable item rows, dynamic equal/custom allocation, transaction-date history, local ledger persistence, and repayment recording. | Source implementation complete for this local slice; Xcode compilation and on-device validation remain pending. |
| 2026-09-26 | Added the first TypeScript ledger API and PostgreSQL schema with atomic expense writes, idempotency, memberships, repayments, audit versions, derived balances, and database-backed profile and receipt images. | Superseded later that day by the transaction-first, account-owned ledger model below. |
| 2026-09-26 | Selected Supabase Auth and added a custom native authentication gate, later updated to primary email/password sign-in/create-account with emailed password reset, secondary native Sign in with Apple, stored-session restoration, sign out, and backend JWT verification through Supabase JWKS. | Source implementation complete; Supabase project configuration and Mac/Xcode device validation remain pending. |
| 2026-09-26 | Selected Supabase hosted PostgreSQL and replaced group-owned pools with account-owned transaction ledgers. Local people can be collected into named saved filters without invitations; filters use any-person matching and never affect balances or access. General expenses now support optional itemization and optional database-backed evidence for receipts, checks, tickets, or other images. | Backend schema, memory/PostgreSQL adapters, stateless API routes, and tests implemented locally; deployment, PostgreSQL integration testing, iOS sync, extraction, and multi-account sharing remain pending. |
| 2026-09-26 | Selected Supabase Edge Functions as the production API runtime, keeping Auth, PostgreSQL, injected database connectivity, and stateless compute within Supabase. The existing Node runtime remains only as a local test harness and behavioral reference. | Edge Function deployed; process health, PostgreSQL readiness, and anonymous-route rejection verified. iOS ledger integration remains pending. |
| 2026-09-26 | Connected the native SwiftUI client to the live Supabase Edge Function. Authenticated launch provisions the profile and prototype people, loads server transactions and balances, and scopes its local cache by account. Expense saves upload optional evidence and post an idempotent server command; repayments are also server-first. | Source integration complete; Xcode compilation and signed-in device testing remain pending. The fixed four-person UI remains an explicit temporary bridge to dynamic people management. |
| 2026-09-26 | Made Friends a first-class account relationship. Added real-name profile fields, unique usernames, exact-match invitations, accepted/pending states, automatic linked participant creation, signup identity fields, and a Liquid Glass Friends entry with count and list UI. | Database migration applied, Edge API deployed, and two-account smoke test passed. Xcode/device validation and replacement of the fixed participant enum remain pending. |
| 2026-09-27 | Removed local and placeholder people: every participant is an app account, and you split with yourself and accepted friends. Expenses are shared with everyone on them, balances are shown per person and overall, evidence is visible to everyone on the expense, and removing a friend keeps shared history. Existing test transactions between placeholder people were deleted. | Confirmed by the product owner. API unit tests and a full Postgres smoke test pass; migration 004 applied and Edge API deployed. Device testing pending. |
| 2026-09-27 | Added Save and add another, which splits several expenses from one receipt that share a single uploaded evidence asset. Contribution sliders became system sliders with an equal-share detent and whole-dollar or whole-percent haptic ticks, selectable in Settings. Text fields show a Done key, and the interface consistently says “expense” and “payment” instead of “transaction”. | Confirmed by the product owner. API tests pass; installed on paired iPhones. |
| 2026-09-27 | Settings became a bottom tab replacing Profile, holding the profile, account, Friends, Payments, and app settings; Payments left Summary. Summary’s per-person balances collapsed into an expandable one-line summary with one row per person (no more grouping of equal amounts). Sliders show both units and snap in tiers, and Save and add another became a circular + button beside Save. | Confirmed by the product owner. Builds for the simulator; device testing pending. |
| 2026-09-27 | Expense detail: the name is editable by any participant (recorded as a revision, migration 005), total and payer share one line, and “Who owes what” became “Split”. Summary shows only the “Owed by/to” line under the total; Sign out sits on the signed-in row; contributions are entered in the chosen unit with the other beneath. Removed explanatory interface copy throughout. | Confirmed by the product owner; rename permission is provisional under D-04. API tests pass; migration 005 and Edge deploy pending. |
| 2026-09-27 | The payer owns an expense and is the only one who can edit it (D-04 resolved). The payer presses and holds the expense's title to edit its name or date; the title is no longer an always-editable field, and others get no menu. Each changed field is recorded as a revision; a date change only reorders the expense and never changes balances. | Confirmed by the product owner. API tests pass; no migration needed; Edge deploy pending. |
| 2026-09-27 | Expenses can carry an optional, manually chosen category (Groceries, Restaurant, Movie, Concert), picked on the split screen and shown as an icon in Summary’s expense list (migration 006). Existing expenses have none. Suggesting a category from the receipt image is planned. | Requested by the product owner. API tests pass and the app builds for the simulator; migration 006 and Edge deploy pending. |
| 2026-09-27 | Added a developer-only reset in Settings that deletes all expense and payment data for every account while keeping users, account settings, friendships, and saved filters (migration 007 adds the `is_developer` flag). | Keep/delete split, developer-only scope, and type-DELETE confirmation confirmed by the product owner. API tests pass and the app builds for the simulator. |
| 2026-09-27 | Renamed the per-account `ledgers` table, which only held a currency after expenses became shared, to `user_settings` (migration 008). The contribution slider unit moved there, so it follows the account across devices instead of staying on one phone. | Confirmed by the product owner. API tests pass and the app builds for the simulator. |
| 2026-09-29 | Defined three switchable expense layouts: Split Total, Select Items, and Assign Items. On-device analysis will suggest a 2–3 word name, category, and layout, with strong category associations but no locked behavior; the member can switch layouts before saving without losing reviewed receipt data. | Confirmed by the product owner; the first native implementation slice is described below. |
| 2026-09-29 | Implemented the first adaptive-entry slice: deterministic on-device suggestions, switchable Split Total/Select Items/Assign Items views, item-derived restaurant contributions, a save-success animation, and optimistic history/balance updates reconciled through the existing client request ID. | API tests pass. Native compilation and device interaction testing remain pending; Apple Intelligence inference and persisted per-item assignments are not yet implemented. |
| 2026-09-29 | Strengthened save feedback with a heavy haptic, simplified the saved-expense header to title plus amount and payer avatar, and added a Full name/Me/You self-reference preference defaulting to full name. | Confirmed by the product owner; implemented as a device preference. Native compilation and device testing remain pending. |
| 2026-09-29 | Added the payer's first name after their avatar in expense detail, moved Summary upward with an inline title, reduced and dimmed the owed summary while allowing it the card width, and added a subtle selection haptic when an expense opens. | Confirmed by the product owner; native compilation and device testing remain pending. |
| 2026-09-29 | Combined first name, last name, and username in one profile-editing section and added a draggable, pinch-to-zoom circular crop step before profile-photo upload. | Confirmed by the product owner; native compilation and device testing remain pending. |
| 2026-09-29 | Replaced Summary's expandable balance card with a full-card button and light haptic that opens a dedicated Balances list; each balance row opens the existing Settle Up view. The card keeps its total styling and uses a one-line first-name summary with adaptive `+N` overflow. | Confirmed by the product owner; native compilation and device testing remain pending. |
| 2026-09-30 | Added the transaction date to the expense-detail title card after the payer's avatar and first name. In Assign Items, pressing and holding an item opens a compact scrollable participant popover ordered by recent use, with profile images, first names, and direct assignment toggles. | Confirmed by the product owner; implemented with the modern long-press equivalent of Force Touch. Native compilation and device testing remain pending. |
| 2026-09-30 | Made Assign Items controls selectable in Settings. Press and hold now opens a wider, centered popover; Select person first puts all participant avatar/name buttons above the list and makes compact item rows tappable for the active person. Removed the repeated horizontal participant bar beneath every item. | Confirmed by the product owner; implemented as a device preference. Native compilation and device testing remain pending. |
| 2026-09-30 | Condensed the person-first controls to one horizontally scrolling line with exactly All plus one dark pill per participant. Added All-participant assignment and haptic feedback for choosing an assignment target and applying it to an item. | Confirmed by the product owner; native compilation and device testing remain pending. |
| 2026-09-30 | Refined Assign Items around an All/participant filter bar: up to five equal-width pills fill the row before horizontal scrolling, each receipt item stays on one line with a trailing fade before its amount, and filter and assignment taps provide haptic feedback. | Confirmed by the product owner; native compilation and device interaction testing remain pending. |
| 2026-09-30 | Deprecated Select Items in favor of Split Total and Assign Items. Combined expense details with participant selection immediately after scanning, routed single-charge scans directly to final review and multi-row scans through assignment, reorganized final review, and moved contribution sliders to a separate Edit Contributions screen. | Confirmed by the product owner; native compilation and device interaction testing remain pending. |
| 2026-09-30 | Added payer selection beneath Split by on the first review screen, moved primary actions to the top right, and placed receipt mismatch copy after the friend list. Assign Items now shows billed rows above a bottom All/participant avatar strip and uses a two-stage confirm/continue action that visibly fills untouched rows to the payer. Final review places the category value left of the expense name and saves from the top right. | Confirmed by the product owner; native compilation and device interaction testing remain pending. |
| 2026-09-30 | Fixed Assign Items rows to one height so avatar changes do not shift the list, sized the bottom All/participant icon-and-first-name filters so five fit across before scrolling, and removed the final-review plus action. | Confirmed by the product owner; native compilation and device interaction testing remain pending. |
| 2026-09-30 | Rebuilt the first Review expense screen as four consistently spaced regions on one non-scrolling page, with the friends list taking remaining height and scrolling internally. Shortened its top-right action to Split, centered its title, expanded on-device category and identifying-name suggestions, and forced saved-expense metadata onto one tightening line ending in the date. | Confirmed by the product owner; native compilation and device interaction testing remain pending. |
| 2026-09-30 | Restored native rounded/right-aligned styling on the fixed Review expense page, changed saved-expense metadata to one continuous fit-to-width reading, made balance rows explicit Settle Up actions with first-name-only sentences, and made percent the contribution default with the secondary unit inline in parentheses. Migration 009 changes the persisted account default and moves existing accounts to percent. | Confirmed by the product owner; API and native verification pending. |
| 2026-09-30 | Made Assign Items confirmation reversible: Back restores the exact manual assignment map from before the checkmark, removes payer autofill, and unlocks the item and filter controls; Back before confirmation keeps its original navigation behavior. | Confirmed by the product owner; native compilation and device interaction testing remain pending. |
| 2026-09-30 | Separated Search friends into its own visible native rounded section and made the internally scrolling friends region consume all space above the receipt warning even when only a few rows are available. | Confirmed by the product owner; native compilation and device interaction testing remain pending. |
| 2026-10-01 | Added an optional Apple Foundation Models semantic pass after Vision OCR. It normalizes receipt item names and suggests merchant, category, and a concise expense name; proposed totals and dates are accepted only when found in the OCR evidence. Improved deterministic final-total selection and retained it as the fallback on unsupported or unavailable devices. | Source implementation complete; Mac/Xcode compilation and representative on-device receipt validation remain pending. |
| 2026-10-01 | Replaced unconditional double OCR with iOS 26 structured document recognition and an adaptive legacy fallback. Receipt summary classification now tolerates common OCR substitutions, prevents amounts after the summary boundary from becoming items, and uses alternate recognition candidates. Review no longer waits for generative cleanup, which may update only untouched extracted fields. | Parser regression tests cover explicit, misread, alternate-candidate, post-subtotal, and discounted totals. Mac/Xcode compilation and representative on-device performance validation remain pending. |
| 2026-10-02 | Minimized the Review expense controls into a single-line summary card (total, paid by avatar/name, date) matching existing expense detail styling, with a press-and-hold context menu to edit Paid by, total, date, and layout. Combined Search friends with the internally scrollable friends list into a single component with standard iOS rounded search styling. | Confirmed by the product owner; native compilation and device interaction testing pending. |
| 2026-10-02 | Extracted final Review Expense into a unified component (`ExpenseReviewEditorView`) with top-aligned categorizer/naming, reordered controls (editable Expense total, Paid by, Date of expense, Split by), integrated contribution sliders on the same page, and removed the red error disclaimer. Tapping the description card on an existing expense routes directly to this component populated with all fields. | Confirmed by the product owner; native compilation and device interaction testing pending. |
| 2026-10-02 | Dedicated the first post-scan screen entirely to participant selection under the title Select participants, replaced the Split button with a top-right checkmark icon, removed the top descriptor and bottom mismatch warning, expanded the combined search/friends component to reach the top and bottom of the page, and reduced search bar height. | Confirmed by the product owner; native compilation and device interaction testing pending. |
| 2026-10-02 | Encapsulated Assign Items into portable `AssignItemsView` with top content margin matching review, centered bottom filters when fewer than five, and integrated an Assign items section between main controls and sliders on Review expense. Removed the Contributions header to maintain uniform tight section spacing. | Confirmed by the product owner; native compilation and device interaction testing pending. |
| 2026-10-06 | Merged item ownership into the current frontend architecture and retired the Split by selector. A single item belongs to everyone; several items open Assign Items. Its top-right action is Split All only while every row is unowned, then becomes the checkmark. The checkmark auto-assigns untouched rows to the current payer or continues immediately when all rows are owned. | Confirmed by the product owner; API tests and typecheck pass. Migration 010 and Edge deployment are required before the main push. |
| 2026-10-06 | Made receipt reading model-first on iOS 26: the on-device model reads merchant, date, items with quantities, item discounts and taxed flags, subtotal, ordered adjustments, and total, with one corrective re-read and the rule-based parser as fallback. Items keep printed prices with separate local and global offsets; discounts, taxes, and surcharges apply in receipt order; the tip is its own evenly split row. Final review edits adjustment rates and the tip. Raised the minimum to iOS 26. |
| 2026-10-06 | After a real restaurant receipt was misread (names and prices recognized as separate columns), receipt text is regrouped into rows before the model reads it; misplaced unit prices and discounts are settled against the subtotal; cash and card totals add the difference as a surcharge; a missing total warns and triggers a re-read. Each receipt now uploads diagnostics for replaying misreads. |
| 2026-10-06 | Replayed two real misreads from diagnostics. The model read Five Guys correctly but marked every item untaxed, which zeroed the tax; the smokehouse failed because document recognition lost two prices and the model could not pair 14 items with prices. Code now pairs names with prices by position (with the accurate OCR pass filling gaps) and reads quantities, and the model only labels rows; both receipts now read exactly. |
| 2026-10-06 | Assign Items shows each item's local total. The tip is no longer an item row: it lives with the adjustments, is split evenly, and carries its share of any later surcharge. Rates within 0.005 points of a whole percent display as whole. |
| 2026-10-06 | A signed card slip with a handwritten tip lost the tip: the model stopped labeling after the printed total. The model is now told how many rows to label, unlabeled summary rows trigger a re-read, and totals are read by position (a tip between totals makes the later one final; totals without one are cash and card prices). |
| 2026-10-06 | Added cloud receipt vision processing backed by OpenAI `gpt-4o-mini` with strict structured outputs (`POST /v1/receipts/parse`), extracting items, prices, date, total, merchant, and category. The iOS client reads with cloud vision first; when the request fails (offline, signed out, or no key), the on-device model and rule-based parser read the receipt instead. Cloud tax, discount, and tip become ordered adjustments. | Merged with main's on-device reader on `feature/cloud-receipt-vision`. |
| 2026-10-07 | Added a Split tip setting (Evenly or By items), saved to the account, for how starting contributions divide the tip. Even stays the default. |
| 2026-10-07 | Cloud vision now returns the same reading as the on-device model, printed rows each with a label, instead of its own items-and-totals summary. Code reads every amount from the rows and applies the same quantities, item discounts, taxed items, totals, checks, re-read, adjustment order, and diagnostics as on-device reading; only the image-to-rows step differs. |

Future entries should briefly explain material scope or behavioral decisions. Update the main requirements to reflect the latest decision rather than leaving contradictory instructions in this log.

## 14. Reference background

These references informed feasibility discussion; they do not commit the implementation to a vendor. Recheck current documentation when selecting technology.

- [Image reading capabilities and limitations](https://developers.openai.com/api/docs/guides/images-vision)
- [Apple web application guidance](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariWebContent/ConfiguringWebApplications/ConfiguringWebApplications.html)
- [Expo cross-platform tutorial](https://docs.expo.dev/tutorial/introduction/)
