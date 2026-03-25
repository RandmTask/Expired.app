import SwiftUI

struct SubscriptionRowView: View {
    let item: SubscriptionItem

    private var statusColor: Color {
        switch item.status {
        case .autoRenew:
            return Color.green
        case .manualRenew:
            return Color.blue
        case .cancelledButActive:
            return Color.orange
        case .expired:
            return Color.red
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
                Image(systemName: "sparkle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.custom("Avenir Next", size: 18))
                    .foregroundStyle(.primary)

                Text(dateLabel)
                    .font(.custom("Avenir Next", size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                StatusBadge(label: item.status.label, color: statusColor)

                if let cost = item.cost {
                    Text(costLabel(cost))
                        .font(.custom("Avenir Next", size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
        )
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = item.nextRelevantDate
        if item.isTrial {
            return "Trial ends \(formatter.string(from: date))"
        }
        if item.status == .cancelledButActive {
            return "Active until \(formatter.string(from: date))"
        }
        return "Renews \(formatter.string(from: date))"
    }

    private func costLabel(_ cost: Double) -> String {
        let currency = item.currency
        let formatted = String(format: "%.2f", cost)
        return "\(currency) \(formatted)"
    }
}

struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.custom("Avenir Next", size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.18))
            )
            .foregroundStyle(color)
    }
}

#Preview {
    VStack(spacing: 16) {
        ForEach(PreviewData.sampleSubscriptions) { item in
            SubscriptionRowView(item: item)
        }
    }
    .padding()
    .background(
        LinearGradient(
            colors: [Color(.systemBackground), Color(.systemGray6)],
            startPoint: .top,
            endPoint: .bottom
        )
    )
}
