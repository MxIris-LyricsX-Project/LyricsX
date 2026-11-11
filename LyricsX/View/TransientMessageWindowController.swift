import AppKit

/// A small, self-dismissing message panel.
///
/// It exists because a menu-bar app has nowhere to acknowledge a global
/// shortcut: the key is pressed while another app is frontmost, and without a
/// visible reply the user cannot tell a working shortcut from a dead one.
///
/// Deliberately not named "HUD" — `LyricsHUDViewController` is the persistent
/// lyrics panel, and reusing that word for a one-and-a-half-second toast would
/// confuse both.
@MainActor
final class TransientMessageWindowController: NSWindowController {
    static let shared = TransientMessageWindowController()

    private static let horizontalPadding: CGFloat = 18
    private static let verticalPadding: CGFloat = 12
    private static let cornerRadius: CGFloat = 10
    private static let fadeOutDuration: TimeInterval = 0.25
    /// Height above the bottom of the screen, as a fraction of its height —
    /// clear of the Dock without landing in the middle of what the user is
    /// looking at.
    private static let verticalPositionRatio: CGFloat = 0.15

    private let messageLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// Owns the whole dismissal — the visible dwell and the fade that follows —
    /// so a re-presentation cancels both halves in one move and cannot be
    /// ordered out by the fade it interrupted.
    private var dismissalTask: Task<Void, Never>?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        super.init(window: panel)

        let backgroundView = NSVisualEffectView()
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = Self.cornerRadius
        backgroundView.layer?.masksToBounds = true
        backgroundView.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: Self.horizontalPadding),
            backgroundView.trailingAnchor.constraint(equalTo: messageLabel.trailingAnchor, constant: Self.horizontalPadding),
            messageLabel.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: Self.verticalPadding),
            backgroundView.bottomAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: Self.verticalPadding),
        ])

        panel.contentView = backgroundView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(message: String, dismissAfter duration: TimeInterval = 1.5) {
        guard let window else {
            return
        }
        dismissalTask?.cancel()

        messageLabel.stringValue = message
        window.contentView?.layoutSubtreeIfNeeded()
        if let fittingSize = window.contentView?.fittingSize {
            window.setContentSize(fittingSize)
        }
        moveToPresentationPosition(window)

        // Drive alpha through a zero-length animation rather than assigning it:
        // a fade from the previous presentation may still be in flight, and a
        // plain assignment would be overwritten by its next frame.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1
        }
        // `orderFrontRegardless` rather than `orderFront`: the app is an
        // LSUIElement and is never the active one when a global shortcut fires.
        window.orderFrontRegardless()

        dismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else {
                return
            }
            // The async overload returns once the fade has finished playing, so
            // the panel is ordered out only after it is actually invisible.
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeOutDuration
                window.animator().alphaValue = 0
            }
            guard !Task.isCancelled else {
                return
            }
            self.window?.orderOut(nil)
        }
    }

    private func moveToPresentationPosition(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screenFrame = screen?.visibleFrame else {
            return
        }
        window.setFrameOrigin(NSPoint(
            x: screenFrame.midX - window.frame.width / 2,
            y: screenFrame.minY + screenFrame.height * Self.verticalPositionRatio
        ))
    }
}
