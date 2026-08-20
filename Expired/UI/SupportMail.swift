import SwiftUI
#if os(iOS)
import MessageUI
#elseif os(macOS)
import AppKit
#endif

/// A prefilled support email. Two kinds, deliberately kept separate so the inbox
/// sorts itself — see `_shared/settings page/feedback-conventions.md`: a bug report
/// and a feature request are triaged differently, so they never share one row or
/// one subject line.
struct SupportEmailDraft: Identifiable {
    enum Kind {
        case bugReport
        case feedback

        var subject: String {
            switch self {
            case .bugReport: return "Expired \(SupportConfig.appVersion) — bug report"
            case .feedback:  return "Expired \(SupportConfig.appVersion) — feedback"
            }
        }

        var prompt: String {
            switch self {
            case .bugReport:
                return """
                What happened?


                What did you expect instead?


                """
            case .feedback:
                return """
                What would you like Expired to do?


                """
            }
        }
    }

    let id = UUID()
    let kind: Kind

    var recipients: [String] { [SupportConfig.supportEmail] }
    var subject: String { kind.subject }

    /// The user's blank space comes first so the cursor lands on something to write;
    /// the auto-filled context block trails it, visible and editable before sending.
    var body: String { kind.prompt + "\n" + SupportConfig.contextBlock }
}

#if os(iOS)

/// SwiftUI wrapper over `MFMailComposeViewController`. Present with `.sheet(item:)`.
struct MailComposerView: UIViewControllerRepresentable {
    static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }

    let draft: SupportEmailDraft
    let onFinish: () -> Void

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            // Don't dismiss the controller here — `.sheet(item:)` owns presentation,
            // and racing two dismiss requests collapses both sheet layers when this
            // is presented from inside Settings. Clearing the bound item is enough.
            onFinish()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(draft.recipients)
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
}

#endif

enum SupportMail {

    /// True when the platform can present a prefilled draft at all. On macOS this is
    /// always true (the default mail client handles `mailto:`); on iOS it reflects
    /// whether Mail is actually configured.
    static var canCompose: Bool {
        #if os(iOS)
        return MailComposerView.canSendMail
        #else
        return true
        #endif
    }

    /// macOS path: `MessageUI` doesn't exist there, so hand a percent-encoded
    /// `mailto:` to the default client. Still a *prefilled* draft — the conventions'
    /// "never a bare mailto" rule is about prefill, not about the mechanism.
    /// iOS never reaches this: it always has `MFMailComposeViewController`, and
    /// falls back to the copy-the-address alert when Mail isn't configured.
    @discardableResult
    static func openMailto(_ draft: SupportEmailDraft) -> Bool {
        // `.urlQueryAllowed` leaves `&`, `+` and `=` intact, which would truncate the
        // body at the first one — subtract them explicitly.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let subject = draft.subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let body = draft.body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let recipient = draft.recipients.joined(separator: ",")
        guard let url = URL(string: "mailto:\(recipient)?subject=\(subject)&body=\(body)") else {
            return false
        }
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }
}
