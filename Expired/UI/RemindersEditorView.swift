import SwiftUI
import SwiftData

/// Pure value type backing the reminders editor. The form must never hold live
/// SwiftData `NotificationRule` models — those are reconciled into the relationship
/// only on Save, so cancelling can't mutate or churn managed objects.
struct NotificationRuleDraft: Identifiable, Equatable {
    var id: UUID
    var offsetType: NotificationOffsetType
    var value: Int
    var isCritical: Bool
    var customDate: Date?
    /// Per-rule fire time override. nil = inherit from the item's default / global.
    var fireHour: Int?
    var fireMinute: Int?

    init(id: UUID = UUID(),
         offsetType: NotificationOffsetType = .daysBefore,
         value: Int = 1,
         isCritical: Bool = false,
         customDate: Date? = nil,
         fireHour: Int? = nil,
         fireMinute: Int? = nil) {
        self.id = id
        self.offsetType = offsetType
        self.value = value
        self.isCritical = isCritical
        self.customDate = customDate
        self.fireHour = fireHour
        self.fireMinute = fireMinute
    }

    init(rule: NotificationRule) {
        self.id = rule.id
        self.offsetType = rule.offsetType
        self.value = rule.value
        self.isCritical = rule.isCritical
        self.customDate = rule.customDate
        self.fireHour = rule.fireHour
        self.fireMinute = rule.fireMinute
    }

    /// Builds a fresh managed rule from this draft (used when creating a new item).
    func makeRule() -> NotificationRule {
        NotificationRule(id: id, offsetType: offsetType, value: value, isCritical: isCritical,
                         customDate: customDate, fireHour: fireHour, fireMinute: fireMinute)
    }
}

struct RemindersEditorView: View {
    @Binding var notifications: [NotificationRuleDraft]
    let baseDate: Date
    /// The item's default reminder time (nil = inherit global) — used for the resolved-fire caption.
    var itemHour: Int? = nil
    var itemMinute: Int? = nil

    /// Which row currently has its swipe panel open — owned here, not per-row, so
    /// only one row can be open at a time (see `SwipeActionsContainer`).
    @State private var openRowID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            rulesList
            Divider().padding(.leading, 16)
            presetsRow
        }
    }

    @ViewBuilder
    private var rulesList: some View {
        if notifications.isEmpty {
            emptyLabel
        } else {
            ForEach(Array(notifications.enumerated()), id: \.element.id) { index, rule in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                ReminderRuleRow(
                    rule: rule,
                    baseDate: baseDate,
                    itemHour: itemHour,
                    itemMinute: itemMinute,
                    openRowID: $openRowID,
                    onDelete: {
                        withAnimation { notifications.removeAll { $0.id == rule.id } }
                    },
                    onUpdate: { updated in
                        applyUpdate(updated, ruleID: rule.id)
                    }
                )
            }
        }
    }

    private var emptyLabel: some View {
        Text("No reminders set")
            .font(.system(size: 14))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
    }

    private var presetsRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                GlassPresetChip(label: "On day", icon: "bell.badge") { addRule(.onDay, 0) }
                GlassPresetChip(label: "1 day",    icon: "bell")   { addRule(.daysBefore,   1) }
                GlassPresetChip(label: "3 days",   icon: "bell")   { addRule(.daysBefore,   3) }
                GlassPresetChip(label: "1 week",   icon: "bell")   { addRule(.weeksBefore,  1) }
            }
            HStack(spacing: 8) {
                GlassPresetChip(label: "1 month",  icon: "bell")   { addRule(.monthsBefore, 1) }
                GlassPresetChip(label: "3 months", icon: "bell")   { addRule(.monthsBefore, 3) }
                GlassPresetChip(label: "6 months", icon: "bell")   { addRule(.monthsBefore, 6) }
                GlassPresetChip(label: "Custom", icon: "calendar") { addExactDateRule() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func addRule(_ type: NotificationOffsetType, _ value: Int) {
        guard !notifications.contains(where: { $0.offsetType == type && $0.value == value && $0.customDate == nil }) else { return }
        withAnimation {
            notifications.append(NotificationRuleDraft(offsetType: type, value: value))
        }
    }

    private func addExactDateRule() {
        var candidate = baseDate
        let existingDates = notifications.compactMap { rule -> Date? in
            guard rule.offsetType == .exactDate else { return nil }
            return rule.customDate
        }
        while existingDates.contains(where: { Calendar.current.isDate($0, inSameDayAs: candidate) }) {
            candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        withAnimation {
            notifications.append(NotificationRuleDraft(offsetType: .exactDate, value: 0, customDate: candidate))
        }
    }

    private func applyUpdate(_ updated: NotificationRuleDraft, ruleID: UUID) {
        var updatedList = notifications
        guard let index = updatedList.firstIndex(where: { $0.id == ruleID }) else { return }
        let duplicateIndices = updatedList.indices.filter { i in
            i != index && isDuplicate(updated, updatedList[i])
        }
        for i in duplicateIndices.sorted(by: >) {
            updatedList.remove(at: i)
        }
        let adjustedIndex = index - duplicateIndices.filter { $0 < index }.count
        updatedList[adjustedIndex] = updated
        notifications = updatedList
    }

    private func isDuplicate(_ lhs: NotificationRuleDraft, _ rhs: NotificationRuleDraft) -> Bool {
        guard lhs.offsetType == rhs.offsetType else { return false }
        if lhs.offsetType == .exactDate {
            guard let leftDate = lhs.customDate, let rightDate = rhs.customDate else { return false }
            return Calendar.current.isDate(leftDate, inSameDayAs: rightDate)
        }
        return lhs.value == rhs.value
    }
}

// MARK: - Single Rule Row

struct ReminderRuleRow: View {
    let rule: NotificationRuleDraft
    let baseDate: Date
    let itemHour: Int?
    let itemMinute: Int?
    @Binding var openRowID: UUID?
    let onDelete: () -> Void
    let onUpdate: (NotificationRuleDraft) -> Void

    @State private var offsetType: NotificationOffsetType
    @State private var value: Int
    @State private var customDate: Date
    @State private var isCritical: Bool
    @State private var timeOverrideOn: Bool
    @State private var overrideTime: Date
    @State private var showTimePopover = false

    init(rule: NotificationRuleDraft,
         baseDate: Date,
         itemHour: Int?,
         itemMinute: Int?,
         openRowID: Binding<UUID?>,
         onDelete: @escaping () -> Void,
         onUpdate: @escaping (NotificationRuleDraft) -> Void) {
        self.rule = rule
        self.baseDate = baseDate
        self.itemHour = itemHour
        self.itemMinute = itemMinute
        self._openRowID = openRowID
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        _offsetType = State(initialValue: rule.offsetType)
        _value = State(initialValue: rule.value)
        _customDate = State(initialValue: rule.customDate ?? baseDate)
        _isCritical = State(initialValue: rule.isCritical)
        _timeOverrideOn = State(initialValue: rule.fireHour != nil && rule.fireMinute != nil)
        let h = rule.fireHour ?? 9
        let m = rule.fireMinute ?? 0
        _overrideTime = State(initialValue:
            Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date())
    }

    var body: some View {
        SwipeActionsContainer(rowID: rule.id, openRowID: $openRowID) {
            [
                SwipeAction(icon: isCritical ? "bell.badge.fill" : "bell", tint: isCritical ? .orange : .secondary) {
                    Haptics.fire(.selectionChanged)
                    isCritical.toggle()
                    propagate()
                },
                SwipeAction(icon: timeOverrideOn ? "clock.fill" : "clock", tint: timeOverrideOn ? .blue : .secondary) {
                    Haptics.fire(.selectionChanged)
                    showTimePopover = true
                },
                SwipeAction(icon: "trash", tint: .red) {
                    Haptics.fire(.error)
                    onDelete()
                }
            ]
        } content: {
            rowContent
        }
        .popover(isPresented: $showTimePopover) {
            timePopoverContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            if offsetType == .exactDate {
                datePicker
                    .fixedSize()
            } else if offsetType == .onDay {
                typePicker
                    .fixedSize()
            } else {
                valueStepper
                    .fixedSize()
                typePicker
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if timeOverrideOn {
                Text(overrideTime.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var timePopoverContent: some View {
        VStack(spacing: 12) {
            QuarterHourTimePicker(date: $overrideTime)
                .onChange(of: overrideTime) { _, _ in
                    timeOverrideOn = true
                    propagate()
                }
            if timeOverrideOn {
                Button("Use default time", role: .destructive) {
                    timeOverrideOn = false
                    propagate()
                    showTimePopover = false
                }
                .font(.system(size: 13))
            }
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }

    private var overrideMinutes: (hour: Int, minute: Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: overrideTime)
        return (c.hour ?? 9, c.minute ?? 0)
    }

    private var valueStepper: some View {
        HStack(spacing: 6) {
            Button {
                if value > 1 {
                    Haptics.fire(.selectionChanged)
                    value -= 1
                    propagate()
                }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text("\(value)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .frame(minWidth: 24)

            Button {
                if value < 365 {
                    Haptics.fire(.selectionChanged)
                    value += 1
                    propagate()
                }
            } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private var typePicker: some View {
        Picker("", selection: $offsetType) {
            ForEach(availableTypes, id: \.self) { type in
                Text(type.displayLabel(value: value)).tag(type)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: offsetType) { _, newValue in
            Haptics.fire(.selectionChanged)
            if newValue == .onDay {
                value = 0
            } else if newValue != .exactDate, value < 1 {
                value = 1
            }
            propagate()
        }
    }

    private var availableTypes: [NotificationOffsetType] {
        switch offsetType {
        case .daysBefore, .onDay, .daysAfter:
            return [.daysBefore, .onDay, .daysAfter]
        case .weeksBefore, .weeksAfter:
            return [.weeksBefore, .weeksAfter]
        case .monthsBefore, .monthsAfter:
            return [.monthsBefore, .monthsAfter]
        case .exactDate:
            return [.exactDate]
        }
    }

    private var datePicker: some View {
        HStack(spacing: 8) {
            Text("On")
                .font(.system(size: 16))
            DatePicker("", selection: $customDate, displayedComponents: .date)
                .labelsHidden()
#if os(macOS)
                .datePickerStyle(.field)
#endif
                .onChange(of: customDate) { _, _ in propagate() }
        }
    }

    private func propagate() {
        let date = offsetType == .exactDate ? customDate : nil
        let fh = timeOverrideOn ? overrideMinutes.hour : nil
        let fm = timeOverrideOn ? overrideMinutes.minute : nil
        onUpdate(NotificationRuleDraft(id: rule.id, offsetType: offsetType, value: value,
                                       isCritical: isCritical, customDate: date,
                                       fireHour: fh, fireMinute: fm))
    }
}

// MARK: - Glass Preset Chip

struct GlassPresetChip: View {
    let label: String
    var icon: String = "bell"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Swipe Actions

/// Hand-rolled swipe-to-reveal container. `ReminderRuleRow` lives in a `ScrollView`
/// (the edit form's outer container), not a `List`, so SwiftUI's native
/// `.swipeActions(edge:)` isn't available — see `_shared/gestures.md`'s documented
/// fallback for custom card lists. Reveals the same action panel from either edge so
/// all actions are reachable regardless of which way the user swipes.
struct SwipeAction: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let handler: () -> Void
}

/// Hand-rolled swipe-to-reveal actions.
///
/// **Why this isn't `List`'s native `.swipeActions`:** those only exist inside a
/// `List`, and this editor lives inside the Add/Edit form's `ScrollView` + glass
/// `FormCard` layout. A `List` nested in a `ScrollView` collapses to zero height
/// (see `CLAUDE.md` "Anti-Patterns", #9), so going native here would mean
/// restructuring the whole item editor away from its card design.
///
/// Because it's hand-rolled it must reimplement the parts of the native behaviour
/// people expect, which earlier revisions didn't:
/// - **Only one row open at a time** — the open row's identity lives in the parent
///   (`openRowID`), not in each row's own `@State`, so opening row B closes row A.
/// - **An open row can only be dragged closed, never flipped straight through to
///   the opposite side's panel** — the clamp below is asymmetric based on the
///   settled position. Without that, swiping back on an open row sailed past 0 and
///   opened the other panel, which read as "a left swipe triggered itself".
/// *(Both reported by Deon, 2026-07-28.)*
struct SwipeActionsContainer<Content: View>: View {
    let rowID: UUID
    @Binding var openRowID: UUID?
    let actions: () -> [SwipeAction]
    @ViewBuilder let content: () -> Content

    /// In-flight drag only. The settled position is derived from `openRowID`, so a
    /// row can't disagree with the parent about whether it's open.
    @State private var dragTranslation: CGFloat = 0
    @State private var settledOffset: CGFloat = 0
    private let actionWidth: CGFloat = 52

    private var isOpen: Bool { openRowID == rowID }

    var body: some View {
        let list = actions()
        let panelWidth = CGFloat(list.count) * actionWidth
        let offset = currentOffset(panelWidth: panelWidth)

        ZStack {
            // Panels are always laid out but must be explicitly hidden at rest —
            // relying on `content()` to occlude them fails wherever the row has a
            // transparent gap (a Spacer, padding), which let a panel's solid tint
            // "ghost" through behind the row text.
            HStack(spacing: 0) {
                panel(list)
                Spacer(minLength: 0)
            }
            .opacity(offset > 0 ? 1 : 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                panel(list)
            }
            .opacity(offset < 0 ? 1 : 0)

            content()
                .contentShape(Rectangle())
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            // Claim the "open row" slot as soon as a real drag starts,
                            // so any other open row closes before this one moves.
                            if !isOpen && openRowID != nil {
                                openRowID = nil
                                settledOffset = 0
                            }
                            dragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            let proposed = clamped(settledOffset + value.translation.width,
                                                   panelWidth: panelWidth)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                if proposed > panelWidth / 2 {
                                    settledOffset = panelWidth
                                    openRowID = rowID
                                } else if proposed < -panelWidth / 2 {
                                    settledOffset = -panelWidth
                                    openRowID = rowID
                                } else {
                                    settledOffset = 0
                                    if isOpen { openRowID = nil }
                                }
                                dragTranslation = 0
                            }
                        }
                )
                .onTapGesture {
                    guard settledOffset != 0 else { return }
                    close()
                }
        }
        .clipped()
        .onChange(of: openRowID) { _, newValue in
            // Another row took the slot — collapse without waiting for a gesture.
            if newValue != rowID && settledOffset != 0 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    settledOffset = 0
                    dragTranslation = 0
                }
            }
        }
    }

    private func currentOffset(panelWidth: CGFloat) -> CGFloat {
        clamped(settledOffset + dragTranslation, panelWidth: panelWidth)
    }

    /// Asymmetric on purpose: from closed you may open either side, but from an open
    /// side you may only travel back toward 0 — never through it into the opposite
    /// panel.
    private func clamped(_ value: CGFloat, panelWidth: CGFloat) -> CGFloat {
        if settledOffset > 0 {
            return min(max(value, 0), panelWidth)
        } else if settledOffset < 0 {
            return max(min(value, 0), -panelWidth)
        }
        return max(min(value, panelWidth), -panelWidth)
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            settledOffset = 0
            dragTranslation = 0
            if isOpen { openRowID = nil }
        }
    }

    private func panel(_ list: [SwipeAction]) -> some View {
        HStack(spacing: 0) {
            ForEach(list) { action in
                Button {
                    action.handler()
                    close()
                } label: {
                    Image(systemName: action.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: actionWidth, height: 44)
                }
                .buttonStyle(.plain)
                .background(action.tint)
            }
        }
    }
}
