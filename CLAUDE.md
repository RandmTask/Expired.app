# CLAUDE.md — Expired App

This file serves dual purposes:
1. **Generic guide** for any iOS/macOS multiplatform SwiftUI project
2. **Project-specific** repository of lessons learned, design preferences, and anti-patterns discovered during this development cycle

---

## Project Vision & Technical Stack

**Expired** is a subscription and document expiry tracker. Users add items (streaming services, insurance, gym memberships, passports) and receive reminders before they expire. The app is clean, calm, and uncluttered — it does one job well.

### Stack
- **Language**: Swift 6 (strict concurrency)
- **UI**: SwiftUI — no UIKit/AppKit unless absolutely forced
- **Data**: SwiftData (replaces Core Data) with CloudKit automatic sync
- **Platforms**: iOS 26+, macOS 26+ — single multiplatform target
- **Notifications**: `UNUserNotificationCenter` via `NotificationManager`
- **Cross-device settings**: `NSUbiquitousKeyValueStore` (iCloud KV store)
- **Icons**: `FaviconFetcher` — 5-strategy cascading favicon/logo fetcher
- **Design language**: iOS 26 Liquid Glass (`glassEffect(in: .rect(cornerRadius: N))`)

### Data Model (`SubscriptionItem`)
SwiftData model with CloudKit-safe raw String storage for enums:
- `name`, `website`, `notes`, `accountEmail`, `accountUsername`, `accountPassword`
- `costAmount: Double`, `currencyCode: String`, `billingCycle: String` (raw BillingCycle enum)
- `category: String` (raw SubscriptionCategory enum), `customCategory: String?`
- `startDate: Date?`, `renewalDate: Date?`
- `status: String` (raw SubscriptionStatus: active/trial/cancelled)
- `iconData: Data?` — `@Attribute(.externalStorage)` for CloudKit binary compat
- `iconSource: String` (raw IconSource: favicon/appBundle/customImage/default)
- `isArchived: Bool`

**Rule**: All enum fields stored as raw `String` for CloudKit compatibility. Never use `@Attribute(.transformable)` or store enum types directly.

---

## Project Architecture

```
Expired/
├── Expired.xcodeproj
└── Expired/
    ├── ExpiredApp.swift          # App entry, @ModelContainer setup
    ├── ContentView.swift         # TabView, ArchiveView, CategoriesView, SettingsView
    ├── Models/
    │   └── SubscriptionItem.swift
    ├── UI/
    │   ├── HomeView.swift        # Main list, sort/filter, GlassSectionView
    │   ├── AddEditSubscriptionView.swift  # Add/edit sheet, AccountField
    │   ├── SubscriptionRowView.swift      # List row card
    │   ├── TimelineView.swift
    │   └── InsightsView.swift
    ├── Services/
    │   ├── NotificationManager.swift
    │   ├── FaviconFetcher.swift
    │   └── CloudKitSyncMonitor.swift
    └── Utilities/
        ├── CurrencyInfo.swift
        └── Extensions/
```

---

## Build & Workflow Commands

```bash
# Build (use Xcode MCP tool, not CLI)
# In Claude sessions: use BuildProject MCP tool

# Git workflow
git add -A                          # Stage all changes
git commit -m "Detailed message"    # Commit with changelog
git push origin main                # Push to GitHub

# Terminology: staging → committing → pushing to GitHub
```

**Commit message style**: Multi-line, enumerate changes numerically, describe behaviour not just "fixed X". Example from this project:

```
UI polish: liquid glass aesthetics, settings alignment, nav fixes

1. CategoriesView — full liquid glass redesign
2. ArchiveView — section header with item count
3. Settings — macSettingsLabel helper, iCloud toggle green
4. HomeView — suppressed sort/filter menu chevrons on macOS
5. Settings navigation — resets to root on tab leave/retap
6. Reminder picker — 15-minute intervals
```

---

## The Parity Protocol: iOS/macOS Alignment

This is the most critical section. macOS and iOS SwiftUI rendering differ significantly. **Always build and visually verify on both platforms.** Do not assume iOS code works on macOS.

### The Core Rule
**Write platform-specific implementations when behaviour diverges. Never try to force a single implementation to work on both platforms when it looks wrong on one.**

```swift
// Pattern: platform-split body
var body: some View {
    #if os(macOS)
    macBody
    #else
    iosBody
    #endif
}
```

### Known Divergences and Their Fixes

#### 1. `Menu` in toolbars shows a dropdown `⌄` chevron on macOS
**Problem**: Any `Menu` used as a toolbar button shows a chevron indicator on macOS.
**Fix**: Always add `.menuIndicator(.hidden)` inside `#if os(macOS)`.

```swift
Menu { /* ... */ } label: { Image(systemName: "arrow.up.arrow.down") }
#if os(macOS)
    .menuIndicator(.hidden)
#endif
```

#### 2. `Menu` with `.menuStyle(.borderlessButton)` adds stepper `⌃⌄` chrome
**Problem**: `.menuStyle(.borderlessButton)` on macOS renders stepper arrows on the left AND a chevron on the right — double chrome.
**Fix**: Add `.menuIndicator(.hidden)` on macOS after `.menuStyle(.borderlessButton)`.

```swift
.menuStyle(.borderlessButton)
#if os(macOS)
.menuIndicator(.hidden)
#endif
```

#### 3. `Label` uses variable-width icons — text never aligns
**Problem**: `Label("Netflix", systemImage: "tv")` puts text at a different x-position than `Label("Other", systemImage: "ellipsis.circle")` because icons have different widths.
**Fix**: Always replace `Label` with explicit `Image + Text` using a fixed-width frame.

```swift
// Instead of:
Label(cat.displayName, systemImage: cat.icon)

// Use:
HStack(spacing: 12) {
    Image(systemName: cat.icon)
        .font(.system(size: 16))
        .frame(width: 22, alignment: .center)  // Fixed slot = aligned text
    Text(cat.displayName)
        .font(.system(size: 16))
}
```

Apply this everywhere: settings rows, category rows, custom list rows, form fields.

#### 4. `Toggle` renders as a checkbox on macOS
**Problem**: Default Toggle on macOS is a checkbox, not a switch.
**Fix**: Always add `.toggleStyle(.switch)` when you want iOS-style toggle.

```swift
Toggle("iCloud Sync", isOn: $iCloudSyncEnabled)
    .toggleStyle(.switch)
    .tint(.green)  // Match iOS green color
```

#### 5. `DatePicker` row is too tall on macOS
**Problem**: Default DatePicker renders as a large calendar popup on macOS.
**Fix**: Use `.datePickerStyle(.field)` on macOS.

```swift
DatePicker("", selection: $date, displayedComponents: .date)
#if os(macOS)
    .datePickerStyle(.field)
#endif
```

#### 6. `EditButton` unavailable on macOS
**Problem**: `EditButton()` is iOS-only.
**Fix**: Wrap in `#if os(iOS)`.

#### 7. Settings UI needs full platform split
**Problem**: iOS settings with `Form` + `Section` looks completely wrong on macOS. macOS needs a sidebar-style layout with card sections.
**Fix**: Create separate `macSettingsBody` and `iosSettingsBody` computed properties, switch with `#if os(macOS)`.

macOS settings pattern:
```swift
private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        VStack(spacing: 0) { content() }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
}

@ViewBuilder
private func macSettingsLabel(_ title: String, icon: String) -> some View {
    HStack(spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 15))
            .frame(width: 20, alignment: .center)
            .foregroundStyle(.secondary)
        Text(title)
            .font(.system(size: 15))
            .foregroundStyle(.primary)
    }
}
```

#### 8. Appearance `Menu` in settings adds chrome on macOS
**Fix**: `.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()`

#### 9. `List` inside `ScrollView` always collapses to zero height
**Problem**: `List` is UITableView-backed. It reports zero intrinsic content size inside a `ScrollView`. Neither `.fixedSize(horizontal: false, vertical: true)` nor a fixed `.frame(height: N)` reliably solves this. The list renders blank or cuts off content.
**Root cause**: UITableView and UIScrollView both want to own vertical scrolling. Nesting them fights over ownership.
**Fix**: Make `List` the root scroll container. Never nest `List` inside `ScrollView`.

```swift
// WRONG — List collapses inside ScrollView
ScrollView {
    List { ForEach(...) { row } }
        .fixedSize(horizontal: false, vertical: true)  // ← does NOT work
}

// CORRECT — List is the root container
List {
    Section { ForEach(...) { row } }
    Section { addButton }  // "Add" button goes in its own Section at the bottom
}
.listStyle(.insetGrouped)
.scrollContentBackground(.hidden)
```

If the design needs a custom glass layout (not a standard list), use `ScrollView + VStack` instead — but that means no swipe actions and no native drag-to-reorder.

#### 9b. `List` row height is doubled when manual padding is added
**Problem**: `List` (.insetGrouped) already adds standard row insets. Adding `.padding(.horizontal, 16).padding(.vertical, 12)` on top makes rows ~2× too tall.
**Fix**: Remove all manual padding from row content when inside a native `List`. Let the system provide insets.

#### 9c. `.listRowSeparator(.hidden)` must go inside `ForEach`, not after it
**Problem**: Chaining `.listRowSeparator(.hidden)` after `ForEach { }.onMove { }` breaks — the result type changes and `.onMove` is no longer available.
**Fix**: Wrap row content in `Group {}` inside the `ForEach` and apply `.listRowSeparator(.hidden)` to the `Group`.

```swift
ForEach(items) { item in
    Group {
        rowView(item)
    }
    .listRowSeparator(.hidden)  // ← on the Group, inside ForEach
}
.onMove { ... }   // ← on ForEach, not on the row
.onDelete { ... }
```

#### 10. Pull-to-refresh not available on macOS
**Fix**: Add a "Sync Now" button in macOS toolbar. Wrap `refreshable` in `#if os(iOS)`.

---

## UI/UX Design System

### Liquid Glass (iOS 26)
The primary design language is iOS 26 Liquid Glass. Use it consistently.

```swift
// Card container
VStack(spacing: 0) { content }
    .glassEffect(in: .rect(cornerRadius: 20))

// Form card (reusable)
struct FormCard<Content: View>: View { ... }

// Glass section with pill header
private func categoriesSection<Content: View>(title: String, icon: String,
    @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        // Pill header
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.6)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .padding(.horizontal, 4)

        // Glass card
        VStack(spacing: 0) { content() }
            .glassEffect(in: .rect(cornerRadius: 20))
    }
}
```

### Background
```swift
// Adaptive background for all views
private var groupedBackground: Color {
    #if os(macOS)
    Color(nsColor: .windowBackgroundColor)
    #else
    Color(.systemGroupedBackground)
    #endif
}
```

### Reusable Components
- `FormCard` — glass card wrapper
- `FormRow` — labeled row inside a card
- `FormDivider` — subtle separator between rows
- `GlassSectionView` — home view section with pill header
- `AccountField` — smart text input with `Menu`-based suggestions
- `SubscriptionRowView` — list row card with icon, name, cost, date

### Typography Conventions
- Body: `.system(size: 16)`
- Labels: `.system(size: 15)` with `.secondary` foreground
- Section headers (pill): `.system(size: 11, weight: .bold)` + `.tracking(0.6)` + `.uppercased()`
- Small metadata: `.system(size: 12, weight: .semibold)` + `.secondary` + `.tracking(0.4)`

### Color Conventions
- iCloud/sync-related toggles: `.tint(.green)`
- Destructive actions: `.red`
- Action/refresh buttons: `.blue`
- Filter active state: `.blue` fill icon
- Disabled/loading state: `.secondary`

### Spacing Conventions
- Card internal padding: `.padding(.horizontal, 16).padding(.vertical, 14)` per row
- Between sections: `spacing: 24` in outer VStack
- Between cards: `spacing: 8` in section VStack
- List row insets: `EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)`

---

## Design Preferences (Owner-Specific)

These are the design preferences discovered through this development cycle. When in doubt, follow these:

1. **Minimal and calm** — No busy borders, no heavy shadows, no decoration for decoration's sake.
2. **Consistent alignment** — Text must start at the same horizontal position across all rows. Icons are decorative; text is primary. Use fixed-width icon frames everywhere.
3. **Platform feel first** — The app should feel native on each platform. Don't force iOS patterns onto macOS.
4. **Green for sync** — iCloud/sync indicators should be green (`.tint(.green)`) on all platforms.
5. **Blue for actions** — Non-destructive action buttons (Refresh Icons, etc.) should be `.blue`.
6. **Concise labels** — Prefer `"Currency"` over `"Base Currency"`, `"Reminder"` over `"Reminder Time"`, `"Refresh Icons"` over `"Refresh All Icons"`. Remove redundant words.
7. **No chevrons on icon-only buttons** — Suppress `.menuIndicator(.hidden)` always when the button is icon-only.
8. **Section counts** — List sections should show item counts in a subtle header (`"3 items"` in `.secondary` small caps style).
9. **15-minute intervals** — Time pickers should snap to quarter-hours, not every minute.
10. **Settings navigation resets** — Navigating away from Settings (or re-tapping the tab) must return to the root settings page.
11. **Remove "Other" catch-alls** — Don't show "Other" or "Uncategorised" categories/sections unless the count is nonzero. Hide empty states.
12. **Swipe actions are platform-correct** — iOS swipe-to-archive and swipe-to-delete are standard. Don't fight the system rendering of swipe action buttons.

---

## Component Recipes

### AccountField (smart input with suggestions)
```swift
// VStack(alignment: .leading) + HStack(alignment: .center) is critical on macOS
// Without these, labels center-align horizontally
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center) {
            Text(label).font(.system(size: 16)).fixedSize()
            // ... Menu or TextField ...
        }
    }
}
```

### Settings Navigation Reset (TabView)
```swift
// ContentView — custom Binding resets settingsNavID on leave or retap
@State private var selectedTab = 0
@State private var settingsNavID = UUID()

var body: some View {
    TabView(selection: Binding(
        get: { selectedTab },
        set: { newTab in
            if selectedTab == 3 && newTab != 3 {
                settingsNavID = UUID()  // Leaving settings → reset
            } else if newTab == 3 && selectedTab == 3 {
                settingsNavID = UUID()  // Retapping settings → reset
            }
            selectedTab = newTab
        }
    )) {
        // ...
        Tab("Settings", systemImage: "gear", value: 3) {
            SettingsView().id(settingsNavID)  // .id forces recreation
        }
    }
}
```

### 15-Minute Time Snapping
```swift
private func saveNotificationTime(_ date: Date) {
    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
    let hour   = comps.hour   ?? 9
    let rawMin = comps.minute ?? 0
    let minute = (rawMin / 15) * 15  // Snap to nearest quarter-hour
    // ... save to NSUbiquitousKeyValueStore ...
}
```

### Cross-Device Settings Sync
```swift
// NSUbiquitousKeyValueStore for settings that should sync across devices
// (not suitable for large data — use CloudKit/SwiftData for that)
let kv = NSUbiquitousKeyValueStore.default
kv.set(Int64(hour), forKey: "notificationHour")
kv.synchronize()

// Required entitlement:
// com.apple.developer.ubiquity-kvstore-identifier = $(TeamIdentifierPrefix)com.swiftstudio.Expired
```

### FaviconFetcher Strategy Order
1. Google favicon service (256px) — fast, reliable
2. icon.horse — high-quality logos
3. Apple touch icon (180×180) — direct from site
4. DuckDuckGo favicon service — reliable fallback
5. Direct `/favicon.ico` — last resort

Special case: `apps.apple.com` URLs → iTunes API → `artworkUrl512`

---

## Persistent Ordering: Interleaved Lists

When users can drag-reorder a list that mixes two data sources (e.g. built-in enum cases + user-created items), saving each source separately and rejoining them on load always destroys the interleaved position.

### The Problem
```swift
// WRONG — saves two arrays separately
func save() {
    saveBuiltInOrder(items.compactMap { if case .builtIn(let c) = $0 { return c.rawValue } else { return nil } })
    saveCustomItems(items.compactMap { if case .custom(let c) = $0 { return c } else { return nil } })
}

// WRONG — always reconstructs as builtIns + customs, customs always go to the bottom
func load() -> [Item] {
    return loadBuiltIns() + loadCustoms()
}
```

### The Fix: Save a Unified Tag Sequence
Save the full interleaved order as a single array of tagged strings to UserDefaults. On load, reconstruct from tags first, then append anything new.

```swift
// Key in UserDefaults: ["builtin:streaming", "custom:uuid-xxxx", "builtin:gaming", ...]
static func saveUnifiedOrder(_ tags: [String]) {
    UserDefaults.standard.set(tags, forKey: "unifiedCategoryOrder")
}

func saveUnified() {
    let tags: [String] = items.map {
        switch $0 {
        case .builtIn(let c): return "builtin:\(c.rawValue)"
        case .custom(let c):  return "custom:\(c.id.uuidString)"
        }
    }
    saveUnifiedOrder(tags)
    // Also update the individual stores (used elsewhere)
    saveBuiltInOrder(...)
    saveCustomItems(...)
}

func buildUnified() -> [Item] {
    guard let tags = loadUnifiedOrder(), !tags.isEmpty else {
        return loadBuiltIns() + loadCustoms()  // first-launch fallback only
    }
    var result: [Item] = tags.compactMap { tag -> Item? in
        if tag.hasPrefix("builtin:") { return builtInMap[String(tag.dropFirst(8))].map { .builtIn($0) } }
        if tag.hasPrefix("custom:")  { return customMap[String(tag.dropFirst(7))].map { .custom($0) } }
        return nil
    }
    // Append any new items not yet in the saved order
    let seenBuiltIns = Set(result.compactMap { if case .builtIn(let c) = $0 { return c.rawValue } else { return nil } })
    let seenCustoms  = Set(result.compactMap { if case .custom(let c) = $0 { return c.id.uuidString } else { return nil } })
    for c in allBuiltIns where !seenBuiltIns.contains(c.rawValue) { result.append(.builtIn(c)) }
    for c in allCustoms  where !seenCustoms.contains(c.id.uuidString) { result.append(.custom(c)) }
    return result
}
```

### Key Rules
- **One source of truth for order** — the unified tag array. Not two separate arrays.
- **Save the unified tags every time the user reorders** — in `.onMove`, on edit/add confirm, on delete.
- **All consumers of the order** (add/edit pickers, home category sort, settings list) must all read from the same unified order function. If any consumer has its own separate data source, it will show a different order.
- **Append-new logic is required** — new built-in enum cases added in a future app update won't be in old users' saved tag arrays. Always append unseen items at the end.

### Diagnosing Order Bugs
Before writing any UI for a reorderable list, answer these 3 questions:
1. Where is the order saved? (Which UserDefaults key?)
2. Where is it loaded? (Which function reconstructs the list?)
3. Do save and load use the same data shape? (If save splits into two arrays but load rejoins them, the interleaved position is lost.)

---

## Anti-Patterns & Gotchas

### SwiftData / CloudKit
- **Never** use `@Attribute(.transformable)` — breaks CloudKit sync
- **Never** store enum types directly — always store `rawValue: String`
- **Never** use `@Relationship` with delete rules that CloudKit can't handle
- `@Attribute(.externalStorage)` for binary data (images) — required for CloudKit binary compat
- CloudKit schema is immutable after first sync — plan your model carefully before shipping

### SwiftUI Multiplatform
- **Never** assume iOS SwiftUI code looks correct on macOS without testing
- **Never** use `List` for custom-styled card layouts — use `ScrollView + VStack`
- **Never** use `EditButton()` without `#if os(iOS)` guard
- **Never** use `Label` in custom list rows — always `Image.frame(width: N) + Text`
- **Always** test toolbar menus on macOS for unexpected chrome
- **Always** check Toggle renders as switch, not checkbox, on macOS

### Notifications
- Request permission before scheduling — never schedule silently
- Always call `removePendingNotificationRequests` before rescheduling
- Test on physical device — simulator notification delivery is unreliable

### Performance
- `@Attribute(.externalStorage)` prevents large `Data` from bloating the SwiftData store
- Favicon fetch is network-bound — always `async`, never block main actor
- `FaviconFetcher.isImage(_:)` validates magic bytes — prevents storing HTML error pages as icons

### Git
- Stage with `git add -A`, commit with `git commit -m "..."`, push with `git push origin main`
- This is: staging → committing → pushing (in that order)
- Commit messages should be descriptive changelogs, not just "fixed stuff"

---

## Lessons Learned: iOS/macOS Parity

The biggest source of rework in this project was the gap between iOS and macOS appearance. Here's what was learned and what to do differently next time:

### Why macOS diverged
1. Development happened primarily in iOS Simulator — macOS was only checked later
2. SwiftUI's cross-platform promise is aspirational, not literal — rendering differs significantly
3. Components like `Label`, `Toggle`, `DatePicker`, `Menu` behave fundamentally differently

### What required multiple back-and-forth iterations
1. `Label` alignment — took 3 iterations (Label → frame attempt → fixed-width Image+Text)
2. `Menu` chrome — `.menuStyle(.borderlessButton)` + `.menuIndicator(.hidden)` combination
3. `AccountField` alignment — `VStack`/`HStack` alignment params were the root cause
4. Settings layout — required completely separate macOS implementation
5. iCloud toggle — had to add `.toggleStyle(.switch).tint(.green)` separately

### How to avoid this next time
1. **Check macOS at the same time as iOS** — every UI change, open both simulators
2. **Use `#if os(macOS)` proactively** — don't wait for bugs to appear
3. **Test all `Menu` usages on macOS immediately** — they always need `.menuIndicator(.hidden)`
4. **Use fixed-width icon frames from day one** — `Label` will always misalign on custom layouts
5. **Split Settings body early** — macOS and iOS settings need fundamentally different layouts

### The Parity Checklist (run after every UI change)
- [ ] Does every `Menu` in the toolbar have `.menuIndicator(.hidden)` on macOS?
- [ ] Does every `Toggle` have `.toggleStyle(.switch)`?
- [ ] Does every `DatePicker` have `.datePickerStyle(.field)` on macOS?
- [ ] Does every list row use `Image.frame(width: 22)` instead of `Label`?
- [ ] Is `EditButton` guarded with `#if os(iOS)`?
- [ ] Does the settings view have platform-split implementations?

---

## Debugging Protocol: How to Diagnose Issues Fast

When a UI feature isn't behaving correctly, follow this order. Skipping steps 1–2 and going straight to UI changes is the main cause of slow debugging cycles.

### Step 1: Trace the Data Round-Trip First
Before touching any view code, map the full save → persist → load → display cycle on paper:
- **Save**: What function writes the data? What format? What key?
- **Persist**: UserDefaults key, SwiftData store, or iCloud KV?
- **Load**: What function reads it back? Does it reconstruct the same shape that was saved?
- **Display**: Which views read from the loaded data? Are there multiple consumers that might be reading from different sources?

**If save and load don't use the same data shape, you found the bug. Fix the data layer first.**

### Step 2: Check All Consumers
For any shared data (category order, preferences, user-defined items), grep for every place that reads or writes it:
```bash
# Find every place that touches a given store
grep -r "UserCategoryStore\|unifiedCategoryOrder\|visibleCategories" --include="*.swift"
```
If the settings screen writes to one function but the add/edit picker reads from a different function, they will show different results. Every consumer must use the same single source of truth.

### Step 3: Isolate UI vs Data
Ask: "If I print the data array, is it correct?" before asking "Why does the view show the wrong thing?"
- Wrong data → fix the store/load logic
- Correct data → fix the view binding or `onAppear` call

### Step 4: Known SwiftUI Layout Suspects (check in this order)
When a list or scroll view is blank, cut off, or has wrong height:
1. **`List` inside `ScrollView`?** → Make `List` the root. This is almost always the cause.
2. **Manual padding inside a native `List`?** → Remove it. List provides its own insets.
3. **`onAppear` rebuilding state it shouldn't?** → Add `if state.isEmpty { rebuild() }` guard.
4. **`@State` initialised to `[]` but nothing populates it?** → Check `onAppear` fires.

### Step 5: When Stuck, Slow Down
If you've made 2+ attempts at the same bug without a fix, stop and:
1. Write out what you *know* is true (data shape, what's saved, what's loaded)
2. Write out what *must* be true for the bug to exist
3. Find the contradiction — that's the root cause

**Do not make more UI changes to mask a data bug.** A list that shows items in the wrong order has a persistence problem, not a display problem.

---

## Collaboration Style

### How to work with this codebase

1. **Read before modifying** — always read the file before making changes
2. **Make targeted changes** — don't refactor unrelated code while fixing a bug
3. **Build after every change** — use `BuildProject` MCP tool to verify
4. **Check both platforms** — iOS and macOS simulators after every UI change
5. **Commit working states** — commit after each logical batch of changes, not after every file

### Preferred communication style
- Concise technical descriptions
- No excessive praise or emotional validation
- Direct, honest assessment of trade-offs
- When something can't be done or is platform-constrained, say so clearly
- Don't propose changes you haven't read the code for

### How to interpret requests
- "Make it look like iOS" = implement `.toggleStyle(.switch)`, `.menuIndicator(.hidden)`, same colors
- "Align the text" = fixed-width icon frame pattern
- "Remove the glyph/arrow/chevron" = `.menuIndicator(.hidden)` on macOS
- "Go back to main settings" = UUID-based `.id()` reset pattern
- "Green/blue toggle" = `.tint(.green)` or `.tint(.blue)`
- "15-minute intervals" = `(rawMin / 15) * 15` snapping

---

## CloudKit Entitlements

Required entitlements in `Expired.entitlements`:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.swiftstudio.Expired</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>$(TeamIdentifierPrefix)com.swiftstudio.Expired</string>
<key>com.apple.developer.aps-environment</key>
<string>development</string>
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

The `ubiquity-kvstore-identifier` entitlement is required for `NSUbiquitousKeyValueStore` (used for cross-device notification time sync).

---

## Quick Reference: Key Modifiers

| Problem | Fix |
|---|---|
| macOS Menu shows `⌄` chevron | `.menuIndicator(.hidden)` in `#if os(macOS)` |
| macOS Toggle is a checkbox | `.toggleStyle(.switch)` |
| macOS DatePicker too large | `.datePickerStyle(.field)` in `#if os(macOS)` |
| Icon+text not aligned in rows | `Image.frame(width: 22, alignment: .center)` |
| Settings nav doesn't reset | UUID `.id()` + custom `TabView` Binding |
| Time picker shows every minute | `(rawMin / 15) * 15` snapping |
| Sync toggle wrong color | `.tint(.green)` |
| Action button wrong color | `.foregroundStyle(.blue)` |
| `List` won't accept custom glass | Switch to `ScrollView + VStack` |
| Appearance Menu shows chrome | `.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()` |
