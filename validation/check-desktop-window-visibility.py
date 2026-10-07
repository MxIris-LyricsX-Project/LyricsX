"""Exercise production visibility methods with a real NSWindow, without song/network dependencies."""
from pathlib import Path
import subprocess
import re
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'LyricsX/Controller/KaraokeLyricsController.swift').read_text()
start = source.index('    override func showWindow(')
end = source.index('    private func updateWindowFrame(', start)
methods = source[start:end].replace('private func ', 'func ')
geometry_start = source.index('    static func lyricWindowFrame(')
geometry_end = source.index('    // Mirrors the Cocoa', geometry_start)
geometry = source[geometry_start:geometry_end]
behavior = re.search(r'window.collectionBehavior = (\[[^\n]+\])', source).group(1)
assert 'contentView?.bind(.hidden' not in source
assert 'observeDefaults(key: .desktopLyricsEnabled' in source
temporary = tempfile.TemporaryDirectory(prefix='LyricsXDesktopChecks-')
folder = Path(temporary.name)
probe = '''import AppKit
struct Settings {
    enum Key { case desktopLyricsEnabled }
    var enabled = false
    subscript(_ key: Key) -> Bool { enabled }
}
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(range.upperBound, max(range.lowerBound, self)) }
}
var defaults = Settings()
struct LyricsLine { struct Attachments { typealias RangeAttribute = String } }
final class LyricsViewStub {
    func displayLrc(_ first: String, secondLine: String, firstLineFurigana: String? = nil, secondLineFurigana: String? = nil) {}
}
final class Controller: NSWindowController {
    var lyricsView = LyricsViewStub()
    var windowHasContent = false
    func updateWindowFrame(animate: Bool) {}
GEOMETRY
METHODS
}
_ = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
window.isReleasedWhenClosed = false
window.backgroundColor = .clear
window.isOpaque = false
window.sharingType = .none
window.collectionBehavior = BEHAVIOR
let controller = Controller(window: window)
var checks = 0
func check(_ value: Bool, _ message: String) {
    precondition(value, message)
    checks += 1
    print("PASS: " + message)
}
check(window.collectionBehavior.contains(.transient) && !window.collectionBehavior.contains(.stationary), "Mission Control uses system transient hiding instead of a stationary overlay")
check(window.collectionBehavior.contains(.canJoinAllSpaces), "desktop lyrics remain available across Spaces")
controller.displayLyrics("LyricsX")
controller.showWindow(nil)
check(!window.isVisible, "disabled startup never orders in the protected window")
controller.displayLyrics("new song")
check(!window.isVisible, "incoming lyrics cannot display a disabled window")
defaults.enabled = true
controller.updateWindowVisibility()
check(window.isVisible, "enabled lyrics can display")
defaults.enabled = false
controller.updateWindowVisibility()
check(!window.isVisible, "disable orders the whole window out immediately")
defaults.enabled = true
controller.displayLyrics("")
check(!window.isVisible, "empty lyrics stay out even when enabled")
controller.displayLyrics("   ", secondLine: "\\n")
check(!window.isVisible, "whitespace does not leave an invisible window")
controller.displayLyrics("", secondLine: "translation")
check(window.isVisible, "a nonempty second line can display")
controller.displayLyrics("")
check(!window.isVisible, "clearing a previously visible line removes its window")
controller.showWindow(nil)
check(!window.isVisible, "external showWindow cannot bypass empty content")
controller.displayLyrics("resumed")
check(window.isVisible, "new content restores the window after pause or clear")
check(window.sharingType == .none, "screenshot exclusion preference is preserved")
let area = NSRect(x: -1800, y: 39, width: 1800, height: 1130)
let compact = Controller.lyricWindowFrame(contentSize: NSSize(width: 320, height: 80), in: area, xFactor: 0.5, yFactor: 0.9)
check(compact.size == NSSize(width: 320, height: 80), "desktop window is content-sized, not screen-sized")
check(compact.midX == area.midX && abs(compact.midY - (area.maxY - area.height * 0.9)) < 0.01, "relative position survives a nonzero or negative screen origin")
for x: CGFloat in [0, 1] {
    for y: CGFloat in [0, 1] {
        let edge = Controller.lyricWindowFrame(contentSize: NSSize(width: 320, height: 80), in: area, xFactor: x, yFactor: y)
        check(area.contains(edge), "lyrics remain within the screen at position \\(x), \\(y)")
    }
}
let oversized = Controller.lyricWindowFrame(contentSize: NSSize(width: 10000, height: 10000), in: area, xFactor: -1, yFactor: 2)
check(oversized == area, "oversized lyrics and out-of-range positions are bounded")
let invalid = Controller.lyricWindowFrame(contentSize: NSSize(width: CGFloat.infinity, height: CGFloat.nan), in: area, xFactor: .nan, yFactor: .infinity)
check(invalid.width == 1 && invalid.height == 1 && area.contains(invalid), "nonfinite geometry remains safe")
window.orderOut(nil)
print("\\(checks) desktop window checks passed")
'''.replace('METHODS', methods).replace('BEHAVIOR', behavior).replace('GEOMETRY', geometry)
path = folder / 'VisibilityProbe.swift'
path.write_text(probe)
subprocess.run(['xcrun','swiftc','-module-cache-path',str(folder/'ModuleCache'),str(path),'-o',str(folder/'VisibilityProbe')],check=True)
subprocess.run([str(folder/'VisibilityProbe')],check=True)
