import AppKit
import Testing
import LyricsXFoundation
@testable import AppleMusicLyricsPanel

/// Who moves the panel window while it is dragged.
///
/// The window server drags a window by itself from the strip its title bar and
/// toolbar cover, and the panel's root view does not take that strip away from
/// it: under a title bar, AppKit leaves a view out of the window server's drag
/// region only when the view accepts first responder and handles `mouseDown`
/// itself. So a press there has to leave the move to the window server. When
/// the panel moved the window from there too, the two fought over it and the
/// window jittered back and forth under the pointer. Anywhere else nothing else
/// moves the window, and the panel follows the pointer itself.
///
/// The events go straight to the root view's mouse handlers, so no window server
/// drag starts here: the window stays where it is unless the panel moves it.
@MainActor
struct PanelWindowDragTests {
    @Test func aDragFromTheTitleBarLeavesTheMoveToTheWindowServer() throws {
        let mounted = try MountedPanel()

        // 15 pt below the top edge, where the recorded jittering drag held it.
        try mounted.press(at: NSPoint(x: 300, y: mounted.window.frame.height - 15))
        try mounted.dragPointer(toOffsetFromPress: NSSize(width: 40, height: -12))
        try mounted.dragPointer(toOffsetFromPress: NSSize(width: 90, height: -20))

        #expect(mounted.window.frame.origin == mounted.originBeforePress)
        // The backdrop holds still during any drag, whoever moves the window.
        #expect(mounted.draggingChanges == [true])

        try mounted.release()
        #expect(mounted.draggingChanges == [true, false])
    }

    @Test func aDragFromBelowTheTitleBarMovesTheWindowWithThePointer() throws {
        let mounted = try MountedPanel()

        try mounted.press(at: NSPoint(x: 300, y: mounted.window.contentLayoutRect.midY))
        try mounted.dragPointer(toOffsetFromPress: NSSize(width: 40, height: -12))
        try mounted.dragPointer(toOffsetFromPress: NSSize(width: 90, height: -20))

        let expectedOrigin = NSPoint(x: mounted.originBeforePress.x + 90, y: mounted.originBeforePress.y - 20)
        #expect(mounted.window.frame.origin == expectedOrigin)
        #expect(mounted.draggingChanges == [true])

        try mounted.release()
        #expect(mounted.draggingChanges == [true, false])
    }
}

/// The panel's root view as the content view of a window configured like the
/// panel's (title bar, empty toolbar, full-size content), never put on screen.
@MainActor
private final class MountedPanel {
    let window: NSWindow
    let rootView: AppleMusicLyrics.DraggablePanelView
    let originBeforePress: NSPoint
    private(set) var draggingChanges: [Bool] = []

    private var pointerLocation = NSPoint.zero
    private var pointerLocationAtPress = NSPoint.zero

    init() throws {
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 980, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        AppleMusicLyricsWindowConfiguration.apply(to: window)
        rootView = AppleMusicLyrics.DraggablePanelView()
        window.contentView = rootView
        originBeforePress = window.frame.origin

        // Without the strip the title-bar test would pass for nothing.
        try #require(
            window.contentLayoutRect.maxY < window.frame.height - 20,
            "no title bar strip: content layout rect \(window.contentLayoutRect) in a window \(window.frame.height) pt tall"
        )

        rootView.currentPointerLocation = { [unowned self] in pointerLocation }
        rootView.onWindowDraggingChanged = { [unowned self] isDragging in draggingChanges.append(isDragging) }
    }

    func press(at locationInWindow: NSPoint) throws {
        pointerLocation = window.convertPoint(toScreen: locationInWindow)
        pointerLocationAtPress = pointerLocation
        rootView.mouseDown(with: try mouseEvent(.leftMouseDown))
    }

    func dragPointer(toOffsetFromPress offset: NSSize) throws {
        pointerLocation = NSPoint(
            x: pointerLocationAtPress.x + offset.width,
            y: pointerLocationAtPress.y + offset.height
        )
        rootView.mouseDragged(with: try mouseEvent(.leftMouseDragged))
    }

    func release() throws {
        rootView.mouseUp(with: try mouseEvent(.leftMouseUp))
    }

    private func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: window.convertPoint(fromScreen: pointerLocation),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}
