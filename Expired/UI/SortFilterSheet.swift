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
/// Sort is a native dropdown + segmented ascending/descending control in one
/// section; filters are multi-select tags as a uniform 2x2 button grid.
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
                            Text(option.rawValue).tag(option)
                        }
                    } label: {
                        Text("Sort By")
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .onChange(of: sortOrder) { _, _ in Haptics.fire(.selectionChanged) }

                    Picker(selection: $sortAscending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    } label: {
                        Text("Order")
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    .onChange(of: sortAscending) { _, _ in Haptics.fire(.selectionChanged) }
                } header: {
                    Text("Sort")
                }

                ForEach(HomeView.FilterTag.Section.allCases, id: \.self) { section in
                    Section {
                        FilterTagGrid(tags: HomeView.FilterTag.allCases.filter { $0.section == section }, filterTags: $filterTags)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                    } header: {
                        Text(section.rawValue)
                    }
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

private struct FilterTagGrid: View {
    let tags: [HomeView.FilterTag]
    @Binding var filterTags: Set<HomeView.FilterTag>

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(tags, id: \.self) { tag in
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
    }
}

private struct FilterTagChip: View {
    let tag: HomeView.FilterTag
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tag.icon)
                Text(tag.rawValue)
            }
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(isSelected ? Color.blue : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
