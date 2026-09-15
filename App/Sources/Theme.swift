import SwiftUI
import AppKit

enum TE {
    static let orange = Color(red: 1.0, green: 75.0 / 255.0, blue: 0.0)

    static let ground = Color(nsColor: .dynamic(
        light: NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1),
        dark: NSColor(srgbRed: 0.071, green: 0.071, blue: 0.075, alpha: 1)
    ))

    static let surface = Color(nsColor: .dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.105, green: 0.105, blue: 0.11, alpha: 1)
    ))

    static let hairline = Color(nsColor: .dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
    ))

    static let connectedGreen = Color(nsColor: .dynamic(
        light: NSColor(srgbRed: 0.10, green: 0.60, blue: 0.30, alpha: 1),
        dark: NSColor(srgbRed: 0.21, green: 0.78, blue: 0.42, alpha: 1)
    ))
}

extension NSColor {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(TE.hairline)
            .frame(height: 1)
    }
}

/// Tape-reel motif: ring, three hub holes, centre spindle.
/// Idles at a barely-perceptible crawl; spins during sync; static under Reduce Motion.
struct TapeReel: View {
    var spinning: Bool
    var size: CGFloat = 32
    var tint: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0
    @State private var rate: Double = TapeReel.idleRate

    private static let idleRate: Double = 4
    private static let spinRate: Double = 220

    var body: some View {
        TimelineView(.animation(minimumInterval: spinning ? 1 / 60 : 1 / 10, paused: reduceMotion)) { context in
            reel.rotationEffect(.degrees(angle(at: context.date)))
        }
        .frame(width: size, height: size)
        .onAppear {
            rate = spinning ? Self.spinRate : Self.idleRate
        }
        .onChange(of: spinning) { _, isSpinning in
            let now = Date().timeIntervalSinceReferenceDate
            let newRate = isSpinning ? Self.spinRate : Self.idleRate
            // Re-anchor the phase so the angle is continuous across the rate change.
            phase += (rate - newRate) * now
            rate = newRate
        }
    }

    private func angle(at date: Date) -> Double {
        guard !reduceMotion else { return 0 }
        return (phase + rate * date.timeIntervalSinceReferenceDate)
            .truncatingRemainder(dividingBy: 360)
    }

    private var reel: some View {
        ZStack {
            Circle()
                .strokeBorder(tint, lineWidth: size * 0.055)
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .strokeBorder(tint, lineWidth: size * 0.045)
                    .frame(width: size * 0.24, height: size * 0.24)
                    .offset(y: -size * 0.27)
                    .rotationEffect(.degrees(Double(index) * 120))
            }
            Circle()
                .fill(tint)
                .frame(width: size * 0.09, height: size * 0.09)
        }
        .foregroundStyle(tint)
    }
}

struct HairlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HairlineButtonBody(configuration: configuration)
    }

    private struct HairlineButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(hovering && isEnabled ? Color.primary.opacity(0.06) : Color.clear)
                )
                .overlay(Capsule().strokeBorder(TE.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIconBody(configuration: configuration)
    }

    private struct HoverIconBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering ? TE.orange : Color.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.55 : 1)
                .onHover { hovering = $0 }
        }
    }
}
