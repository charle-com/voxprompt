import SwiftUI

enum VPPalette {
    static let background  = Color(red: 0.985, green: 0.985, blue: 0.99)
    static let surface     = Color.black.opacity(0.04)
    static let surfaceHi   = Color.black.opacity(0.06)
    static let border      = Color.black.opacity(0.08)
    static let borderHi    = Color.black.opacity(0.12)

    static let accent      = Color(red: 0.40, green: 0.33, blue: 0.98)
    static let accentSoft  = Color(red: 0.40, green: 0.33, blue: 0.98).opacity(0.14)

    static let live        = Color(red: 0.92, green: 0.28, blue: 0.36)
    static let work        = Color(red: 0.94, green: 0.66, blue: 0.20)
    static let ok          = Color(red: 0.18, green: 0.72, blue: 0.44)

    static let textPrimary = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let textSecond  = Color(red: 0.36, green: 0.36, blue: 0.40)
    static let textTert    = Color(red: 0.55, green: 0.55, blue: 0.60)
    static let textFaint   = Color(red: 0.72, green: 0.72, blue: 0.76)

    // HUD-specific (garde un fond légèrement contrasté pour lisibilité over any backdrop)
    static let hudFill     = Color.white.opacity(0.86)
    static let hudBorder   = Color.black.opacity(0.06)
    static let hudBar      = Color(red: 0.07, green: 0.07, blue: 0.09)
}

enum VPType {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct SoftDot: View {
    var color: Color
    var size: CGFloat = 6
    var pulsing: Bool = false
    @State private var pulse: CGFloat = 0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 2)
                    .scaleEffect(1 + pulse * 1.6)
                    .opacity(1 - pulse)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    pulse = 1
                }
            }
    }
}
