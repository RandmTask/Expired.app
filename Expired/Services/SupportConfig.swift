import Foundation
#if os(iOS)
import UIKit
#endif

/// Single source of truth for the Support/About section's outward-facing constants
/// and the short device-context block every support email carries.
///
/// Per `_shared/settings page/feedback-conventions.md`: the context block is
/// *triage metadata only* — app version/build, OS, device model. It must never grow
/// to carry user content; the fuller dump is Debug → Copy Diagnostic Report.
enum SupportConfig {

    // MARK: Addresses & links

    /// PRE-LAUNCH: swap for a real studio address before App Store submission.
    /// Tracked in `ROADMAP.md` → Pre-launch checklist.
    static let supportEmail = "swiftstudio.dob@gmail.com"

    /// Numeric App Store Apple ID (App Store Connect → My Apps → Expired → App
    /// Information → General Information → Apple ID). Empty until the app record
    /// exists; the "Rate Expired" row hides itself while it is empty rather than
    /// shipping a dead link (`_shared/settings page/settings-conventions.md`).
    static let appStoreID = ""

    /// Deep link that opens the App Store product page with the review sheet already
    /// presented. `nil` while `appStoreID` is unset.
    static var reviewURL: URL? {
        guard !appStoreID.isEmpty else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }

    // MARK: Tip jar

    /// Non-consumable tip products, cheapest first. These must exist in App Store
    /// Connect *and* be attached to the RevenueCat app before they resolve; until
    /// then the fetch returns nothing and the Tip Jar row stays hidden.
    static let tipProductIDs = [
        "com.swiftstudio.Expired.tip.small",
        "com.swiftstudio.Expired.tip.medium",
        "com.swiftstudio.Expired.tip.large"
    ]

    // MARK: Device / app context

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// The marketing-ish hardware identifier (`iPhone16,2`), not `UIDevice.model`,
    /// which only ever returns the generic string "iPhone" and is useless for triage.
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    static var osDescription: String {
        #if os(iOS)
        return "iOS \(UIDevice.current.systemVersion)"
        #elseif os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        return "unknown OS"
        #endif
    }

    /// The short auto-filled block appended to every support email body. Deliberately
    /// four lines — enough to match a report to a build, short enough that the user
    /// can read the whole draft before sending it.
    static var contextBlock: String {
        """
        ---
        App: Expired \(appVersion) (\(appBuild))
        OS: \(osDescription)
        Device: \(deviceModel)
        Locale: \(Locale.current.identifier)
        """
    }
}
