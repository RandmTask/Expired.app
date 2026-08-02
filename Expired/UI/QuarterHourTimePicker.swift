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
        TimeChip(date: $date)
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

/// A native, system-styled compact time control snapping to 15-minute intervals.
///
/// On iOS this wraps `UIDatePicker` with `preferredDatePickerStyle = .compact` — Apple's own
/// "small pill button that expands into a tightly-sized overlay" time picker (the same control
/// Reminders/Calendar use). It already renders with the standard system pill background and
/// standard system time-text size, so no custom font/pill styling is layered on top. On macOS
/// `.compact` isn't available, so this falls back to the existing `.field` style picker.
struct TimeChip: View {
    @Binding var date: Date
    var tint: Color = .primary

    var body: some View {
#if os(iOS)
        CompactStyleTimePickerRepresentable(
            date: Binding(get: { date }, set: { date = QuarterHourTimePicker.snap($0) }),
            tintColor: UIColor(tint)
        )
        .fixedSize(horizontal: true, vertical: true)
#else
        DatePicker(
            "",
            selection: Binding(
                get: { date },
                set: { date = QuarterHourTimePicker.snap($0) }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .datePickerStyle(.field)
        .tint(tint)
#endif
    }
}

#if os(iOS)
private struct CompactStyleTimePickerRepresentable: UIViewRepresentable {
    @Binding var date: Date
    var tintColor: UIColor

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.minuteInterval = 15
        picker.preferredDatePickerStyle = .compact
        picker.tintColor = tintColor
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        picker.tintColor = tintColor
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
