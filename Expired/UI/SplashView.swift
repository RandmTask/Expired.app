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
    /// TEMP: bumped to 3s so Deon can actually see each stage while testing —
    /// drop back to ~1.5s (adjust `hold` below) once the look is confirmed.
    static let total: TimeInterval = 3.0

    static let wordmarkDelay: TimeInterval = 0.15
    static let wordmarkIn: TimeInterval = 0.40
    static let out: TimeInterval = 0.40
    /// Whatever's left after the fixed stages above, so `total` stays authoritative.
    static let hold: TimeInterval = total - wordmarkDelay - wordmarkIn - out
}

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                // No entrance animation here on purpose — this must be on screen in the
                // very first frame, matching the static launch screen the instant it hands
                // over. Only the wordmark animates in after it (the Duolingo pattern).
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 118, height: 118)

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
        if reduceMotion {
            withAnimation(.easeOut(duration: SplashTiming.wordmarkIn)) {
                wordmarkShown = true
            }
        } else {
            try? await Task.sleep(for: .seconds(SplashTiming.wordmarkDelay))
            withAnimation(.easeOut(duration: SplashTiming.wordmarkIn)) {
                wordmarkShown = true
            }
        }

        try? await Task.sleep(for: .seconds(SplashTiming.hold))
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
