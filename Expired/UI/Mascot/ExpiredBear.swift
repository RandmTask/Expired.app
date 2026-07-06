import SwiftUI

/// Expression states for the app mascot. `.expired` is a comic X-eyes wink at the
/// app's theme, not a scary/sad face — used only in genuinely-expired contexts.
enum BearExpression {
    case happy
    case sleepy
    case expired
    case celebrating
}

/// Pure-SwiftUI vector mascot — no image assets, tintable-free fixed palette,
/// scales from small empty-state glyphs up to a large onboarding hero.
/// Anonymous decoration (no user-facing name); every dimension is proportional
/// to `size` so it holds up at any scale.
struct ExpiredBear: View {
    var expression: BearExpression = .happy
    var size: CGFloat = 120
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var breathing = false
    @State private var blinkAmount: CGFloat = 1

    private var isAnimated: Bool { animated && !reduceMotion }

    private var furColor: Color { Color(red: 0.64, green: 0.44, blue: 0.27) }
    private var furShadowColor: Color { Color(red: 0.52, green: 0.34, blue: 0.20) }
    private var innerEarColor: Color { Color(red: 0.84, green: 0.63, blue: 0.44) }
    private var muzzleColor: Color { Color(red: 0.94, green: 0.85, blue: 0.70) }
    private var darkColor: Color { Color(red: 0.28, green: 0.18, blue: 0.11) }

    var body: some View {
        ZStack {
            ears
            head
            muzzleGroup
            eyesGroup
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(expression == .expired ? -4 : 0))
        .scaleEffect(appeared ? (breathing ? 1.02 : 1.0) : 0.6)
        .opacity(appeared ? 1 : 0)
        .onAppear { handleAppear() }
        .task(id: "\(expression)-\(isAnimated)") { await runBlinkLoop() }
        .accessibilityHidden(true)
    }

    // MARK: - Head structure

    private var ears: some View {
        HStack(spacing: size * 0.14) {
            earShape
            earShape
        }
        .offset(y: -size * 0.34)
    }

    private var earShape: some View {
        ZStack {
            Circle().fill(furColor).frame(width: size * 0.32, height: size * 0.32)
            Circle().fill(innerEarColor).frame(width: size * 0.15, height: size * 0.15)
        }
    }

    private var head: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [furColor, furShadowColor],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: size * 0.86, height: size * 0.86)
    }

    private var muzzleGroup: some View {
        VStack(spacing: size * 0.015) {
            Ellipse()
                .fill(muzzleColor)
                .frame(width: size * 0.48, height: size * 0.36)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: size * 0.03)
                        .fill(darkColor)
                        .frame(width: size * 0.13, height: size * 0.08)
                        .offset(y: size * 0.04)
                }
            mouthShape
                .frame(width: size * 0.22, height: size * 0.09)
        }
        .offset(y: size * 0.20)
    }

    @ViewBuilder
    private var mouthShape: some View {
        switch expression {
        case .happy, .sleepy:
            SmileShape(openness: 0.15)
                .stroke(darkColor, style: StrokeStyle(lineWidth: size * 0.018, lineCap: .round))
        case .expired:
            Rectangle()
                .fill(darkColor)
                .frame(width: size * 0.16, height: size * 0.014)
        case .celebrating:
            SmileShape(openness: 0.85)
                .fill(darkColor.opacity(0.85))
        }
    }

    private var eyesGroup: some View {
        HStack(spacing: size * 0.20) {
            eyeShape
            eyeShape
        }
        .offset(y: -size * 0.05)
    }

    @ViewBuilder
    private var eyeShape: some View {
        switch expression {
        case .happy, .celebrating:
            ZStack {
                Circle().fill(.white).frame(width: size * 0.15, height: size * 0.15)
                Circle().fill(darkColor).frame(width: size * 0.08, height: size * 0.08)
            }
            .scaleEffect(x: 1, y: blinkAmount, anchor: .center)
        case .sleepy:
            ClosedEyeArc()
                .stroke(darkColor, style: StrokeStyle(lineWidth: size * 0.018, lineCap: .round))
                .frame(width: size * 0.13, height: size * 0.05)
        case .expired:
            XMarkShape()
                .stroke(darkColor, style: StrokeStyle(lineWidth: size * 0.02, lineCap: .round))
                .frame(width: size * 0.13, height: size * 0.13)
        }
    }

    // MARK: - Animation

    private func handleAppear() {
        guard isAnimated else {
            appeared = true
            return
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) {
            appeared = true
        }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(0.3)) {
            breathing = true
        }
    }

    /// Randomized blink every 3-5s. `.task(id:)` cancels this automatically when the
    /// expression changes or the view disappears — no manual Timer to leak.
    private func runBlinkLoop() async {
        guard isAnimated, expression != .expired else {
            blinkAmount = 1
            return
        }
        while !Task.isCancelled {
            let delay = Double.random(in: 3...5)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.09)) { blinkAmount = 0.05 }
            try? await Task.sleep(for: .seconds(0.09))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.12)) { blinkAmount = 1 }
        }
    }
}

// MARK: - Shapes

private struct ClosedEyeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}

private struct XMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

/// Quadratic-curve smile. `openness` 0 = shallow line smile, 1 = wide open grin.
private struct SmileShape: Shape {
    var openness: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.minY + rect.height * (0.6 + 0.4 * openness))
        )
        if openness > 0.5 {
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Preview

#Preview("Expressions") {
    let expressions: [(String, BearExpression)] = [
        ("Happy", .happy), ("Sleepy", .sleepy),
        ("Expired", .expired), ("Celebrating", .celebrating)
    ]
    return VStack(spacing: 24) {
        ForEach(Array(expressions.enumerated()), id: \.offset) { _, pair in
            HStack(spacing: 24) {
                ExpiredBear(expression: pair.1, size: 100)
                Text(pair.0)
                Spacer()
            }
        }
    }
    .padding(32)
}

#Preview("Dark") {
    ExpiredBear(expression: .expired, size: 160)
        .padding(40)
        .background(Color.black)
}
