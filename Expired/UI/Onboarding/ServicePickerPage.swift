import SwiftUI
import SwiftData

/// R4 Page A — "what do you already use?" Flat, 4-across multi-select logo grid of
/// real apps only (no category headers, no non-app/document tiles — Deon's call,
/// 2026-07-27, after the first cut felt cluttered: "focus on popular apps or
/// websites"). Self-contained: renders its own header + sticky footer CTA rather
/// than relying on `OnboardingView`'s generic continue button, since the CTA text is
/// selection-count dependent. Reused both inside the onboarding pager and from
/// `HomeView`'s empty state / Settings replay (per `_shared/onboarding-conventions.md`).
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
    /// Persisted so a chosen style survives navigating away mid-comparison.
    @AppStorage("onboardingGridStyle") private var gridStyleRaw = ServiceGridStyle.squircleLabelled.rawValue
    /// The style switcher is a debug affordance only — it appears once the hidden
    /// Debug section has been revealed in Settings, and never for a real user.
    @AppStorage("debugSectionRevealed") private var debugSectionRevealed = false

    private var style: ServiceGridStyle {
        ServiceGridStyle(rawValue: gridStyleRaw) ?? .squircleLabelled
    }

    /// Measured width of the scroll container. iPhone widths (<500) keep the style's
    /// authored sizing untouched; wider iPad/Mac windows scale columns and icon size up
    /// so the grid doesn't sit as a cramped iPhone layout in a lot of empty space
    /// (Deon, 2026-07-28: "imagine an 11 or 13 inch iPad or a 16in MBP").
    @State private var containerWidth: CGFloat = 0

    private var metrics: AdaptiveGridMetrics {
        AdaptiveGridMetrics(style: style, width: containerWidth)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: metrics.interItemSpacing),
              count: metrics.columnCount)
    }

    private var tiles: [AppCatalog.OnboardingTile] { AppCatalog.onboardingTiles() }

    private var existingNames: Set<String> {
        Set(existingItems.map { AppCatalog.canonicalName($0.name) })
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 6) {
                    Text("What do you already use?")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Tap to add — we'll set up reminders for you.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 44)

                if debugSectionRevealed {
                    styleDebugMenu
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 14)

            ScrollView {
                if style == .honeycomb {
                    honeycombGrid
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                } else {
                    LazyVGrid(columns: columns, spacing: metrics.rowSpacing) {
                        ForEach(tiles) { tile in
                            tileView(tile)
                        }
                        addYourOwnTile
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }

            footer
        }
    }

    /// Debug-only layout switcher (top-left). Lets a whole grid style be compared
    /// on-device without a rebuild — see `ServiceGridStyle`.
    private var styleDebugMenu: some View {
        Menu {
            Picker("Grid style", selection: $gridStyleRaw) {
                ForEach(ServiceGridStyle.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .padding(.leading, 4)
#if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
#endif
    }

    /// Offset alternating rows by half a tile so tiles interlock. Uses a manual row
    /// split rather than `LazyVGrid`, which can't stagger.
    private var honeycombGrid: some View {
        let metrics = metrics
        let perRow = metrics.columnCount
        let all = tiles
        let rows = stride(from: 0, to: all.count, by: perRow).map { start in
            Array(all[start..<min(start + perRow, all.count)])
        }
        return VStack(spacing: metrics.rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, rowTiles in
                HStack(spacing: metrics.interItemSpacing) {
                    ForEach(rowTiles) { tile in
                        tileView(tile)
                    }
                    if rowTiles.count < perRow {
                        ForEach(0..<(perRow - rowTiles.count), id: \.self) { _ in
                            Color.clear.frame(width: metrics.iconSize, height: metrics.iconSize)
                        }
                    }
                }
                .offset(x: index.isMultiple(of: 2) ? 0 : (metrics.iconSize + metrics.interItemSpacing) / 2)
            }
            addYourOwnTile
                .padding(.top, metrics.rowSpacing)
        }
    }

    @ViewBuilder
    private func tileView(_ tile: AppCatalog.OnboardingTile) -> some View {
        let isTracked = existingNames.contains(AppCatalog.canonicalName(tile.name))
        let isSelected = isTracked || selectedTileIDs.contains(tile.id)
        let metrics = metrics

        Button {
            guard !isTracked else { return }
            toggle(tile)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    tileIcon(tile, metrics: metrics)
                        .frame(width: metrics.iconSize, height: metrics.iconSize)
                        .background(Color.secondary.opacity(0.08), in: metrics.iconShape)
                        .overlay(
                            metrics.iconShape
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

                if metrics.showsLabel {
                    Text(tile.name)
                        .font(.system(size: metrics.labelSize, weight: .medium))
                        .foregroundStyle(isTracked ? .tertiary : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(isTracked ? 0.5 : 1)
        .disabled(isTracked)
        .accessibilityLabel(tile.name)
    }

    @ViewBuilder
    private func tileIcon(_ tile: AppCatalog.OnboardingTile, metrics: AdaptiveGridMetrics) -> some View {
        if let symbolName = tile.symbolName {
            Image(systemName: symbolName)
                .font(.system(size: metrics.iconSize * 0.37, weight: .semibold))
                .foregroundStyle(.blue)
        } else if let iconData = tile.iconData, let image = platformImage(from: iconData) {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: metrics.iconSize, height: metrics.iconSize)
                .clipShape(metrics.iconShape)
        } else {
            Text(tile.name.prefix(1).uppercased())
                .font(.system(size: metrics.iconSize * 0.33, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var addYourOwnTile: some View {
        let metrics = metrics
        return Button(action: onAddYourOwn) {
            VStack(spacing: 6) {
                ZStack {
                    metrics.iconShape
                        .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .frame(width: metrics.iconSize, height: metrics.iconSize)
                    Image(systemName: "plus")
                        .font(.system(size: metrics.iconSize * 0.33, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                if metrics.showsLabel {
                    Text("Add your own")
                        .font(.system(size: metrics.labelSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
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

// MARK: - Grid style variants

/// Candidate layouts for the onboarding picker grid, switchable at runtime from the
/// debug-only menu on `ServicePickerPage` so they can be compared on a real device
/// instead of by rebuilding. The shipped default is `.squircleLabelled`; the rest
/// exist to settle the "which of these looks best" question with real icons and a
/// real device, not mockups.
enum ServiceGridStyle: String, CaseIterable, Identifiable {
    case squircleLabelled   // 4-up rounded square + name (default)
    case squircleLarge      // 3-up, noticeably bigger tiles + name
    case iconOnly           // 5-up, no names — densest
    case iconOnlyLarge      // 4-up, no names, big icons
    case circular           // 4-up circular avatars + name
    case circularLarge      // 3-up circular avatars + name
    case honeycomb          // 4-up staggered/interlocking rows + name
    case compact            // 5-up small tiles + name

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .squircleLabelled: return "Squircle + name (default)"
        case .squircleLarge:    return "Squircle large + name"
        case .iconOnly:         return "Icon only (5-up)"
        case .iconOnlyLarge:    return "Icon only, large (4-up)"
        case .circular:         return "Circular + name"
        case .circularLarge:    return "Circular large + name"
        case .honeycomb:        return "Honeycomb (staggered)"
        case .compact:          return "Compact (5-up + name)"
        }
    }

    var columnCount: Int {
        switch self {
        case .squircleLabelled, .iconOnlyLarge, .circular, .honeycomb: return 4
        case .squircleLarge, .circularLarge: return 3
        case .iconOnly, .compact: return 5
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .squircleLabelled: return 68
        case .squircleLarge:    return 92
        case .iconOnly:         return 58
        case .iconOnlyLarge:    return 74
        case .circular:         return 68
        case .circularLarge:    return 92
        case .honeycomb:        return 64
        case .compact:          return 52
        }
    }

    var showsLabel: Bool {
        switch self {
        case .iconOnly, .iconOnlyLarge: return false
        default: return true
        }
    }

    var labelSize: CGFloat {
        switch self {
        case .squircleLarge, .circularLarge: return 12
        case .compact: return 10
        default: return 11
        }
    }

    var interItemSpacing: CGFloat {
        switch self {
        case .iconOnly, .compact: return 8
        case .squircleLarge, .circularLarge: return 16
        default: return 12
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .iconOnly, .iconOnlyLarge: return 14
        case .squircleLarge, .circularLarge: return 20
        default: return 16
        }
    }

    /// `AnyInsettableShape` keeps both `.fill(_:in:)` and `.strokeBorder` available
    /// across the circle/rounded-rect variants without duplicating every call site.
    var iconShape: AnyInsettableShape {
        switch self {
        case .circular, .circularLarge:
            return AnyInsettableShape(Circle())
        default:
            return AnyInsettableShape(RoundedRectangle(cornerRadius: iconSize * 0.26))
        }
    }
}

/// Minimal type-erased `InsettableShape` — `AnyShape` (SwiftUI) erases `Shape` only,
/// which loses `.strokeBorder`.
struct AnyInsettableShape: InsettableShape {
    private let makePath: (CGRect) -> Path
    private let makeInset: (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        makePath = { shape.path(in: $0) }
        makeInset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { makePath(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { makeInset(amount) }
}
