import SwiftUI

/// A button that copies text to the pasteboard and gives visible confirmation — its
/// label flips to a checkmark for ~1.5s. Per `_shared/settings-conventions.md`'s button
/// feedback rule: a copy action with no visible result reads as broken, so every copy
/// affordance in Settings/Debug uses this instead of a bare `Button` + pasteboard call.
struct CopyFeedbackButton: View {
    let label: String
    let systemImage: String
    var tint: Color = .blue
    let value: () -> String

    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(value())
            Haptics.fire(.success)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : systemImage)
        }
        .foregroundStyle(copied ? .green : tint)
        .animation(.easeInOut(duration: 0.15), value: copied)
    }

    private func copyToPasteboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
