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
            ForEach(notifications.indices, id: \.self) { index in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                ReminderRuleRow(
                    rule: notifications[index],
                    baseDate: baseDate,
                    itemHour: itemHour,
                    itemMinute: itemMinute,
                    onDelete: {
                        let i = index
                        withAnimation { _ = notifications.remove(at: i) }
                    },
                    onUpdate: { updated in
                        applyUpdate(updated, at: index)
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
                GlassPresetChip(label: "1 day",    icon: "bell")   { addRule(.daysBefore,   1) }
                GlassPresetChip(label: "3 days",   icon: "bell")   { addRule(.daysBefore,   3) }
                GlassPresetChip(label: "1 week",   icon: "bell")   { addRule(.weeksBefore,  1) }
                GlassPresetChip(label: "1 month",  icon: "bell")   { addRule(.monthsBefore, 1) }
            }
            HStack(spacing: 8) {
                GlassPresetChip(label: "3 months", icon: "bell")   { addRule(.monthsBefore, 3) }
                GlassPresetChip(label: "6 months", icon: "bell")   { addRule(.monthsBefore, 6) }
                GlassPresetChip(label: "On day", icon: "bell.badge") { addRule(.onDay, 0) }
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

    private func applyUpdate(_ updated: NotificationRuleDraft, at index: Int) {
        var updatedList = notifications
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
        VStack(alignment: .leading, spacing: 4) {
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
                criticalButton
                    .fixedSize()
                timeOverrideButton
                    .fixedSize()
                deleteButton
                    .fixedSize()
            }
            if timeOverrideOn {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("At")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    QuarterHourTimePicker(date: $overrideTime)
                        .onChange(of: overrideTime) { _, _ in propagate() }
                    Spacer(minLength: 0)
                }
            }
            resolvedCaption
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var criticalButton: some View {
        Button {
            Haptics.fire(.selectionChanged)
            isCritical.toggle()
            propagate()
        } label: {
            Image(systemName: isCritical ? "bell.badge.fill" : "bell")
                .font(.system(size: 14))
                .foregroundStyle(isCritical ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(isCritical ? "Critical (bypasses quiet hours)" : "Standard")
    }

    private var timeOverrideButton: some View {
        Button {
            Haptics.fire(.selectionChanged)
            timeOverrideOn.toggle()
            propagate()
        } label: {
            Image(systemName: timeOverrideOn ? "clock.fill" : "clock")
                .font(.system(size: 14))
                .foregroundStyle(timeOverrideOn ? Color.blue : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Set a specific time for this reminder")
    }

    /// Live "→ Mon 3 Aug, 9:00 am" caption using the same resolution logic the scheduler uses.
    @ViewBuilder
    private var resolvedCaption: some View {
        if let fire = NotificationManager.resolvedFireMoment(
            occurrenceDate: baseDate,
            offsetType: offsetType,
            value: value,
            customDate: offsetType == .exactDate ? customDate : nil,
            isCritical: isCritical,
            ruleHour: timeOverrideOn ? overrideMinutes.hour : nil,
            ruleMinute: timeOverrideOn ? overrideMinutes.minute : nil,
            itemHour: itemHour,
            itemMinute: itemMinute
        ) {
            Text("→ \(fire.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
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

    private var deleteButton: some View {
        Button(role: .destructive) {
            Haptics.fire(.error)
            onDelete()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .foregroundStyle(Color.red.opacity(0.8))
        }
        .buttonStyle(.plain)
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
