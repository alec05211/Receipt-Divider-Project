# Receipt Divider — Living Product Specification

Status: Draft for refinement; local interaction prototype started  
Last updated: 2026-09-25  
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

**Confirmed:** Make it easy to photograph a receipt, extract its individual items and costs, select the items to share, assign individual contributions, and maintain a shared group expense history with accurate running totals.

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
| S-03 | Confirmed | Combine selected items into an expense total for a group. |
| S-04 | Confirmed | Use a subsequent screen to assign individual group member contributions. |
| S-05 | Confirmed | Sum individual responsibilities across group entries. |
| S-06 | Confirmed | Maintain an expense log with descriptions, actual items, attribution, contribution breakdowns, and original receipt photos. |
| S-07 | Confirmed | Support users with iOS and Android phones. |
| S-08 | Confirmed | Use a native SwiftUI iPhone app as the reference client, including Apple system navigation, Liquid Glass behavior, and meaningful haptic feedback. |
| S-09 | Proposed | Provide accounts, private groups, and invitation-based membership. |
| S-10 | Proposed | Track who paid, net balances, and manually recorded repayments. |
| S-11 | Proposed | Permit manual expense entry when a receipt is unavailable or scanning fails. |
| S-12 | Proposed | Use one payer per expense and one currency per group. |

### Deferred scope

- App Store and Google Play distribution, pending validation of the web experience.
- Bank connections, money transfers, and automatic collection of payments.
- Currency conversion and expenses involving multiple currencies within one group.
- Multiple payers for a single expense.
- Automatic recurring charges, subscriptions, and monetization.
- Complex approval workflows and assigning every individual item to different subsets of members.
- Receipt splitting across multiple groups in one guided flow.

**Confirmed:** The iPhone app is the reference experience. It uses standard SwiftUI navigation, tabs, toolbars, sheets, and controls so the current iOS system supplies Liquid Glass behavior. Avoid custom recreation of Liquid Glass effects. Use haptics only for meaningful selection and successful completion feedback.

Android remains a required future client. Keep the backend, money rules, API contracts, and data model independent of SwiftUI so an Android implementation can use the same shared ledger without duplicating financial logic.

## 4. Primary user journey

### Navigation model

**Confirmed:** The main view is a chronological, transaction-first activity list. Each transaction visibly shows the people included in that transaction through their avatars. The app maintains a reusable people roster, ordered with recently used people first during participant selection.

**Confirmed native navigation:** The bottom tab bar contains Transactions (`clock`), Add expense (`plus.circle.fill`), and Profile (`person.crop.circle`). Settings lives in the Transactions screen’s top-right `gearshape` button. Use SF Symbols and system components rather than custom navigation icon artwork. Settlement and people management live under Profile.

Do not make saved groups the primary navigation model. A transaction can include any subset of people from the roster without requiring the user to create a separate group for every combination. Saved groups may later exist as optional templates for recurring households, trips, or teams.

### Core add-transaction flow

**Confirmed:** The central Add action in the native iOS tab bar begins a receipt capture flow:

1. Open the camera. The user may instead choose an existing receipt image or manually enter items.
2. Show a short loading state while receipt item rows and likely costs are extracted.
3. Present an editable multi-select list of receipt rows: item description, cost, and include control. The user confirms selected items and any adjustments.
4. Present a participant picker, ordered by recently used people. The user tags the friends involved and confirms.
5. Present the split screen. Equal shares are the default; the user can switch to exact custom contributions. Saving requires contributions to equal the transaction total.
6. Return to the chronological transaction list, where the saved transaction displays its associated participant avatars.

The receipt’s purchase date, rather than time of entry, determines its position in the transaction list.

### Transaction detail and evidence

**Confirmed:** Opening a transaction shows the cost breakdown before the receipt image: total cost, who paid the purchase, and the exact assigned share for every tagged person. Scrolling then reveals the original receipt photo and selected line items as the paper trail. The final section shows recent transactions involving one or more of the same tagged people, with their avatars visible.

### A. Open the group

**Confirmed:** The group’s primary default view is a chronological transaction history organized by when purchases occurred, rather than when entries were added. **Proposed:** Show newest purchase dates first and group entries under date headings. Group spending, each member’s assigned costs, and proposed net balances remain accessible. A prominent action begins a new expense.

### B. Capture the receipt

The member takes a photo or chooses an existing image. The app shows upload and analysis progress, with recoverable error states.

### C. Review and select items

The app presents editable extracted rows with selection controls. Each row shows an item description and line total; quantity and unit price appear when available. The selected total changes immediately as rows are selected or corrected.

The original receipt is accessible during review. Unselected personal items do not contribute to the shared expense. Receipt-level adjustments are shown separately and explicitly included or excluded.

**Confirmed:** Explicitly target the receipt’s purchase date during extraction and use it as the expense’s transaction date. **Proposed:** Display this date prominently for review and correction before saving. If the receipt date is missing, unreadable, or ambiguous, require the member to choose or confirm the transaction date instead of silently using the upload date.

### D. Allocate contributions

On the next screen, the member confirms the group, enters a description, identifies the payer, and assigns member contributions. Proposed split modes are equal shares, percentages, and exact amounts.

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
| R-03 | Proposed | Extract quantities, line totals, merchant, date, subtotal, discounts, tax, tip, and total when visible; missing information remains missing. |
| R-04 | Proposed | Show a mismatch when extracted amounts do not reconcile with the receipt total; do not silently invent balancing items. |
| R-05 | Proposed | Preserve the original uploaded image independently of corrected extraction data. |
| R-06 | Proposed | Allow retries and manual correction without losing already entered work. |
| R-07 | Confirmed | Specifically extract the receipt’s purchase date and use it as the expense transaction date, independently of when the receipt is uploaded or entered. |
| R-08 | Proposed | Make the extracted transaction date editable and require explicit date selection or confirmation if extraction cannot determine it reliably. |

### Selection and expense creation

| ID | Status | Requirement |
| --- | --- | --- |
| E-01 | Confirmed | Allow multiple receipt items to be selected and show a running total. |
| E-02 | Confirmed | Save the actual selected item details with the expense, not only a total. |
| E-03 | Confirmed | Collect a description and individual contributions on the next screen. |
| E-04 | Proposed | Clearly distinguish creator, payer, and members responsible for a share. |
| E-05 | Proposed | Support equal, percentage, and exact-amount allocation, including a zero share. |
| E-06 | Proposed | Save the expense, items, and allocations atomically and prevent duplicate saves caused by retries. |
| E-07 | Proposed | Copy reviewed item values into a saved expense snapshot so later extraction changes cannot silently alter balances. |

### Groups and history

| ID | Status | Requirement |
| --- | --- | --- |
| G-01 | Proposed | Restrict group data and receipts to authorized group members. |
| G-02 | Confirmed | Show an expense log with description, items, attribution, split, and receipt evidence. |
| G-03 | Confirmed | Aggregate assigned costs by member across the group. |
| G-04 | Proposed | Separately show amounts paid, assigned costs, repayments, and net balances. |
| G-05 | Proposed | Preserve attributable revisions when an expense is edited or voided; recalculate balances from the current effective entries. |
| G-06 | Proposed | Record repayments separately from purchases and allow erroneous repayments to be reversed with history. |
| G-07 | Confirmed | Make chronological transaction history the primary default group view, ordered by transaction date rather than entry creation time. Backdated purchases appear on the date they occurred. |
| G-08 | Proposed | Default to newest transaction date first, use date headings, and apply date filters and spending periods to transaction dates. Keep creation timestamps available in entry details for auditing. |

## 6. Financial rules and invariants

These are proposed implementation rules. They should be settled before implementing the financial engine.

### Money representation

- Store money as integer minor units, such as cents for USD, with an explicit currency.
- Use deterministic application logic for calculations. Receipt AI proposes data; it does not determine authoritative arithmetic.
- Use one currency per group in the first release. A receipt in a different currency must be rejected or handled manually under an explicitly decided policy.
- The initial scope is nonnegative purchases and repayments. Refunds and credits need an explicit later policy.

### Expense total

`expense total = sum of selected line totals + included tax + included tip + included fees − included discounts`

Avoid subtracting discounts twice when a line total already includes them. Keep the full receipt total separate from the selected expense total: these can legitimately differ.

For partial receipt selection, show how receipt-level tax, fees, and discounts are allocated. A proportional allocation may be suggested, but tax treatment may differ by item. The member must be able to review and correct the included amounts. The exact default is open in section 12.

### Allocation

- The sum of member shares must exactly equal the expense total before saving.
- Exact-amount splits show the remaining difference as the member edits.
- Percentage splits must total 100%; convert them to exact monetary shares for storage.
- Equal and percentage splits use a deterministic rounding rule. Proposed rule: distribute leftover cents by largest fractional remainder, breaking ties by stable member order, and show the resulting amounts before saving.
- A payer can have a zero assigned share. A member can have a share without being the payer or creator.

### Group balances

For each member:

`net balance = expenses paid − assigned expense shares + repayments sent − repayments received`

- Positive means the member should receive money; negative means they owe money.
- Member net balances sum to zero within a group.
- Repayments change balances but do not change purchase totals.
- Aggregate balances are derived from saved records, not independently editable totals.

### Worked example

| Entry | Payer | Owner’s share | Roommate’s share |
| --- | --- | ---: | ---: |
| Groceries: $60 | Owner | $20 | $40 |
| Supplies: $30 | Roommate | $15 | $15 |

The owner paid $60 and owes $35 in assigned costs, yielding +$25. The roommate paid $30 and owes $55, yielding −$25. A $25 repayment from the roommate to the owner brings both balances to zero. Group purchase spending remains $90.

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

This describes responsibilities, not a committed database schema or technology stack.

| Entity | Purpose and important fields |
| --- | --- |
| User | Identity, display name, and an optional database-backed profile image. |
| Group | Name, currency, creator, and timestamps. |
| Membership | Group, user, role, and membership state. Preserve references needed for historical entries. |
| Receipt | Uploader, private image bytes stored in the database, media type, integrity hash, merchant/date if known, extraction status, extracted data, reviewed data, and full receipt total. |
| Expense | Group, creator, payer, description, currency, total, transaction date (purchase calendar date), receipt reference if present, effective status, creation timestamp, and modification timestamp. |
| Expense item | Saved description, quantity if known, selected line total, and source receipt-row reference if available. |
| Expense adjustment | Included tax, tip, fee, or discount, with amount and allocation method. |
| Expense allocation | Expense, member, and exact assigned amount; preserve chosen split mode where useful for editing. |
| Repayment | Group, sender, recipient, amount, transaction date (actual payment date), creation timestamp, recorder, and effective status. |
| Revision/audit event | Actor, time, action, affected record, and sufficient change information to explain balance changes. |

## 8. Interface expectations

**Proposed:** Use a clear, touch-friendly interface designed first for phone screens.

- Primary screens: group overview, capture/upload, receipt review, allocation, expense detail, and repayment entry.
- Make the chronological transaction list the main group view. Show purchase dates prominently and keep “added on” timestamps secondary in entry details.
- Keep receipt item names and monetary amounts readable without horizontal scrolling.
- Make selected states, missing allocation, extraction errors, and save success explicit.
- Preserve draft state when moving between review and allocation.
- Support accessible labels, adequate contrast, keyboard access, and clear validation messages.
- Show upload/scanning/loading states and useful retry actions.
- Explain how a displayed balance was calculated through accessible expense history.

Visual design, naming, and navigation details remain open.

## 9. Architecture and operational requirements

### Proposed architecture

- Responsive web client for capture, review, allocation, and group history.
- Authenticated backend for group access, validation, scanning orchestration, and atomic expense writes.
- Persistent PostgreSQL database for identities, memberships, expenses, allocations, repayments, history, profile images, and receipt image bytes.
- Keep image access behind authenticated API endpoints and impose conservative size limits. The initial implementation uses 5 MB per profile image and 15 MB per receipt; these are implementation defaults rather than permanent product requirements.
- Replaceable receipt extraction service so provider choices do not define the financial model.

The initial API implementation uses portable TypeScript HTTP handlers and a PostgreSQL adapter. Hosting, managed PostgreSQL, authentication, and extraction providers are not yet selected.

### Trust and reliability

- Enforce group access on the server, including access to original images.
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
| A-02 | Correct an extracted price and select only some items. | The selected total uses corrected selected values; unselected items do not contribute. |
| A-03 | Select items from a receipt with tax or a discount. | Included adjustments and their calculation are visible and editable, with no double counting. |
| A-04 | Allocate a $60 expense as $20 and $40. | Save succeeds and detail displays those exact shares. |
| A-05 | Allocate only $59 of a $60 expense. | Save is blocked and the remaining $1 is shown. |
| A-06 | Split $10 equally among three members. | Shares total exactly $10 and the extra cent is assigned deterministically. |
| A-07 | Save the two expenses in the worked example. | Balances are +$25 and −$25, with $90 total group spending. |
| A-08 | Record the example’s $25 repayment. | Both balances become zero and purchase history still totals $90. |
| A-09 | Retry a save after a delayed response. | Only one expense and allocation set exist. |
| A-10 | Open another group’s expense or receipt without membership. | Access is denied on the server. |
| A-11 | Edit or void a saved expense under the chosen permission policy. | Balances update and the actor and change remain explainable through history. |
| A-12 | Receipt analysis fails. | The user can retry or complete a manual expense without a partial ledger entry. |
| A-13 | Enter a September 18 receipt on September 23. | Extraction targets September 18; the saved expense appears under September 18, while details retain the September 23 creation timestamp. |
| A-14 | Open the group after entering several older receipts in arbitrary order. | The default transaction list follows transaction dates, newest first under the proposed ordering, rather than upload order. |
| A-15 | Upload a receipt with a missing or ambiguous purchase date. | The user must choose or confirm a date; the app does not silently substitute the upload date. |
| A-16 | Correct a saved expense’s transaction date. | Its chronological position and applicable reporting period update, its monetary balance effect remains unchanged, and the change is recorded in history. |
| A-17 | View the same expense from devices in different time zones. | Its stored purchase calendar date remains the same. |

## 11. Proposed implementation sequence

1. **Settle core decisions:** Confirm platform, initial currency, permissions, adjustment policy, and receipt visibility. Choose infrastructure and extraction providers.
2. **Build the ledger:** Implement accounts, groups, manual expenses, contribution allocation, history, and deterministic balance calculation.
3. **Add receipts:** Implement private uploads, extraction, editable review, item selection, and preserved evidence.
4. **Complete household use:** Add repayments, revision behavior, error recovery, and phone usability checks. Verify section 10 with representative receipts.
5. **Evaluate expansion:** Use real household feedback to refine the flow before public registration, commercial features, or native distribution.

Each phase should produce usable, reviewable behavior. Record implemented requirement IDs here as development progresses; do not mark planned behavior as complete.

## 12. Open decisions

| ID | Decision | Proposed starting point | When needed |
| --- | --- | --- | --- |
| D-01 | Resolved: reference client platform | Confirmed: native SwiftUI iPhone app. The existing web prototype remains a workflow reference; Android follows after the backend and contracts are defined. | Core decision resolved. |
| D-02 | Initial currency? | One selected currency per group; confirm the household currency. | Before ledger implementation. |
| D-03 | What does “who added what” include? | Show creator, payer, selected items, and each member’s assigned amount. | Before finalizing expense detail. |
| D-04 | Who can edit or void expenses? | Creator can edit/void their entries, with visible history; confirm administrator powers. | Before mutation permissions. |
| D-05 | How are tax and receipt-wide discounts allocated? | Suggest proportional amounts, clearly disclosed and editable. | Before receipt calculation implementation. |
| D-06 | Can an item be partially selected, such as one of three units? | Initially select whole rows; decide whether quantity splitting is essential. | Before selection interface. |
| D-07 | Who can see the full receipt, including personal items? | All group members can see the original attached receipt; clearly disclose this before posting. | Before sharing receipts. |
| D-08 | Can one receipt produce multiple expense entries? | Initially one entry per upload flow; decide duplicate-receipt handling. | Before receipt persistence design. |
| D-09 | Do members approve allocations or repayments? | Immediate posting with attribution and history; no approval step initially. | Before finalizing posting behavior. |
| D-10 | What happens when members leave a group? | Preserve historical references and balances; define access and outstanding-debt behavior. | Before membership removal. |
| D-11 | Which infrastructure and extraction providers? | Select for accuracy, cost, privacy, and operational simplicity after a receipt sample evaluation. | Before integration work. |
| D-12 | Are refunds or negative line items needed immediately? | Defer refund transactions; explicitly detect unsupported cases. | Before scan validation. |
| D-13 | Resolved: which date places an expense in history? | Confirmed: receipt purchase date determines placement; creation time is separate. Proposed: newest-first ordering, transaction-date reporting, and same-day tie-breakers as specified in section 6. | Core decision resolved; proposed details remain refinable. |
| D-14 | Is a suggested payment plan needed for groups larger than two? | Begin with member net balances; add deterministic settlement suggestions if required. | Before multi-person settlement UI. |
| D-15 | When should images leave PostgreSQL? | Keep receipt and profile image bytes in PostgreSQL initially. Reconsider only if database size, backup duration, bandwidth, or delivery performance creates a demonstrated problem; preserve the API contract if storage changes. | After measured household or beta usage. |

## 13. Decision and change log

| Date | Change | Status |
| --- | --- | --- |
| 2026-09-23 | Captured the original receipt-to-group vision and proposed household release. | Initial draft; recommendations are not yet confirmed. |
| 2026-09-23 | Confirmed chronological history as the primary default view and receipt purchase date as the expense transaction date, including receipts entered days later. Added date extraction, review, storage, sorting, and acceptance rules. | Core behavior confirmed; ordering direction and fallback details are proposed. |
| 2026-09-25 | Began a dependency-free local interaction prototype in `receipt-divider/dist`. It supports manual receipt item entry, selection, exact/equal splits, transaction-date history, and recorded repayments. It uses device-local browser storage only and does not yet provide shared accounts, server validation, receipt extraction, or private cloud image storage. | Prototype started; production architecture remains pending. |
| 2026-09-25 | Pivoted to a native iPhone reference client in `apps/ios`. The SwiftUI foundation uses system `TabView`, navigation, and toolbars for Liquid Glass behavior on current iOS, plus sensory feedback for selection and successful saves. | Native iOS source scaffold started; requires a Mac with Xcode for generation, compilation, and device validation. |
| 2026-09-25 | Extended the native local foundation with camera/photo receipt intake, Vision text extraction, editable item rows, dynamic equal/custom allocation, transaction-date history, local ledger persistence, and repayment recording. | Source implementation complete for this local slice; Xcode compilation and on-device validation remain pending. |
| 2026-09-26 | Added a provider-neutral TypeScript ledger API and PostgreSQL schema with atomic expense writes, idempotency, memberships, repayments, audit versions, derived balances, and database-backed profile and receipt images. | Backend foundation implemented and locally tested; production authentication, invitations, deployment provider, PostgreSQL integration testing, and iOS synchronization remain pending. |

Future entries should briefly explain material scope or behavioral decisions. Update the main requirements to reflect the latest decision rather than leaving contradictory instructions in this log.

## 14. Reference background

These references informed feasibility discussion; they do not commit the implementation to a vendor. Recheck current documentation when selecting technology.

- [Image reading capabilities and limitations](https://developers.openai.com/api/docs/guides/images-vision)
- [Apple web application guidance](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariWebContent/ConfiguringWebApplications/ConfiguringWebApplications.html)
- [Expo cross-platform tutorial](https://docs.expo.dev/tutorial/introduction/)
