import SwiftUI
import SwiftData

struct RemindersEditorView: View {
    @Binding var notifications: [NotificationRule]

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
                ReminderRuleRow(rule: notifications[index]) {
                    let i = index
                    withAnimation { _ = notifications.remove(at: i) }
                } onUpdate: { updated in
                    notifications[index] = updated
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                GlassPresetChip(label: "1 day",    icon: "bell")        { addRule(.daysBefore,   1) }
                GlassPresetChip(label: "3 days",   icon: "bell")        { addRule(.daysBefore,   3) }
                GlassPresetChip(label: "1 week",   icon: "bell")        { addRule(.weeksBefore,  1) }
                GlassPresetChip(label: "1 month",  icon: "bell")        { addRule(.monthsBefore, 1) }
                GlassPresetChip(label: "3 months", icon: "bell")        { addRule(.monthsBefore, 3) }
                GlassPresetChip(label: "6 months", icon: "bell")        { addRule(.monthsBefore, 6) }
                GlassPresetChip(label: "+ Custom", icon: "slider.horizontal.3", isAccent: true) { addRule(.daysBefore, 7) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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
        guard !notifications.contains(where: { $0.offsetType == type && $0.value == value }) else { return }
        withAnimation {
            notifications.append(NotificationRule(offsetType: type, value: value))
        }
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
        onUpdate(NotificationRule(id: rule.id, offsetType: offsetType, value: value, isCritical: isCritical))
    }
}

// MARK: - Glass Preset Chip

struct GlassPresetChip: View {
    let label: String
    var icon: String = "bell"
    var isAccent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isAccent ? Color.blue : Color.primary.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(
                isAccent
                    ? .regular.tint(.blue).interactive()
                    : .regular.interactive(),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}
