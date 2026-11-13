import AppKit
import SwiftUI

/// Decorative brand colors. Warnings, text and control surfaces use system colors.
enum AppIdentity {
    static let brandBlue = Color(red: 0.20, green: 0.40, blue: 0.79)
    static let brandTeal = Color(red: 0.18, green: 0.56, blue: 0.59)
    static let brandCopper = Color(red: 0.70, green: 0.43, blue: 0.25)

    static let blue = adaptive(light: (0.20, 0.40, 0.79), dark: (0.48, 0.70, 1.0),
                               highContrastLight: (0.10, 0.27, 0.59), highContrastDark: (0.68, 0.82, 1.0))
    static let teal = adaptive(light: (0.18, 0.56, 0.59), dark: (0.40, 0.75, 0.76),
                               highContrastLight: (0.08, 0.38, 0.40), highContrastDark: (0.62, 0.88, 0.89))
    static let copper = adaptive(light: (0.70, 0.43, 0.25), dark: (0.90, 0.66, 0.44),
                                 highContrastLight: (0.48, 0.26, 0.12), highContrastDark: (1.0, 0.80, 0.61))

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double),
                                 highContrastLight: (Double, Double, Double), highContrastDark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let values: (Double, Double, Double)
            switch appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua]) {
            case .accessibilityHighContrastDarkAqua: values = highContrastDark
            case .accessibilityHighContrastAqua: values = highContrastLight
            case .darkAqua: values = dark
            default: values = light
            }
            return NSColor(srgbRed: values.0, green: values.1, blue: values.2, alpha: 1)
        })
    }
}

struct AppMark: View {
    var onTile = false

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path(AndrodoMarkGeometry.body(in: rect))
                .fill(onTile ? AnyShapeStyle(.white) : AnyShapeStyle(LinearGradient(
                    colors: [AppIdentity.blue, AppIdentity.teal], startPoint: .topLeading, endPoint: .bottomTrailing)),
                      style: FillStyle(eoFill: true))
            Path(AndrodoMarkGeometry.fold(in: rect))
                .fill(onTile ? AppIdentity.brandCopper : AppIdentity.copper)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct AppEmblem: View {
    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: proxy.size.width * 0.24)
                .fill(LinearGradient(colors: [AppIdentity.brandBlue, AppIdentity.brandTeal], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { AppMark(onTile: true).padding(proxy.size.width * 0.13) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// An Android-neutral illustration; it never displays or reads device content.
struct DeviceIllustration: View {
    var connected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13)
                .fill(.background)
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.12)) }
            RoundedRectangle(cornerRadius: 8)
                .fill(AppIdentity.blue.opacity(0.10)).padding(6)
            Capsule().fill(.secondary.opacity(0.6)).frame(width: 14, height: 3).offset(y: -42)
            Image(systemName: "cable.connector")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(connected ? AppIdentity.teal : Color.secondary)
        }
        .frame(width: 60, height: 104)
        .accessibilityHidden(true)
    }
}

struct SidebarGlyph: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: 20)
            .accessibilityHidden(true)
    }
}
