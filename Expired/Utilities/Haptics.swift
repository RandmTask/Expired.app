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
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .selectionChanged:
            UISelectionFeedbackGenerator().selectionChanged()
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
