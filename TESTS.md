# TESTS.md — Expired

Cross-app test tracking per `_shared/test-tracking.md`. 🔴 not yet run · 🟠
Claude-verified only (build/logic check, not on-device) · 🟢 Deon-confirmed on
device. Claude may never write 🟢 — only Deon's own y/n flips a line.

---

### Context menu / long-press

🔴 Row long-press context menu no longer detaches/floats — *(source:
IMPLEMENTATION_LOG.md 2026-08-19 "Context menu fix")*
1. Long-press a subscription row in the middle of a section → the row lifts in
   place with a native platter (no separate floating white bar/menu) — y/n
2. The context menu shows all five actions (Edit, Duplicate, Archive,
   Cancel/Reinstate, Delete) and each works — y/n

### Settings — structure

🔴 Settings section order and content match the revamp — *(source:
IMPLEMENTATION_LOG.md 2026-08-19 "Settings revamp")*
1. Section order top to bottom is: Expired Pro, General, Appearance, Screenshot
   Import, Notifications, Data & Backup, Privacy, Support, version footer — y/n
2. Data & Backup contains Archive, Categories, Refresh Icons, iCloud Sync,
   iCloud Backup, and a single "Import / Export" row (no separate Export/Import
   rows) — y/n
3. Support section shows only "Replay Onboarding" and it actually replays
   onboarding — y/n
4. Refresh Icons / Restore Purchases / Import-Export rows are tappable
   anywhere across the row width, not just on the text — y/n
5. Same check on macOS: sections render correctly, no double chrome on any
   Menu, Toggle renders as a switch — y/n

### Settings — Import / Export sheet

🔴 Import/Export opens as its own sheet and both directions work — *(source:
IMPLEMENTATION_LOG.md 2026-08-19 "Settings revamp")*
1. Tapping "Import / Export" as a free user shows the paywall instead of
   opening the sheet — y/n
2. As a Pro user, tapping it opens a sheet titled "Import / Export" with
   separate Export and Import sections — y/n
3. Export Backup → confirms the unencrypted-data warning → produces a JSON
   file via the file exporter — y/n
4. Import Backup → picking a valid Expired JSON backup shows "Imported N new,
   updated N" — y/n

### Settings — Debug menu

🔴 Debug collapses into one gated row and every nested screen works — *(source:
IMPLEMENTATION_LOG.md 2026-08-19 "Settings revamp")*
1. 4-second long-press (iOS) / ⌥-click (macOS) on the version footer reveals a
   single "Debug Menu" row (no inline debug sections appear directly in
   Settings) — y/n
2. Tapping "Debug Menu" pushes to a Debug screen (not a sheet) — y/n
3. Inside Debug, "Mascot Gallery" pushes to a working gallery screen — y/n
4. Inside Debug, "CloudKit Debug" pushes to its own screen with Status rows,
   three full-width action buttons (Refresh / Copy Transcript / Clear Log),
   and a scrollable activity log — y/n
5. "Copy Diagnostic Report" and "Copy Transcript" both flip their label to
   "Copied" briefly and fire a haptic — y/n
6. "Hide Debug" re-conceals the row and the version footer returns to normal —
   y/n
7. The version footer's own tap-to-copy shows "Copied!" briefly instead of
   just copying silently — y/n

### Settings — Support / About

🔴 Support section row set and order — *(source: IMPLEMENTATION_LOG.md 2026-08-20
"Support/About rows")*
1. Settings → Support lists, in this order: Report a Problem, Send Feedback,
   Replay Onboarding, Acknowledgements — y/n
2. "Rate Expired" and "Tip Jar" are **absent** (expected — the App Store record
   and the tip products don't exist yet; these rows hide themselves rather than
   ship dead) — y/n
3. Every row is tappable anywhere across its full width, not just on the text —
   y/n
4. The section footer reads "Bug reports and feature requests open a prefilled
   email…" — y/n

🔴 Contact / Feedback mail composer — *(source: IMPLEMENTATION_LOG.md 2026-08-20)*
5. Tap "Report a Problem" → a mail composer opens addressed to
   swiftstudio.dob@gmail.com, subject "Expired 1.0 — bug report" — y/n
6. That draft's body has "What happened? / What did you expect instead?"
   prompts, then a `---` block listing App, OS, Device, Locale — y/n
7. The Device line shows a real model identifier (e.g. `iPhone16,2`), **not**
   the generic word "iPhone" — y/n
8. Tap "Send Feedback" → same composer but subject "Expired 1.0 — feedback" and
   a "What would you like Expired to do?" prompt — y/n
9. Cancelling the composer returns to Settings with Settings still open (both
   sheet layers do not collapse) — y/n
10. On macOS, "Report a Problem" opens a prefilled draft in Mail with the
    subject AND the full body intact (nothing truncated mid-sentence) — y/n

🔴 Acknowledgements — *(source: IMPLEMENTATION_LOG.md 2026-08-20)*
11. Tap "Acknowledgements" → pushes to a screen (not a sheet) listing 8
    packages: purchases-ios, supabase-swift, swift-asn1, swift-clocks,
    swift-concurrency-extras, swift-crypto, swift-http-types,
    xctest-dynamic-overlay — y/n
12. Each row shows its licence (MIT or Apache 2.0) and tapping it opens that
    package's GitHub page — y/n
13. There's a second "Icons & Logos" section mentioning SF Symbols — y/n

🔴 Tip Jar (only testable once the products exist in App Store Connect) —
*(source: IMPLEMENTATION_LOG.md 2026-08-20)*
14. With tip products live, a "Tip Jar" row appears and opens a sheet showing
    three tips cheapest-first with localized prices — y/n
15. Buying a tip shows a "Thank You" alert and grants nothing — Pro state is
    unchanged before and after — y/n
16. Cancelling the App Store sheet produces NO error alert and no haptic — y/n

### Home — Sort & Filter sheet

🔴 Dedicated Sort & Filter sheet replaces the old nested overflow-menu
submenus — *(source: IMPLEMENTATION_LOG.md 2026-08-20 "Sort & Filter sheet")*
17. Overflow menu (⋯) → "Sort & Filter" opens a sheet (not a nested menu) — y/n
18. "Sort By" is a dropdown; selecting "Date Added" sorts/groups Home by date
    added — y/n
19. "Order" is a segmented Ascending/Descending control; flipping it reverses
    whichever sort field is active (dates soonest/latest, name A-Z/Z-A, price
    low/high) — y/n
20. Filter is grouped into 3 headed sections — Status (Trial, Cancelled,
    Expired), Renewal (Auto-Renew, Manual Renewal), Plan (Lifetime, Free) —
    each a 2-column grid of equal-size buttons — y/n
21. Selecting two tags in the SAME section is OR (e.g. Trial + Cancelled
    shows items that are either) — y/n
22. Selecting tags in DIFFERENT sections is AND (e.g. Auto-Renew + Free shows
    only items that are both auto-renewing AND free) — y/n
23. "Free" matches items with $0 cost (not Trials — those only show under the
    Trial tag) — y/n
24. "Lifetime" matches one-time-purchase items (billing cycle "One-time") —
    y/n
25. "Reset" (top-left) is disabled with no filters selected, and clears all
    filters (across all 3 sections) when tapped — y/n
26. No filter-chip row appears on the Home list itself — filters are only
    visible/editable inside the sheet — y/n
27. A small blue dot appears on the ⋯ toolbar icon itself whenever any filter
    tag is active, and disappears when cleared — y/n
28. The ⋯ menu no longer has divider lines between rows — y/n
29. macOS: Toggle/segmented controls render natively (switch, not checkbox;
    no double chevron chrome on the dropdown) — y/n

### Add/Edit — App Store search

🔴 Name field stays editable after picking an App Store search result —
*(source: IMPLEMENTATION_LOG.md 2026-08-20 "App Store title glitch fix")*
30. Add Subscription → type a name (3+ chars) → "Search App Store" → pick a
    result → back on the main Add page, tap into the Name field and delete
    several characters in a row without needing to type first → deletes work
    immediately every time — y/n
31. Retype a different name after deleting → no visual glitch/flicker in the
    field — y/n
