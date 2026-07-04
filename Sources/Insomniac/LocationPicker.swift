import SwiftUI
import AppKit
import CoreGraphics

@MainActor
final class LocationPickerManager {
    static let shared = LocationPickerManager()
    private var windows: [PickerWindow] = []
    
    private init() {}
    
    func startPicking(onSelect: @escaping (CGPoint) -> Void) {
        close()
        
        for screen in NSScreen.screens {
            let window = PickerWindow(screen: screen) { [weak self] point in
                DispatchQueue.main.async {
                    onSelect(point)
                    self?.close()
                }
            } onCancel: { [weak self] in
                DispatchQueue.main.async {
                    self?.close()
                }
            }
            window.isReleasedWhenClosed = false
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func close() {
        for window in windows {
            window.close()
        }
        windows.removeAll()
    }
}

class PickerWindow: NSWindow {
    var onSelect: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    
    init(screen: NSScreen, onSelect: @escaping (CGPoint) -> Void, onCancel: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .statusBar
        self.backgroundColor = NSColor.black.withAlphaComponent(0.4)
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        
        let contentView = NSHostingView(rootView: PickerOverlayView(onCancel: onCancel))
        self.contentView = contentView
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override func mouseDown(with event: NSEvent) {
        if let cgPoint = CGEvent(source: nil)?.location {
            onSelect?(cgPoint)
        } else {
            let mouseLocation = NSEvent.mouseLocation
            if let primaryScreen = NSScreen.screens.first {
                let cgPoint = CGPoint(x: mouseLocation.x, y: primaryScreen.frame.height - mouseLocation.y)
                onSelect?(cgPoint)
            }
        }
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc key
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

struct PickerOverlayView: View {
    let onCancel: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.1)
            
            VStack(spacing: 16) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                
                Text("Select Click Location")
                    .font(.headline)
                    .foregroundStyle(.white)
                
                Text("Click anywhere on the screen to set the target.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                
                Text("Press ESC to cancel")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            .frame(maxWidth: 320)
        }
        .edgesIgnoringSafeArea(.all)
    }
}
