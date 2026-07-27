import SwiftUI
import SwiftData

/// R4 Page A — "what do you already use?" Category-grouped multi-select logo grid.
/// Self-contained: renders its own header + sticky footer CTA rather than relying on
/// `OnboardingView`'s generic continue button, since the CTA text is selection-count
/// dependent. Reused both inside the onboarding pager and from `HomeView`'s empty
/// state / Settings replay (per `_shared/onboarding-conventions.md`).
struct ServicePickerPage: View {
    @Query private var existingItems: [SubscriptionItem]

    /// Ordered selection (tap order), shared with `QuickSetupPage` via the parent.
    @Binding var selectedTileIDs: [String]
    /// Called with a non-empty selection to advance to `QuickSetupPage`.
    let onContinue: () -> Void
    /// Called when skipping with zero selections.
    let onSkip: () -> Void
    let onAddYourOwn: () -> Void

    static let maxSelection = 10

    @State private var showCapWarning = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var tiles: [AppCatalog.OnboardingTile] { AppCatalog.onboardingTiles() }

    private var existingNames: Set<String> {
        Set(existingItems.map { AppCatalog.canonicalName($0.name) })
    }

    private var groupedTiles: [(category: String, tiles: [AppCatalog.OnboardingTile])] {
        var order: [String] = []
        var groups: [String: [AppCatalog.OnboardingTile]] = [:]
        for tile in tiles {
            if groups[tile.category] == nil {
                groups[tile.category] = []
                order.append(tile.category)
            }
            groups[tile.category]?.append(tile)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("What do you already use?")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Tap to add — we'll set up reminders for you.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groupedTiles, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.category.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(group.tiles) { tile in
                                    tileView(tile)
                                }
                            }
                        }
                    }

                    addYourOwnTile
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            footer
        }
    }

    @ViewBuilder
    private func tileView(_ tile: AppCatalog.OnboardingTile) -> some View {
        let isTracked = existingNames.contains(AppCatalog.canonicalName(tile.name))
        let isSelected = isTracked || selectedTileIDs.contains(tile.id)

        Button {
            guard !isTracked else { return }
            toggle(tile)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    tileIcon(tile)
                        .frame(width: 60, height: 60)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                        )

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white, .blue)
                            .background(Circle().fill(.white).padding(1))
                            .offset(x: 6, y: -6)
                    }
                }

                Text(tile.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isTracked ? .tertiary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .buttonStyle(.plain)
        .opacity(isTracked ? 0.5 : 1)
        .disabled(isTracked)
    }

    @ViewBuilder
    private func tileIcon(_ tile: AppCatalog.OnboardingTile) -> some View {
        if let symbolName = tile.symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue)
        } else if let iconData = tile.iconData, let image = platformImage(from: iconData) {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            Text(tile.name.prefix(1).uppercased())
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var addYourOwnTile: some View {
        Button(action: onAddYourOwn) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                Text("Add your own")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if showCapWarning {
                Text("You can pick up to \(Self.maxSelection) to start — add more anytime.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Button {
                Haptics.fire(.light)
                if selectedTileIDs.isEmpty {
                    onSkip()
                } else {
                    onContinue()
                }
            } label: {
                Text(selectedTileIDs.isEmpty ? "Skip for now" : "Continue with \(selectedTileIDs.count) selected")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 32)
        .padding(.top, 4)
    }

    private func toggle(_ tile: AppCatalog.OnboardingTile) {
        if let index = selectedTileIDs.firstIndex(of: tile.id) {
            selectedTileIDs.remove(at: index)
            showCapWarning = false
        } else if selectedTileIDs.count >= Self.maxSelection {
            Haptics.fire(.warning)
            withAnimation { showCapWarning = true }
        } else {
            Haptics.fire(.selectionChanged)
            selectedTileIDs.append(tile.id)
        }
    }
}
