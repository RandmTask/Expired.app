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
