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
