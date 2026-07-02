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

    init(id: UUID = UUID(),
         offsetType: NotificationOffsetType = .daysBefore,
         value: Int = 1,
         isCritical: Bool = false,
         customDate: Date? = nil) {
        self.id = id
        self.offsetType = offsetType
        self.value = value
        self.isCritical = isCritical
        self.customDate = customDate
    }

    init(rule: NotificationRule) {
        self.id = rule.id
        self.offsetType = rule.offsetType
        self.value = rule.value
        self.isCritical = false
        self.customDate = rule.customDate
    }

    /// Builds a fresh managed rule from this draft (used when creating a new item).
    func makeRule() -> NotificationRule {
        NotificationRule(id: id, offsetType: offsetType, value: value, isCritical: false, customDate: customDate)
    }
}

struct RemindersEditorView: View {
    @Binding var notifications: [NotificationRuleDraft]
    let baseDate: Date

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
                ReminderRuleRow(rule: notifications[index], baseDate: baseDate) {
                    let i = index
                    withAnimation { _ = notifications.remove(at: i) }
                } onUpdate: { updated in
                    applyUpdate(updated, at: index)
                }
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
    let onDelete: () -> Void
    let onUpdate: (NotificationRuleDraft) -> Void

    @State private var offsetType: NotificationOffsetType
    @State private var value: Int
    @State private var customDate: Date

    init(rule: NotificationRuleDraft,
         baseDate: Date,
         onDelete: @escaping () -> Void,
         onUpdate: @escaping (NotificationRuleDraft) -> Void) {
        self.rule = rule
        self.baseDate = baseDate
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        _offsetType = State(initialValue: rule.offsetType)
        _value = State(initialValue: rule.value)
        _customDate = State(initialValue: rule.customDate ?? baseDate)
    }

    var body: some View {
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
            deleteButton
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        onUpdate(NotificationRuleDraft(id: rule.id, offsetType: offsetType, value: value, isCritical: false, customDate: date))
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
