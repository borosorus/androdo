import AppKit
import PhoneBackupCore
import SwiftUI

/// One leading accessory per represented window; never uses a global/key window lookup.
struct WindowTitlebarBranding: NSViewRepresentable {
    @Binding var columnVisibility: NavigationSplitViewVisibility

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window, visibility: $columnVisibility)
        }
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.attach(to: view.window, visibility: $columnVisibility)
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.detach()
    }

    final class AttachmentView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?
        private var hostingView: NSHostingView<TitlebarIdentity>?

        func attach(to newWindow: NSWindow?, visibility: Binding<NavigationSplitViewVisibility>) {
            if window !== newWindow { detach() }
            guard let newWindow else { return }
            let content = TitlebarIdentity(columnVisibility: visibility)
            if let hostingView {
                hostingView.rootView = content
                return
            }
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 175, height: 36)
            let controller = NSTitlebarAccessoryViewController()
            controller.layoutAttribute = .left
            controller.view = host
            window = newWindow
            hostingView = host
            accessory = controller
            newWindow.addTitlebarAccessoryViewController(controller)
        }

        func detach() {
            if let window, let accessory,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessory = nil
            hostingView = nil
            window = nil
        }
    }
}

private struct TitlebarIdentity: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        HStack(spacing: 8) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Image(systemName: "sidebar.leading").frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
            .help(columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
            AppMark().frame(width: 25, height: 25)
            Text(PhoneBackupCore.applicationName).font(.system(size: 16, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .fixedSize()
    }
}
