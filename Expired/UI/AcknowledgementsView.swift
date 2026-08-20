import SwiftUI

/// Open-source licences for everything Expired links against.
///
/// The list mirrors `Expired.xcodeproj/.../Package.resolved` — every entry was read
/// from the package's own `LICENSE` file in `SourcePackages/checkouts`, not inferred.
/// When a dependency is added or removed, update this list in the same commit;
/// a licence page that lists something the app doesn't ship is worse than none.
struct AcknowledgementsView: View {

    struct Dependency: Identifiable {
        var id: String { name }
        let name: String
        let owner: String
        let licence: String
        let url: String
    }

    /// Alphabetical, matching how the resolved file reads.
    static let dependencies: [Dependency] = [
        .init(name: "purchases-ios", owner: "RevenueCat, Inc.", licence: "MIT License",
              url: "https://github.com/RevenueCat/purchases-ios-spm"),
        .init(name: "supabase-swift", owner: "Supabase", licence: "MIT License",
              url: "https://github.com/supabase-community/supabase-swift"),
        .init(name: "swift-asn1", owner: "Apple Inc.", licence: "Apache License 2.0",
              url: "https://github.com/apple/swift-asn1"),
        .init(name: "swift-clocks", owner: "Point-Free", licence: "MIT License",
              url: "https://github.com/pointfreeco/swift-clocks"),
        .init(name: "swift-concurrency-extras", owner: "Point-Free", licence: "MIT License",
              url: "https://github.com/pointfreeco/swift-concurrency-extras"),
        .init(name: "swift-crypto", owner: "Apple Inc.", licence: "Apache License 2.0",
              url: "https://github.com/apple/swift-crypto"),
        .init(name: "swift-http-types", owner: "Apple Inc.", licence: "Apache License 2.0",
              url: "https://github.com/apple/swift-http-types"),
        .init(name: "xctest-dynamic-overlay", owner: "Point-Free, Inc.", licence: "MIT License",
              url: "https://github.com/pointfreeco/xctest-dynamic-overlay")
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.dependencies) { dep in
                    Link(destination: URL(string: dep.url) ?? URL(string: "https://github.com")!) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dep.name)
                                    .foregroundStyle(.primary)
                                Text("\(dep.licence) · \(dep.owner)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text("Expired is built with these open-source packages. Each name links to its repository, where the full licence text lives.")
            }

            Section {
                Text("Icons are Apple SF Symbols, used under the SF Symbols licence and only within Apple platforms. Service logos are fetched from each service's own site and remain the property of their owners.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Icons & Logos")
            }
        }
        .navigationTitle("Acknowledgements")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
