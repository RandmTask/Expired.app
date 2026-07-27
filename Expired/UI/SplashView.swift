import SwiftUI

#if os(iOS)

/// Animated launch experience, using the "bait and switch" technique that Apple actually
/// allows (see `_shared/launch-screens.md`).
///
/// iOS renders the *static* launch screen declared by `UILaunchScreen` in Info.plist —
/// a bare `LaunchBackground` fill, no image. `SplashView` then draws the identical fill
/// and animates the logo and wordmark in on top of it. Because the two backgrounds are
/// the same asset colour, the handover is invisible: the user sees one continuous screen
/// that appears to animate, which the real launch screen can never do.
///
/// The app's real content stays mounted underneath the whole time — the splash is an
/// overlay, never a gate — so nothing about startup is actually delayed by it.
enum SplashTiming {
    /// Total time from launch to the splash being fully gone. Anything that must not
    /// appear on top of the splash (onboarding) waits this long first.
    static let total: TimeInterval = 2.5

    static let logoIn: TimeInterval = 0.40
    static let wordmarkDelay: TimeInterval = 0.25
    static let wordmarkIn: TimeInterval = 0.60
    static let out: TimeInterval = 0.40
    /// Whatever's left after the fixed stages above, so `total` stays authoritative.
    static let hold: TimeInterval = total - wordmarkDelay - wordmarkIn - out
}

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var logoShown = false
    @State private var wordmarkShown = false
    @State private var leaving = false

    /// Brand gradient sampled from the app icon: teal → violet → magenta.
    static let brandGradient = LinearGradient(
        colors: [
            Color(red: 0.23, green: 0.92, blue: 0.82),
            Color(red: 0.49, green: 0.42, blue: 0.95),
            Color(red: 0.89, green: 0.29, blue: 0.88)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        ZStack {
            // Same asset colour as the static launch screen — this is what makes the
            // handover seamless. Do not swap it for a literal or a gradient.
            Color("LaunchBackground")
                .ignoresSafeArea()

            VStack(spacing: 22) {
                // Fade starts the instant the splash appears — no delay before the logo
                // begins showing, matching the static launch screen's handover — it just
                // isn't at full opacity for its first `logoIn` seconds.
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 118, height: 118)
                    .opacity(logoShown ? 1 : 0)

                Text("expired.")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(Self.brandGradient)
                    .opacity(wordmarkShown ? 1 : 0)
                    .offset(y: reduceMotion ? 0 : (wordmarkShown ? 0 : 10))
            }
            .opacity(leaving ? 0 : 1)
            .scaleEffect(reduceMotion ? 1 : (leaving ? 1.06 : 1))
        }
        .opacity(leaving ? 0 : 1)
        .task { await run() }
    }

    private func run() async {
        // Kick off both fades in the same run-loop turn: the logo starts immediately,
        // the wordmark is merely scheduled to start `wordmarkDelay` later — this is not
        // "wait, then start the wordmark fade," it's "start both clocks now."
        withAnimation(.easeOut(duration: SplashTiming.logoIn)) {
            logoShown = true
        }
        Task {
            try? await Task.sleep(for: .seconds(SplashTiming.wordmarkDelay))
            withAnimation(.easeOut(duration: SplashTiming.wordmarkIn)) {
                wordmarkShown = true
            }
        }

        try? await Task.sleep(for: .seconds(SplashTiming.wordmarkDelay + SplashTiming.hold))
        withAnimation(.easeIn(duration: SplashTiming.out)) {
            leaving = true
        }
    }
}

// MARK: - Overlay modifier

private struct SplashOverlay: ViewModifier {
    @State private var isPresented = true

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    SplashView()
                        // The splash is decorative; it must never eat a tap that the
                        // app underneath is already live enough to handle.
                        .allowsHitTesting(false)
                        .transition(.identity)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(SplashTiming.total))
                isPresented = false
            }
    }
}

extension View {
    /// Overlays the animated splash for the first `SplashTiming.total` seconds of a cold launch.
    func expiredSplash() -> some View {
        modifier(SplashOverlay())
    }
}

#Preview {
    Color(.systemGroupedBackground)
        .ignoresSafeArea()
        .expiredSplash()
}

#endif
