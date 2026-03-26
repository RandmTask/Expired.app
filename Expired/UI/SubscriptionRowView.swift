import SwiftUI

struct SubscriptionRowView: View {
    let item: SubscriptionItem

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ItemIconView(item: item, size: 46)

            // Name + date
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                dateLabel
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Right side: cost + badge
            VStack(alignment: .trailing, spacing: 5) {
                if let monthly = item.monthlyCost {
                    Text(monthly, format: .currency(code: item.currency))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("/ mo")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                StatusBadge(status: item.status)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var dateLabel: some View {
        switch item.status {
        case .trial(let endsOn):
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.purple)
                Text("Trial ends \(endsOn, style: .relative)")
            }
        case .cancelledButActive(let until):
            HStack(spacing: 4) {
                Image(systemName: "calendar.badge.minus")
                    .foregroundStyle(.orange)
                Text("Active until \(until.formatted(date: .abbreviated, time: .omitted))")
            }
        case .expired:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
                Text("Expired")
            }
        default:
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(item.nextRelevantDate, style: .date)
            }
        }
    }
}

// MARK: - Icon View

struct ItemIconView: View {
    let item: SubscriptionItem
    let size: CGFloat

    var body: some View {
        Group {
            if item.iconSource == .customImage || item.iconSource == .favicon,
               let data = item.iconData,
               let uiImage = platformImage(from: data) {
                Image(platformImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22)
                        .fill(iconGradient)
                    Image(systemName: item.systemIconName)
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
    }

    private var iconGradient: LinearGradient {
        let colors = gradientColors(for: item.name)
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func gradientColors(for name: String) -> [Color] {
        let lower = name.lowercased()
        if lower.contains("netflix") { return [.red, Color(red: 0.7, green: 0, blue: 0)] }
        if lower.contains("spotify") { return [Color(red: 0.11, green: 0.73, blue: 0.33), .green] }
        if lower.contains("apple") || lower.contains("icloud") { return [.gray, Color(white: 0.35)] }
        if lower.contains("amazon") { return [Color(red: 1, green: 0.6, blue: 0), .orange] }
        if lower.contains("audible") { return [Color(red: 1, green: 0.47, blue: 0), .orange] }
        if lower.contains("youtube") { return [.red, Color(red: 0.8, green: 0, blue: 0)] }
        if lower.contains("disney") { return [Color(red: 0.05, green: 0.1, blue: 0.6), .blue] }
        if lower.contains("gym") || lower.contains("fitness") { return [.purple, .indigo] }
        if lower.contains("microsoft") { return [.blue, .cyan] }
        if lower.contains("adobe") { return [.red, .pink] }
        if lower.contains("passport") || lower.contains("licence") { return [.indigo, .blue] }

        // Hash-based fallback for consistent colours per name
        let hash = abs(name.hashValue)
        let palettes: [[Color]] = [
            [.blue, .cyan],
            [.purple, .indigo],
            [.pink, .orange],
            [.teal, .green],
            [.orange, .yellow],
            [Color(red: 0.3, green: 0.2, blue: 0.8), .purple],
        ]
        return palettes[hash % palettes.count]
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: SubscriptionStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15), in: Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .autoRenew: return .green
        case .manualRenew: return .blue
        case .cancelledButActive: return .orange
        case .expired: return .red
        case .trial: return .purple
        }
    }
}

// MARK: - Cross-platform image helpers

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage

func platformImage(from data: Data) -> UIImage? {
    UIImage(data: data)
}

extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage

func platformImage(from data: Data) -> NSImage? {
    NSImage(data: data)
}

extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        SubscriptionRowView(item: PreviewData.netflix)
        SubscriptionRowView(item: PreviewData.spotify)
        SubscriptionRowView(item: PreviewData.gym)
    }
    .padding()
    .background(Color(white: 0.95))
}

