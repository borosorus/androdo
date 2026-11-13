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

struct AppEmblem: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size.width
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24)
                    .fill(LinearGradient(colors: [AppIdentity.brandBlue, AppIdentity.brandTeal], startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: size * 0.07)
                    .stroke(.white.opacity(0.95), lineWidth: size * 0.045)
                    .frame(width: size * 0.32, height: size * 0.56)
                    .offset(x: -size * 0.1, y: -size * 0.02)
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: size * 0.12, height: size * 0.025)
                    .offset(x: -size * 0.1, y: -size * 0.22)
                RoundedRectangle(cornerRadius: size * 0.045)
                    .fill(.white)
                    .frame(width: size * 0.39, height: size * 0.27)
                    .offset(x: size * 0.13, y: size * 0.20)
                Capsule().fill(AppIdentity.brandCopper)
                    .frame(width: size * 0.15, height: size * 0.035)
                    .offset(x: size * 0.13, y: size * 0.15)
            }
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
            Circle().fill(AppIdentity.teal.opacity(0.08)).frame(width: 166, height: 166)
            Circle().stroke(AppIdentity.teal.opacity(0.10), lineWidth: 1).frame(width: 196, height: 196)
            RoundedRectangle(cornerRadius: 23)
                .fill(.background)
                .shadow(color: AppIdentity.blue.opacity(0.12), radius: 12, y: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 23)
                        .strokeBorder(AppIdentity.blue.opacity(connected ? 0.8 : 0.35), lineWidth: 3)
                }
                .frame(width: 99, height: 174)
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [AppIdentity.blue.opacity(0.15), AppIdentity.teal.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 81, height: 151)
            Circle().fill(AppIdentity.blue.opacity(0.5)).frame(width: 5, height: 5).offset(y: -69)
            Image(systemName: connected ? "checkmark" : "cable.connector")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppIdentity.teal)
        }
        .frame(width: 210, height: 210)
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
