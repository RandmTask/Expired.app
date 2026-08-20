import SwiftUI

extension HomeView.SortOrder {
    var icon: String {
        switch self {
        case .status:      return "tray.full"
        case .category:    return "square.grid.2x2"
        case .name:        return "textformat.abc"
        case .renewalDate: return "calendar"
        case .dateAdded:   return "calendar.badge.plus"
        case .price:       return "dollarsign.circle"
        }
    }
}

/// Dedicated sort/filter sheet (replaces the old nested overflow-menu submenus).
/// Sort is a single dropdown + ascending/descending stepper in one section; filters
/// are multi-select tags (OR-matched) as large iOS-style capsule chips.
struct SortFilterSheet: View {
    @Binding var sortOrder: HomeView.SortOrder
    @Binding var sortAscending: Bool
    @Binding var filterTags: Set<HomeView.FilterTag>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(selection: $sortOrder) {
                        ForEach(HomeView.SortOrder.allCases, id: \.self) { option in
                            Label(option.rawValue, systemImage: option.icon).tag(option)
                        }
                    } label: {
                        Text("Sort By")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: sortOrder) { _, _ in Haptics.fire(.selectionChanged) }

                    Stepper {
                        HStack(spacing: 8) {
                            Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(sortAscending ? "Ascending" : "Descending")
                                .foregroundStyle(.primary)
                        }
                    } onIncrement: {
                        guard !sortAscending else { return }
                        Haptics.fire(.selectionChanged)
                        sortAscending = true
                    } onDecrement: {
                        guard sortAscending else { return }
                        Haptics.fire(.selectionChanged)
                        sortAscending = false
                    }
                } header: {
                    Text("Sort")
                }

                Section {
                    FlowLayout(spacing: 10) {
                        ForEach(HomeView.FilterTag.allCases, id: \.self) { tag in
                            FilterTagChip(tag: tag, isSelected: filterTags.contains(tag)) {
                                Haptics.fire(.selectionChanged)
                                if filterTags.contains(tag) {
                                    filterTags.remove(tag)
                                } else {
                                    filterTags.insert(tag)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Filter")
                }
            }
            .navigationTitle("Sort & Filter")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        Haptics.fire(.light)
                        filterTags.removeAll()
                    }
                    .disabled(filterTags.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct FilterTagChip: View {
    let tag: HomeView.FilterTag
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: tag.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(tag.rawValue)
                    .font(.system(size: 15, weight: .semibold))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(isSelected ? Color.blue : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Minimal wrapping row layout for chips that size to their own content
/// (rather than a fixed-column grid), matching the standard iOS filter-pill look.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
