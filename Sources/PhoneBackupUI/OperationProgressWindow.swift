import AppKit
import PhoneBackupCore
import SwiftUI

/// One app-wide window, independent of the document window's authorization sheets.
public struct OperationProgressScene: Scene {
    public static let windowID = "operation-progress"
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some Scene {
        Window("Androdo — Progress", id: Self.windowID) {
            OperationProgressWindow().environment(model)
        }
        .defaultSize(width: 600, height: 440)
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

public struct OperationProgressWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingOmissionConfirmation = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: model.progressPresentation.symbol)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(AppIdentity.blue)
                    .frame(width: 58, height: 58)
                    .background(AppIdentity.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.progressPresentation.title).font(.title2.weight(.semibold))
                    Text(model.progressPresentation.phase).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)

            VStack(alignment: .leading, spacing: 14) {
                if model.progressSession?.isFinished != true {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction).accessibilityLabel("Operation progress")
                    } else {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Operation in progress")
                    }
                }
                if showsTransferCounts, let event = model.operationEvent {
                    HStack {
                        Text("\(event.progress.completedItems) of \(event.progress.totalItems.map(String.init) ?? "…") items")
                        Spacer()
                        Text(byteProgress(event.progress))
                    }
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                } else if model.progressSession?.stage == .planning {
                    Text("Checking files before copying starts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            ScrollView {
                OperationProgressDetails(showingOmissionConfirmation: $showingOmissionConfirmation)
                    .padding(.horizontal, 24).padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 10) {
                if model.progressSession?.isFinished != true {
                    Button(model.progressSession?.cancellationRequested == true ? "Cancelling…" : "Cancel") {
                        Task { await model.cancelProgress() }
                    }
                    .disabled(!model.canCancelProgress)
                    .help(model.progressSession?.stage == .starting ? "Cancellation becomes available once the transfer starts." : "Stop the current operation safely")
                }
                Spacer()
                if model.progressSession?.isFinished == true {
                    Button("Done") { model.dismissProgress() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Run in Background") { model.backgroundProgress() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .buttonStyle(.bordered).controlSize(.large)
            .padding(18)
        }
        .frame(width: 600, height: hasDetails ? 440 : 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ProgressWindowCloseObserver(model: model))
        .onChange(of: model.progressSession?.presentationID, initial: true) { _, id in
            if id == nil { dismissWindow(id: OperationProgressScene.windowID) }
        }
        .tint(AppIdentity.blue)
        .confirmationDialog("Finish this backup with skipped paths?", isPresented: $showingOmissionConfirmation, titleVisibility: .visible) {
            Button("Finish with omissions", role: .destructive) { Task { await model.finishBackupWithOmissions() } }
            Button("Keep incomplete", role: .cancel) {}
        } message: {
            Text("The restore point will be marked incomplete and will list the paths that could not be saved.")
        }
    }

    private var hasDetails: Bool {
        if model.progressSession?.failure != nil { return true }
        guard model.progressSession?.stage == .running || model.progressSession?.isFinished == true else { return false }
        return model.operationEvent?.failure != nil || model.operationEvent?.warnings.isEmpty == false ||
            model.recoveryAttempt != nil || !model.pendingAttempts.isEmpty || model.restoreResult != nil || model.copyResult != nil
    }

    private var showsTransferCounts: Bool {
        guard let session = model.progressSession else { return model.operationEvent != nil }
        return (session.stage == .running || session.isFinished) && session.failure == nil && !session.wasCancelled
    }

    private func byteProgress(_ progress: OperationProgress) -> String {
        if let total = progress.totalBytes {
            return "\(UIFormatting.bytes(progress.completedBytes)) of \(UIFormatting.bytes(total))"
        }
        return UIFormatting.bytes(progress.completedBytes)
    }
}

extension AppModel {
    /// Unknown scan/start totals remain indeterminate; never invent percentages or an ETA.
    var progressFraction: Double? {
        guard let session = progressSession, !session.cancellationRequested else { return nil }
        if session.stage == .planning, let progress = restorePlanningProgress, progress.totalItems > 0 {
            return min(1, max(0, Double(progress.completedItems) / Double(progress.totalItems)))
        }
        guard session.stage == .running, let event = operationEvent,
              event.phase != .scanning, event.phase != .planning, event.phase != .committing else { return nil }
        if let total = event.progress.totalBytes, total > 0 {
            return min(1, max(0, Double(event.progress.completedBytes) / Double(total)))
        }
        if let total = event.progress.totalItems, total > 0 {
            return min(1, max(0, Double(event.progress.completedItems) / Double(total)))
        }
        return nil
    }
}

/// Observes only the represented progress window and leaves SwiftUI's delegate intact.
private struct ProgressWindowCloseObserver: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> CloseView { CloseView() }
    func updateNSView(_ view: CloseView, context: Context) {
        view.model = model
        view.observeWindow()
    }
    static func dismantleNSView(_ view: CloseView, coordinator: ()) { view.detach() }

    final class CloseView: NSView {
        weak var model: AppModel?
        private weak var observedWindow: NSWindow?
        private var observation: NSObjectProtocol?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeWindow() }
        func observeWindow() {
            guard observedWindow !== window else { return }
            detach()
            guard let window else { return }
            observedWindow = window
            observation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Programmatic review handoff already cleared foreground intent.
                    if self?.model?.progressSession?.isPresented == true { self?.model?.backgroundProgress() }
                }
            }
        }
        func detach() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            observedWindow = nil
        }
    }
}
