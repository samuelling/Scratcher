import SwiftUI

/// Synth-screen theme, shared with Gain Control: a black screen, thin 1.5 pt line art, almost no fill except a few
/// key objects, and a crisp palette (pale white, coral red, periwinkle blue, mint green, amber, violet). Type is
/// condensed and uppercase.
enum Theme {
    static let bg = Color.black
    static let ink = Color(hex: 0xE9E6FF)        // W
    static let red = Color(hex: 0xFF3B5C)        // R
    static let blue = Color(hex: 0x6B8CFF)       // B
    static let green = Color(hex: 0x00E39A)      // G
    static let amber = Color(hex: 0xFFB547)      // A
    static let violet = Color(hex: 0x9C7BFF)     // V
    static let dim = Color(hex: 0x7B7890)        // M
    static let line = Color(hex: 0x3A3842)       // D
    static let deep = Color(hex: 0x36346E)       // N
    static let stroke: CGFloat = 1.5

    // older names used around the app
    static let orange = red
    static let cyan = blue
    static let lime = green
    static let panel = Color.black
    static let lcd = Color.black
    static let lcdLine = line
    static let lcdDim = dim
    static let chrome = ink

    /// Condensed display type.
    static func wide(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
    /// Numbers: condensed with fixed-width digits.
    static func lcdFont(_ size: CGFloat) -> Font { .system(size: size, weight: .medium).width(.condensed).monospacedDigit() }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The black screen.
struct ThemeBackground: View {
    var body: some View { Color.black.ignoresSafeArea() }
}

/// An outlined panel.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(14)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: Theme.stroke))
    }
}

/// Outlined button; filled in ink when lit.
struct ChromeButtonStyle: ButtonStyle {
    var lit = false
    var litColor: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.wide(13, .semibold)).textCase(.uppercase).kerning(1)
            .foregroundStyle(lit || configuration.isPressed ? Color.black : Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(lit || configuration.isPressed ? litColor : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(lit ? litColor : Theme.ink, lineWidth: Theme.stroke))
    }
}
