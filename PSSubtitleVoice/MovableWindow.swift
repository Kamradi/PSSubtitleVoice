import SwiftUI
import AppKit

/// Independent utility windows keep the capture preview accessible while editing.
struct MovableWindow<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let size: NSSize
    let content: Content
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let owner = context.coordinator
        owner.presentation = $isPresented
        owner.onClose = onClose
        guard isPresented else {
            owner.window?.orderOut(nil); owner.showing = false
            return
        }
        if owner.window == nil {
            let host = NSHostingController(rootView: content)
            let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            window.title = title
            window.contentViewController = host
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.hidesOnDeactivate = true
            window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            window.delegate = owner
            if let parent = view.window, let screen = parent.screen {
                let bounds = screen.visibleFrame
                let right = parent.frame.maxX + 12
                let x = right + size.width <= bounds.maxX ? right : bounds.maxX - size.width - 20
                let y = max(bounds.minY + 20, min(parent.frame.maxY - size.height - 60, bounds.maxY - size.height - 30))
                window.setFrameOrigin(NSPoint(x: max(bounds.minX, x), y: y))
            } else { window.center() }
            owner.host = host; owner.window = window
        }
        owner.window?.title = title
        owner.host?.rootView = content
        if !owner.showing {
            owner.showing = true
            owner.window?.makeKeyAndOrderFront(nil)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.window?.delegate = nil
        coordinator.window?.close()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var window: NSWindow?
        var host: NSHostingController<Content>?
        var presentation: Binding<Bool>?
        var onClose: (() -> Void)?
        var showing = false
        func windowWillClose(_ notification: Notification) {
            showing = false
            // Do not mutate SwiftUI state during a representable update.
            DispatchQueue.main.async { [weak self] in
                self?.presentation?.wrappedValue = false
                self?.onClose?()
            }
        }
    }
}
