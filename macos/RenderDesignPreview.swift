import AppKit
import SwiftUI

// Compile with PhoneBackupIdentity.swift and DeviceBackupHero.swift.
// This renderer has no AppModel, transport, repository or phone access.
@main
struct RenderDesignPreview {
    @MainActor
    static func main() throws {
        let dark = CommandLine.arguments.contains("--dark")
        var data: Data?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let view = OverviewDesignPreview().environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.cgImage {
                data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        guard let data else { fatalError("Could not render design preview") }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
