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
         onDelete: @escaping () -> Void,
         onUpdate: @escaping (NotificationRuleDraft) -> Void) {
        self.rule = rule
        self.baseDate = baseDate
        self.itemHour = itemHour
        self.itemMinute = itemMinute
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
        SwipeActionsContainer {
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

struct SwipeActionsContainer<Content: View>: View {
    let actions: () -> [SwipeAction]
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    private let actionWidth: CGFloat = 52

    var body: some View {
        let list = actions()
        let panelWidth = CGFloat(list.count) * actionWidth

        ZStack {
            // Both panels are laid out at all times (left-aligned + right-aligned),
            // but must be explicitly hidden at rest — relying on `content()` being
            // fully opaque to occlude them doesn't hold whenever content has any
            // transparent gap (a Spacer, horizontal padding), which let a panel's
            // solid-tint icon "ghost" through behind the row text (Deon, 2026-07-27
            // R4 test feedback — this had regressed since the earlier
            // "ghost/overlapping delete button" fix).
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
                            offset = max(min(value.translation.width, panelWidth), -panelWidth)
                        }
                        .onEnded { value in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                if value.translation.width > panelWidth / 3 {
                                    offset = panelWidth
                                } else if value.translation.width < -panelWidth / 3 {
                                    offset = -panelWidth
                                } else {
                                    offset = 0
                                }
                            }
                        }
                )
                .onTapGesture {
                    guard offset != 0 else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
                }
        }
        .clipped()
    }

    private func panel(_ list: [SwipeAction]) -> some View {
        HStack(spacing: 0) {
            ForEach(list) { action in
                Button {
                    action.handler()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
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
