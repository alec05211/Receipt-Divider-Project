---
name: receipt-divider-maintenance
description: Maintain Receipt Divider source and product documentation when changing its native iOS client, web prototype, or shared ledger design.
---

# Receipt Divider maintenance

Use this skill for substantive work in this repository.

`README.md` is the public project orientation document. Update it in the same change when work materially changes any of the following:

- the product’s primary navigation or receipt-to-transaction flow;
- supported platforms or how the app is built and run;
- the repository layout or key entry points;
- delivered user-visible capabilities or meaningful limitations.

Keep the README concise and accurate. Do not add minor implementation churn, speculative work, or internal debugging details.

`PRODUCT_SPEC.md` is the living source of truth for requirements and product decisions. Update it when a user confirms a behavior, scope, data rule, or navigation decision. Keep `apps/ios/README.md` focused on native iOS setup and implementation constraints.

Before declaring a major feature complete, ensure the README, product specification, and relevant platform documentation do not contradict the delivered behavior.

## Interface copy

Keep user-visible text minimal. The UI states what the user needs to act, never how a feature works or what changed.

- Do not add footers, hints, descriptions, or notes that explain mechanics, describe a change you made, or restate what the interface already shows. Examples of what not to ship: “Dimmed items are already in an expense you saved from this receipt.”, “Sliders show each contribution in both dollars and percent of the total…”, and settings rows naming the backend (“Ledger: Supabase”).
- Prefer a short label or no text. Keep errors, validation, and labels needed to act.
- Report behavior details to the developer in your summary or in `PRODUCT_SPEC.md`, not in the app.
