import CoreGraphics

/// Original folded-A mark in a 100×100 coordinate space, with the origin at top left.
/// Shared by SwiftUI and the standalone app-icon builder.
enum AndrodoMarkGeometry {
    static func body(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 12, y: 81))
        path.addLine(to: CGPoint(x: 39, y: 20))
        path.addQuadCurve(to: CGPoint(x: 51, y: 11), control: CGPoint(x: 43, y: 11))
        for point in [CGPoint(x: 61, y: 11), CGPoint(x: 89, y: 81), CGPoint(x: 68, y: 81),
                      CGPoint(x: 59, y: 58), CGPoint(x: 38, y: 58), CGPoint(x: 29, y: 81)] {
            path.addLine(to: point)
        }
        path.closeSubpath()
        path.move(to: CGPoint(x: 45, y: 41))
        path.addLine(to: CGPoint(x: 53, y: 41))
        path.addLine(to: CGPoint(x: 49, y: 29))
        path.closeSubpath()
        return scaled(path, into: rect)
    }

    static func fold(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 38, y: 58))
        path.addLine(to: CGPoint(x: 59, y: 58))
        path.addLine(to: CGPoint(x: 68, y: 81))
        path.addLine(to: CGPoint(x: 51, y: 81))
        path.closeSubpath()
        return scaled(path, into: rect)
    }

    private static func scaled(_ path: CGPath, into rect: CGRect) -> CGPath {
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 100, y: rect.height / 100)
        return path.copy(using: &transform)!
    }
}
