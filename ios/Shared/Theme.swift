import SwiftUI

/// "Future 2000": a late-90s DJ shop meets Y2K chrome. Midnight navy, brushed chrome, LCD cyan,
/// safety orange and acid lime.
enum Theme {
    static let bg = Color(red: 0.027, green: 0.035, blue: 0.059)
    static let panel = Color(red: 0.059, green: 0.078, blue: 0.118)
    static let panel2 = Color(red: 0.078, green: 0.106, blue: 0.157)
    static let line = Color(red: 0.149, green: 0.188, blue: 0.267)
    static let orange = Color(red: 1.0, green: 0.416, blue: 0.075)
    static let cyan = Color(red: 0.184, green: 0.839, blue: 1.0)
    static let lime = Color(red: 0.722, green: 1.0, blue: 0.231)
    static let amber = Color(red: 1.0, green: 0.824, blue: 0.247)
    static let lcd = Color(red: 0.016, green: 0.071, blue: 0.102)
    static let lcdLine = Color(red: 0.063, green: 0.224, blue: 0.290)
    static let lcdDim = Color(red: 0.31, green: 0.56, blue: 0.64)
    static let dim = Color(red: 0.5, green: 0.55, blue: 0.64)

    static let chrome = LinearGradient(stops: [
        .init(color: Color(white: 0.96), location: 0),
        .init(color: Color(red: 0.80, green: 0.83, blue: 0.86), location: 0.42),
        .init(color: Color(red: 0.56, green: 0.59, blue: 0.64), location: 0.52),
        .init(color: Color(red: 0.79, green: 0.81, blue: 0.85), location: 0.78),
        .init(color: Color(white: 0.94), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    static let glow = LinearGradient(colors: [Color(red: 1, green: 0.69, blue: 0.48), orange,
                                              Color(red: 0.93, green: 0.32, blue: 0)],
                                     startPoint: .top, endPoint: .bottom)

    /// Wide, techy display type (SF expanded): the Eurostile look of late-90s gear.
    static func wide(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
    /// LCD digits.
    static func lcdFont(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

/// Midnight background with a faint cyan grid and two soft glows.
struct ThemeBackground: View {
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.cyan.opacity(0.12), .clear], center: UnitPoint(x: 0.1, y: -0.1), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.orange.opacity(0.10), .clear], center: UnitPoint(x: 1.0, y: 0.0), startRadius: 0, endRadius: 420)
            Canvas { ctx, size in
                var p = Path()
                let step: CGFloat = 28
                var x: CGFloat = 0
                while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                ctx.stroke(p, with: .color(Theme.cyan.opacity(0.045)), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
    }
}

/// A panel with a hairline highlight and an orange-to-cyan accent line along the top.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Theme.panel2, Theme.panel], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [Theme.orange, .clear, .clear, Theme.cyan], startPoint: .leading, endPoint: .trailing)
                            .frame(height: 2).opacity(0.55).padding(.horizontal, 16)
                    }
            )
    }
}

/// Chrome pill (inactive) or glowing lime pill (active), like a late-90s mixer button.
struct ChromeButtonStyle: ButtonStyle {
    var lit = false
    var litColor: Color = Theme.lime
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.wide(11, .bold))
            .textCase(.uppercase)
            .foregroundStyle(Color(red: 0.06, green: 0.075, blue: 0.1))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                Capsule().fill(lit ? AnyShapeStyle(litColor) : AnyShapeStyle(Theme.chrome))
                    .overlay(Capsule().stroke(Color(red: 0.36, green: 0.4, blue: 0.45), lineWidth: 1))
                    .shadow(color: lit ? litColor.opacity(0.5) : .black.opacity(0.5), radius: lit ? 8 : 3, y: lit ? 0 : 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
