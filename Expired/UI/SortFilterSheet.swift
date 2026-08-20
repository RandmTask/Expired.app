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

    var ascendingLabel: String {
        switch self {
        case .status, .renewalDate: return "Soonest First"
        case .category, .name:      return "A to Z"
        case .dateAdded:             return "Oldest First"
        case .price:                 return "Low to High"
        }
    }

    var descendingLabel: String {
        switch self {
        case .status, .renewalDate: return "Latest First"
        case .category, .name:      return "Z to A"
        case .dateAdded:             return "Newest First"
        case .price:                 return "High to Low"
        }
    }
}

/// Dedicated sort/filter sheet (replaces the old nested overflow-menu submenus).
/// Sort is single-select with a separate ascending/descending order control; filters
/// are multi-select tags (OR-matched), plus a standalone "Hide Expired" toggle.
struct SortFilterSheet: View {
    @Binding var sortOrder: HomeView.SortOrder
    @Binding var sortAscending: Bool
    @Binding var filterTags: Set<HomeView.FilterTag>
    @Binding var hideExpired: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(HomeView.SortOrder.allCases, id: \.self) { option in
                        Button {
                            Haptics.fire(.selectionChanged)
                            sortOrder = option
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.icon)
                                    .font(.system(size: 15))
                                    .frame(width: 20, alignment: .center)
                                    .foregroundStyle(.secondary)
                                Text(option.rawValue)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if sortOrder == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Sort By")
                }

                Section {
                    Picker("Order", selection: $sortAscending) {
                        Text(sortOrder.ascendingLabel).tag(true)
                        Text(sortOrder.descendingLabel).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: sortAscending) { _, _ in Haptics.fire(.selectionChanged) }
                } header: {
                    Text("Order")
                }

                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
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
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)

                    Toggle(isOn: $hideExpired) {
                        Text("Hide Expired")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                    }
                    .toggleStyle(.switch)
                    .tint(.blue)
                    .disabled(filterTags.contains(.expired))
                } header: {
                    Text("Filter")
                } footer: {
                    if !filterTags.isEmpty {
                        Text("Showing subscriptions matching any selected filter.")
                    }
                }

                if !filterTags.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            Haptics.fire(.light)
                            filterTags.removeAll()
                        } label: {
                            Text("Clear Filters")
                        }
                    }
                }
            }
            .navigationTitle("Sort & Filter")
            .inlineNavigationTitle()
            .toolbar {
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
            HStack(spacing: 6) {
                Image(systemName: tag.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(tag.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.blue : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
