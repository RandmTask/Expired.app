import SwiftUI
import SwiftData
import UserNotifications
#if canImport(RevenueCat)
import RevenueCat
#endif

#if os(iOS)

// MARK: - Onboarding gate

/// Presents onboarding exactly once per install. Gating logic:
/// - `hasCompletedOnboarding` is local-only (UserDefaults), never synced via iCloud KV —
///   a second device seeing the pager once is fine; syncing the flag would race CloudKit.
/// - Before showing anything, count existing `SubscriptionItem` rows. A reinstall whose
///   CloudKit data has already landed (or is mid-import) is treated as a returning user:
///   the flag is set silently and onboarding never appears. This performs zero writes to
///   the store itself — it never seeds data and never blocks on iCloud account status —
///   so a mid-onboarding CloudKit import is harmless; the user simply finishes the pager
///   normally and the flag is set on completion.
struct OnboardingGate: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var didCheck = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView {
                    hasCompletedOnboarding = true
                    showOnboarding = false
                }
            }
            .task { await checkOnboardingState() }
    }

    @MainActor
    private func checkOnboardingState() async {
        guard !didCheck else { return }
        didCheck = true
        guard !hasCompletedOnboarding else { return }

        let count = (try? modelContext.fetchCount(FetchDescriptor<SubscriptionItem>())) ?? 0
        if count > 0 {
            hasCompletedOnboarding = true
            return
        }

        // A fullScreenCover presents above the splash overlay, so on a first launch the
        // pager would slide up mid-animation. Let the splash finish first.
        try? await Task.sleep(for: .seconds(SplashTiming.total))
        showOnboarding = true
    }
}

extension View {
    func expiredOnboardingGate() -> some View {
        modifier(OnboardingGate())
    }
}

// MARK: - Onboarding pager

struct OnboardingView: View {
    let onComplete: () -> Void

    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageIndex = 0
    @State private var showSplash = true
    @State private var showPaywall = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var reminderOffsetDays = 3
    @State private var selectedTileIDs: [String] = []
    @AppStorage("preferredCurrency") private var preferredCurrency = SettingsView.localeCurrencyCode

    private let pageCount = 7
    /// Pages with their own footer CTA (grid + quick setup) — the generic
    /// `continueButton`/chrome must stay hidden for these.
    private let customFooterPages: Set<Int> = [4, 5]

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                skipButton

                TabView(selection: $pageIndex) {
                    welcomePage.tag(0)
                    trackEverythingPage.tag(1)
                    screenshotImportPage.tag(2)
                    remindersPage.tag(3)
                    ServicePickerPage(
                        selectedTileIDs: $selectedTileIDs,
                        onContinue: { withAnimation { pageIndex = 5 } },
                        onSkip: { withAnimation { pageIndex = 6 } },
                        onAddYourOwn: onComplete
                    ).tag(4)
                    QuickSetupPage(
                        selectedTileIDs: $selectedTileIDs,
                        reminderOffsetDays: reminderOffsetDays,
                        currency: preferredCurrency,
                        onCommit: { withAnimation { pageIndex = 6 } },
                        onSkip: { withAnimation { pageIndex = 6 } }
                    ).tag(5)
                    proPage.tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                if !customFooterPages.contains(pageIndex) {
                    continueButton
                }
            }
            .padding(.bottom, 24)
            .opacity(showSplash ? 0 : 1)

            if showSplash {
                OnboardingSplashOverlay {
                    withAnimation(.easeInOut(duration: 0.4)) { showSplash = false }
                }
            }
        }
        .expiredPaywallSheet(isPresented: $showPaywall)
        .task { await refreshNotificationStatus() }
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Spacer()
            ExpiredBear(expression: .happy, size: 160, animated: !reduceMotion)
            VStack(spacing: 10) {
                Text("Welcome to Expired")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Never get surprised by a renewal again.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var trackEverythingPage: some View {
        VStack(spacing: 28) {
            Spacer()
            HStack(spacing: 20) {
                featureIcon("creditcard.fill", color: .blue)
                featureIcon("person.text.rectangle.fill", color: .indigo)
            }
            VStack(spacing: 10) {
                Text("Subscriptions & Documents")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("From Netflix to your passport — track every renewal and expiry date in one calm place.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var screenshotImportPage: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 130, height: 130)
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text("Screenshot Import")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    ProChip()
                }
                Text("Snap a screenshot of a receipt or subscription page — AI fills in the details for you.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var remindersPage: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(Color.orange.opacity(0.14)).frame(width: 130, height: 130)
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            VStack(spacing: 10) {
                Text("Timely Reminders")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Get notified before things renew or expire — never a surprise charge again.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            notificationButton
            reminderOffsetPicker
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    /// Sets the default lead time used both by the copy above and by every item R4's
    /// picker grid seeds (`QuickSetupPage` reads this directly) — one control instead
    /// of a separate "reminder defaults" setting.
    private var reminderOffsetPicker: some View {
        VStack(spacing: 6) {
            Text("Remind me")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Remind me", selection: $reminderOffsetDays) {
                Text("1 day before").tag(1)
                Text("3 days before").tag(3)
                Text("5 days before").tag(5)
                Text("7 days before").tag(7)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.top, 4)
    }

    private var proPage: some View {
        VStack(spacing: 18) {
            Spacer()
            ExpiredBear(expression: .celebrating, size: 110, animated: !reduceMotion)
            VStack(spacing: 6) {
                Text("Unlock Expired Pro")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                if let trialText {
                    Text(trialText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                proFeatureRow("Unlimited subscriptions & documents")
                proFeatureRow("AI Screenshot Import")
                proFeatureRow("Backup restore & advanced insights")
            }
            .padding(.horizontal, 20)

            Button {
                Haptics.fire(.light)
                showPaywall = true
            } label: {
                Text("Start Free Trial")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 32)

            Button("Continue with Free") {
                Haptics.fire(.light)
                onComplete()
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .onChange(of: purchaseManager.isPremium) { _, isPremium in
            if isPremium { onComplete() }
        }
    }

    // MARK: Page helpers

    private func featureIcon(_ systemName: String, color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.14)).frame(width: 76, height: 76)
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private func proFeatureRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.blue)
            Text(text).font(.system(size: 14))
            Spacer()
        }
    }

    @ViewBuilder
    private var notificationButton: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Notifications Enabled", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
        case .denied:
            VStack(spacing: 4) {
                Text("Notifications are off")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("You can enable them anytime in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        default:
            Button {
                Task {
                    await NotificationManager.shared.requestAuthorization()
                    await refreshNotificationStatus()
                    Haptics.fire(.light)
                }
            } label: {
                Text("Enable Notifications")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }

    /// Reads the yearly package's introductory discount, if RevenueCat has configured
    /// one as a free trial. Returns nil (hides the line entirely) when offerings
    /// haven't loaded yet, there's no yearly package, or no trial is configured —
    /// this must never claim a trial that doesn't exist.
    private var trialText: String? {
        guard let discount = purchaseManager.offerings?.current?.annual?.storeProduct.introductoryDiscount,
              discount.paymentMode == .freeTrial else { return nil }
        let period = discount.subscriptionPeriod
        let unitLabel: String
        switch period.unit {
        case .day:   unitLabel = period.value == 1 ? "day" : "days"
        case .week:  unitLabel = period.value == 1 ? "week" : "weeks"
        case .month: unitLabel = period.value == 1 ? "month" : "months"
        case .year:  unitLabel = period.value == 1 ? "year" : "years"
        @unknown default: return nil
        }
        let price = purchaseManager.offerings?.current?.annual?.storeProduct.localizedPriceString ?? ""
        return "\(period.value) \(unitLabel) free, then \(price)/yr"
    }

    // MARK: Chrome

    @ViewBuilder
    private var skipButton: some View {
        if pageIndex < pageCount - 1 {
            HStack {
                Spacer()
                Button("Skip") {
                    Haptics.fire(.light)
                    onComplete()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 20)
                .padding(.top, 12)
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { i in
                Capsule()
                    .fill(i == pageIndex ? Color.blue : Color.secondary.opacity(0.25))
                    .frame(width: i == pageIndex ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(duration: 0.3), value: pageIndex)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var continueButton: some View {
        if pageIndex < pageCount - 1 {
            Button {
                Haptics.fire(.light)
                withAnimation { pageIndex += 1 }
            } label: {
                Text("Next")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 32)
            .padding(.top, 8)
        }
    }
}

// MARK: - First-launch splash

/// Brief brand moment shown once, immediately before the onboarding pager, on the
/// very first launch only (gated by the same `hasCompletedOnboarding` flag one layer
/// up — no separate flag needed). Every later launch skips straight past it.
private struct OnboardingSplashOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinished: () -> Void
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                ExpiredBear(expression: .happy, size: 120, animated: !reduceMotion)
                Text("Expired")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
            }
        }
        .task {
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.4 : 1.2))
            onFinished()
        }
    }
}

#endif
