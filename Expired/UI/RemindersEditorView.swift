import SwiftUI
import SwiftData

struct RemindersEditorView: View {
    @Binding var notifications: [NotificationRule]

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
            Text("No reminders set")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            ForEach(Array(notifications.enumerated()), id: \.element.id) { index, rule in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                ReminderRuleRow(rule: rule) {
                    withAnimation { notifications.remove(at: index) }
                } onUpdate: { updated in
                    notifications[index] = updated
                }
            }
        }
    }

    private var presetsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PresetChip(label: "1 day")   { addRule(.daysBefore,   1) }
                PresetChip(label: "3 days")  { addRule(.daysBefore,   3) }
                PresetChip(label: "1 week")  { addRule(.weeksBefore,  1) }
                PresetChip(label: "1 month") { addRule(.monthsBefore, 1) }
                PresetChip(label: "3 months"){ addRule(.monthsBefore, 3) }
                PresetChip(label: "6 months"){ addRule(.monthsBefore, 6) }
                PresetChip(label: "+ Custom", isCustom: true) { addRule(.daysBefore, 7) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func addRule(_ type: NotificationOffsetType, _ value: Int) {
        guard !notifications.contains(where: { $0.offsetType == type && $0.value == value }) else { return }
        withAnimation {
            notifications.append(NotificationRule(offsetType: type, value: value))
        }
    }
}

// MARK: - Single Rule Row

struct ReminderRuleRow: View {
    let rule: NotificationRule
    let onDelete: () -> Void
    let onUpdate: (NotificationRule) -> Void

    @State private var offsetType: NotificationOffsetType
    @State private var value: Int
    @State private var isCritical: Bool

    init(rule: NotificationRule,
         onDelete: @escaping () -> Void,
         onUpdate: @escaping (NotificationRule) -> Void) {
        self.rule = rule
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        _offsetType = State(initialValue: rule.offsetType)
        _value = State(initialValue: rule.value)
        _isCritical = State(initialValue: rule.isCritical)
    }

    var body: some View {
        HStack(spacing: 12) {
            valueStepper
            typePicker
            Spacer()
            criticalButton
            deleteButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            ForEach(NotificationOffsetType.allCases, id: \.self) {
                Text($0.rawValue).tag($0)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: offsetType) { _, _ in propagate() }
    }

    private var criticalButton: some View {
        Button {
            isCritical.toggle()
            propagate()
        } label: {
            Image(systemName: isCritical ? "exclamationmark.circle.fill" : "bell.fill")
                .foregroundStyle(isCritical ? Color.red : Color.secondary)
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
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
        onUpdate(NotificationRule(id: rule.id, offsetType: offsetType, value: value, isCritical: isCritical))
    }
}

// MARK: - Preset Chip

struct PresetChip: View {
    let label: String
    var isCustom: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isCustom ? Color.blue : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isCustom ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}
