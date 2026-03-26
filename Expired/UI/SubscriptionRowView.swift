import SwiftUI

struct SubscriptionRowView: View {
    let item: SubscriptionItem

    private var urgencyAccent: Color {
        switch item.urgency {
        case .critical: return .red
        case .warning:  return .orange
        case .expired:  return .red.opacity(0.5)
        case .normal:   return .clear
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Icon with urgency ring
            UrgencyIconView(item: item, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                dateLabel
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                if item.itemType == .subscription, let monthly = item.monthlyCost {
                    Text(CurrencyInfo.format(monthly, code: item.currency))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("/ mo")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if item.itemType == .document {
                    // Days countdown badge for documents
                    DaysCountdownBadge(days: item.daysUntilRenewal, urgency: item.urgency)
                }
                StatusBadge(status: item.status, itemType: item.itemType)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(in: .rect(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var dateLabel: some View {
        switch item.status {
        case .trial(let endsOn):
            HStack(spacing: 3) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.purple)
                Text("Trial ends \(endsOn, style: .relative)")
            }
        case .cancelledButActive(let until):
            HStack(spacing: 3) {
                Image(systemName: "calendar.badge.minus").foregroundStyle(.orange)
                Text("Active until \(until.formatted(date: .abbreviated, time: .omitted))")
            }
        case .expired:
            HStack(spacing: 3) {
                Image(systemName: "xmark.circle").foregroundStyle(.red)
                Text("Expired")
            }
        default:
            HStack(spacing: 3) {
                Image(systemName: item.itemType == .document ? "doc.text" : "calendar")
                Text(item.nextRelevantDate, style: .date)
            }
        }
    }
}

// MARK: - Urgency Icon View (icon with adaptive border ring)

struct UrgencyIconView: View {
    let item: SubscriptionItem
    let size: CGFloat

    private var ringColor: Color {
        switch item.urgency {
        case .critical: return .red
        case .warning:  return .orange
        case .expired:  return Color.secondary.opacity(0.5)
        case .normal:   return .clear
        }
    }

    var body: some View {
        ZStack {
            ItemIconView(item: item, size: size)

            RoundedRectangle(cornerRadius: size * 0.22)
                .strokeBorder(ringColor, lineWidth: 2)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Days Countdown Badge

struct DaysCountdownBadge: View {
    let days: Int
    let urgency: SubscriptionItem.Urgency

    private var badgeColor: Color {
        switch urgency {
        case .critical: return .red
        case .warning:  return .orange
        case .expired:  return .secondary
        case .normal:   return .indigo
        }
    }

    private var label: String {
        if case .expired = urgency { return "Expired" }
        if days == 0 { return "Today" }
        if days == 1 { return "1 day" }
        return "\(days)d"
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.14), in: Capsule())
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
               let img = platformImage(from: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22)
                        .fill(iconGradient)
                    Image(systemName: item.systemIconName)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
    }

    private var iconGradient: LinearGradient {
        LinearGradient(colors: gradientColors(for: item.name, itemType: item.itemType),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func gradientColors(for name: String, itemType: ItemType) -> [Color] {
        // Documents get indigo/blue palette
        if itemType == .document {
            let lower = name.lowercased()
            if lower.contains("passport")                         { return [Color(red: 0.2, green: 0.2, blue: 0.8), .indigo] }
            if lower.contains("licence") || lower.contains("license") || lower.contains("driver") { return [.teal, .blue] }
            if lower.contains("insurance") || lower.contains("policy") { return [.indigo, .purple] }
            if lower.contains("visa")                             { return [Color(red: 0.1, green: 0.4, blue: 0.9), .blue] }
            return [.indigo, Color(red: 0.3, green: 0.2, blue: 0.8)]
        }

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
        let hash = abs(name.hashValue)
        let palettes: [[Color]] = [
            [.blue, .cyan], [.purple, .indigo], [.pink, .orange],
            [.teal, .green], [.orange, .yellow],
            [Color(red: 0.3, green: 0.2, blue: 0.8), .purple],
        ]
        return palettes[hash % palettes.count]
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: SubscriptionStatus
    var itemType: ItemType = .subscription

    var body: some View {
        Text(badgeLabel)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.14), in: Capsule())
    }

    private var badgeLabel: String {
        if itemType == .document {
            switch status {
            case .expired:     return "Expired"
            default:           return "Valid"
            }
        }
        return status.label
    }

    private var badgeColor: Color {
        switch status {
        case .autoRenew:         return .green
        case .manualRenew:       return itemType == .document ? .indigo : .blue
        case .cancelledButActive: return .orange
        case .expired:           return .red
        case .trial:             return .purple
        }
    }
}

// MARK: - Cross-platform image helpers

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage

func platformImage(from data: Data) -> UIImage? { UIImage(data: data) }

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage

func platformImage(from data: Data) -> NSImage? { NSImage(data: data) }

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#endif

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        SubscriptionRowView(item: PreviewData.netflix)
        SubscriptionRowView(item: PreviewData.spotify)
        SubscriptionRowView(item: PreviewData.gym)
        SubscriptionRowView(item: PreviewData.passport)
    }
    .padding()
    .background(Color(white: 0.92))
}
