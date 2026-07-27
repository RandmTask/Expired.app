# My Questions — Expired

A chronological log of Deon's questions and the answers given (oldest first).

---

## 2026-07-27 — Netflix-style onboarding: pick your services from a logo grid. Is 20 services enough, and what flow?

**A:** 20 is too few — go to ~32, and the list must include non-app items (gym,
insurance, passport, car rego) as SF-Symbol tiles, because a pure app-logo grid
ignores Expired's whole document side.

Flow: one scrollable multi-select grid (tap to toggle, sticky "Continue with N
selected" CTA), then a single lightweight batch screen where each picked service
is a compact row with cost + renewal date inline — never N sequential
AddEditSubscriptionView pushes.

Three constraints found in the code that shape the design more than the grid does:
1. Free tier is capped at 5 items (`HomeView.swift:17`), so a "pick everything you
   use" grid walks a free user straight into the paywall mid-onboarding.
2. `SubscriptionItem.nextRenewalDate` is non-optional, so "I don't know the date
   yet" isn't representable without a CloudKit schema change.
3. Catalog icons aren't bundled (1 of 20 entries has a local icon) — a 32-tile grid
   would fire ~32 iTunes artwork fetches on first launch and render blank offline.

Full spec and the open design questions were delivered in chat; the blueprint lands
on `ROADMAP.md` once the questions are answered.

## 2026-07-27 — Region-ordered catalogs for every country would be huge. Can we do it simply, or just support a few main countries and default everyone else to the USA?

**A:** The blowup doesn't happen, because only ~6 of the 32 tiles are region-specific —
the rest (Netflix, Spotify, Disney+, Adobe, ChatGPT…) plus all the non-app tiles are
global. So: bundle icons for the ~26-entry global core only (~650 KB), let the small
region packs resolve icons at runtime, and ship AU/UK/US packs at launch with everyone
else falling back to the core. Modelled as one optional JSON field (`"regions": ["AU"]`,
absent = global), so adding a pack later is a data edit, not a code change — no
per-country code paths.

Key refinement: region filters the *grid*, never the *catalog*. Other regions' entries
stay searchable, because an Australian living in London still needs Stan findable.

## 2026-07-27 — Is an empty Home screen really a good idea? Maybe seed a 'Netflix' with a demo chip?

**A:** Right about the UX, and the original "no demo data" answer over-applied the
CloudKit rule. That rule bans *inserting* demo rows into a synced store (they sync to
every device and the user has to delete them) — it doesn't ban *rendering* a sample.

So: yes to the visual, no to the row. Build the `SubscriptionItem` in memory, render it
dimmed with a `SAMPLE` chip, never insert it into `modelContext`. Tapping it opens the
add flow prefilled with Netflix, so it's a functional shortcut rather than decoration,
and it vanishes as soon as a real item exists — no delete, no sync, no residue.
`PreviewData.swift` already constructs exactly these throwaway items.

The distinction, now written into `_shared/cloudkit-swiftdata.md`: the hazard is
persistence, not pixels.

## 2026-07-27 — Go ahead and spec the icon sourcing (iTunes scrape vs. manual), for US/AU/UK plus a couple more markets at your discretion.

**A:** Wrote and tested `bin/fetch-onboarding-icons.py` — a one-time dev script (`curl` +
macOS's built-in `sips`, no PyPI dependency) that reads `AppCatalog.json`, fetches each
entry's `artworkUrl512` from the iTunes Lookup API, and bakes it into a Single Scale
imageset (one 180×180 PNG per icon — sharp everywhere, since SwiftUI only ever downsamples
it, never upsamples). Measured against a real Netflix fetch during spec-writing: 8.5 KB per
icon, so ~200–300 KB for all 26 core icons, not the ~650 KB ballpark floated earlier.

Added Canada and New Zealand as the extra markets (Crave/CBC Gem/TSN+ for CA, Neon/
ThreeNow/Sky Sport Now for NZ) — natural fits given the AU/NZ/UK/CA streaming overlap. Five
region packs at launch: AU, GB, CA, NZ, US.

Also found real cruft while checking for a home for the new icons: a **dead, already-
committed** asset-catalog folder from an earlier abandoned attempt, with zero-width-space
characters baked into every path segment (invisible in `ls`, only visible via `git
ls-tree`'s raw bytes) — plus a second copy of it accidentally dragged into the app icon
set. Neither is referenced anywhere in Swift. Documented as a required cleanup step in R4
rather than silently deleting it mid-spec.
