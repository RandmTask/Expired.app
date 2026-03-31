import SwiftUI
import SwiftData

struct RemindersEditorView: View {
    @Binding var notifications: [NotificationRule]
    let baseDate: Date

    var body: some View {
        VStack(spacing: 0) {
            rulesList
            Divider().padding(.leading, 16)
            presetsRow
            criticalAlertDisclaimer
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
                GlassPresetChip(label: "Select date", icon: "calendar") { addExactDateRule() }
                // Invisible placeholder keeps the last row the same width as the first
                GlassPresetChip(label: "1 day", icon: "bell") {}
                    .hidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Shows a contextual disclaimer about critical alerts.
    /// On macOS: warns that critical alerts actually fire on the user's iPhone.
    /// On iOS: confirms that critical alerts bypass Do Not Disturb.
    @ViewBuilder
    private var criticalAlertDisclaimer: some View {
        let hasCritical = notifications.contains { $0.isCritical }
        if hasCritical {
            Divider().padding(.leading, 16)
            #if os(macOS)
            CriticalAlertBanner(
                icon: "iphone.radiowaves.left.and.right",
                color: .orange,
                message: "Critical alerts scheduled on Mac will fire on your iPhone (same iCloud account). This Mac will not play a sound."
            )
            #else
            CriticalAlertBanner(
                icon: "exclamationmark.circle.fill",
                color: .red,
                message: "Critical alerts will play a sound and bypass Do Not Disturb and Silent mode."
            )
            #endif
        }
    }

    private func addRule(_ type: NotificationOffsetType, _ value: Int) {
        guard !notifications.contains(where: { $0.offsetType == type && $0.value == value && $0.customDate == nil }) else { return }
        withAnimation {
            notifications.append(NotificationRule(offsetType: type, value: value))
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
            notifications.append(NotificationRule(offsetType: .exactDate, value: 0, customDate: candidate))
        }
    }

    private func applyUpdate(_ updated: NotificationRule, at index: Int) {
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

    private func isDuplicate(_ lhs: NotificationRule, _ rhs: NotificationRule) -> Bool {
        guard lhs.offsetType == rhs.offsetType else { return false }
        if lhs.offsetType == .exactDate {
            guard let leftDate = lhs.customDate, let rightDate = rhs.customDate else { return false }
            return Calendar.current.isDate(leftDate, inSameDayAs: rightDate)
        }
        return lhs.value == rhs.value
    }
}

// MARK: - Critical Alert Banner

private struct CriticalAlertBanner: View {
    let icon: String
    let color: Color
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Single Rule Row

struct ReminderRuleRow: View {
    let rule: NotificationRule
    let baseDate: Date
    let onDelete: () -> Void
    let onUpdate: (NotificationRule) -> Void

    @State private var offsetType: NotificationOffsetType
    @State private var value: Int
    @State private var isCritical: Bool
    @State private var customDate: Date

    init(rule: NotificationRule,
         baseDate: Date,
         onDelete: @escaping () -> Void,
         onUpdate: @escaping (NotificationRule) -> Void) {
        self.rule = rule
        self.baseDate = baseDate
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        _offsetType = State(initialValue: rule.offsetType)
        _value = State(initialValue: rule.value)
        _isCritical = State(initialValue: rule.isCritical)
        _customDate = State(initialValue: rule.customDate ?? baseDate)
    }

    var body: some View {
        HStack(spacing: 8) {
            if offsetType == .exactDate {
                datePicker
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
            deleteButton
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var valueStepper: some View {
        HStack(spacing: 6) {
            Button {
                if value > 1 { value -= 1; propagate() }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text("\(value)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .frame(minWidth: 24)

            Button {
                if value < 365 { value += 1; propagate() }
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
            if newValue != .exactDate, value < 1 {
                value = 1
            }
            propagate()
        }
    }

    private var availableTypes: [NotificationOffsetType] {
        switch offsetType {
        case .daysBefore, .daysAfter:
            return [.daysBefore, .daysAfter]
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
                .onChange(of: customDate) { _, _ in propagate() }
        }
    }

    private var criticalButton: some View {
        Button {
            isCritical.toggle()
            propagate()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCritical ? "exclamationmark.circle.fill" : "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                if isCritical {
                    Text("Critical")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(isCritical ? Color.white : Color.secondary)
            .padding(.horizontal, isCritical ? 8 : 6)
            .padding(.vertical, 5)
            .background(isCritical ? Color.red : Color.clear, in: Capsule())
            .overlay(
                Capsule().strokeBorder(isCritical ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.2), value: isCritical)
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .foregroundStyle(Color.red.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private func propagate() {
        let date = offsetType == .exactDate ? customDate : nil
        onUpdate(NotificationRule(id: rule.id, offsetType: offsetType, value: value, isCritical: isCritical, customDate: date))
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
