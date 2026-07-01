import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum Haptics {
    enum FeedbackType {
        case success
        case warning
        case error
        case light
        case medium
        case heavy
        case selectionChanged
    }

#if os(iOS)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
#endif

    static func fire(_ type: FeedbackType) {
#if os(iOS)
        switch type {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .light:
            lightGenerator.impactOccurred()
            lightGenerator.prepare()
        case .medium:
            mediumGenerator.impactOccurred()
            mediumGenerator.prepare()
        case .heavy:
            heavyGenerator.impactOccurred()
            heavyGenerator.prepare()
        case .selectionChanged:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        }
#elseif os(macOS)
        switch type {
        case .success, .light, .selectionChanged:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .warning, .error, .medium, .heavy:
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
#endif
    }
}
