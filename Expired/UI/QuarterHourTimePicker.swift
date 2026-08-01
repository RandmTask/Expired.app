import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A time-only picker snapping to 15-minute intervals.
///
/// SwiftUI's `DatePicker` exposes no `minuteInterval`, so on iOS this wraps `UIDatePicker`
/// (`.time`, `minuteInterval = 15`). On macOS `UIViewRepresentable` doesn't apply, so we keep
/// the native SwiftUI `.field` picker and snap the bound value to the nearest 15 minutes in the
/// setter — a deliberate platform limitation (the wheel itself allows any minute, the value is
/// corrected on change).
struct QuarterHourTimePicker: View {
    @Binding var date: Date

    var body: some View {
#if os(iOS)
        QuarterHourTimePickerRepresentable(date: $date)
            .fixedSize()
#else
        DatePicker(
            "",
            selection: Binding(
                get: { date },
                set: { date = Self.snap($0) }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .datePickerStyle(.field)
#endif
    }

    /// Snaps a date's minute to the nearest quarter hour.
    static func snap(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let minute = comps.minute ?? 0
        let snapped = Int((Double(minute) / 15.0).rounded()) * 15
        let hourAdd = snapped / 60
        let finalMinute = snapped % 60
        return cal.date(bySettingHour: (comps.hour ?? 9) + hourAdd, minute: finalMinute, second: 0, of: date) ?? date
    }
}

/// A pill-shaped time chip that opens a compact popover containing a `QuarterHourTimePicker`.
/// Use in place of an inline wheel picker wherever the picker would otherwise dominate the row.
struct TimeChip: View {
    @Binding var date: Date
    @State private var showPopover = false

    var body: some View {
        Button {
            Haptics.fire(.selectionChanged)
            showPopover = true
        } label: {
            Text(date.formatted(.dateTime.hour().minute()))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            QuarterHourTimePicker(date: $date)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }
}

#if os(iOS)
private struct QuarterHourTimePickerRepresentable: UIViewRepresentable {
    @Binding var date: Date

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.minuteInterval = 15
        picker.preferredDatePickerStyle = .wheels
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        if !Calendar.current.isDate(picker.date, equalTo: date, toGranularity: .minute) {
            picker.date = date
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    final class Coordinator: NSObject {
        let date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ picker: UIDatePicker) { date.wrappedValue = picker.date }
    }
}
#endif
