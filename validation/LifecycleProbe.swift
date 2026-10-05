import AppKit

@main
struct LifecycleProbe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: 183)
        let view = NativeMarqueeView(frame: NSRect(x: 0, y: 0, width: 183, height: 22))
        item.button!.addSubview(view)

        func pump(_ duration: TimeInterval) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
        }
        func check(_ condition: Bool, _ description: String) {
            guard condition else { fatalError(description) }
            print("PASS: \(description)")
        }

        view.setStringValue("短歌词", lineDisplayTime: 1)
        check(!view.isAnimating, "short text does not schedule animation")
        let long = "原生菜单栏歌词滚动生命周期验证：暂停恢复隐藏切换时保持时间和位置一致"
        view.setStringValue(long, lineDisplayTime: 2)
        pump(0.7)
        let offset = view.currentTextOffset
        check(offset < 0 && view.isAnimating, "long text starts scrolling")
        let builds = view.bitmapBuildCount
        view.setStringValue(long, lineDisplayTime: 2)
        check(view.bitmapBuildCount == builds && view.currentTextOffset == offset,
              "duplicate update preserves cached text and scroll position")

        view.setPlaybackPaused(true)
        let pausedOffset = view.currentTextOffset
        pump(0.3)
        check(!view.isAnimating && view.currentTextOffset == pausedOffset, "pause freezes scroll and stops timer")
        view.setPlaybackPaused(false)
        pump(0.2)
        check(view.isAnimating && view.currentTextOffset < pausedOffset, "resume continues scroll")

        view.removeFromSuperview()
        check(!view.isAnimating, "detaching native status view stops timer")
        item.button!.addSubview(view)
        check(view.isAnimating, "reattaching resumes the current line")
        view.isHidden = true
        pump(0.1)
        check(!view.isAnimating, "hidden view stops timer")
        view.isHidden = false
        check(view.isAnimating, "unhidden view resumes")
        pump(1.5)
        check(!view.isAnimating, "completed scroll stops timer")

        view.setStringValue(long + "第二句", lineDisplayTime: 2)
        view.setFrameSize(NSSize(width: 2000, height: 22))
        check(!view.isAnimating && view.currentTextOffset > 0, "resizing to fit centers text without animation")
        view.setFrameSize(NSSize(width: 183, height: 22))
        check(view.isAnimating, "resizing to overflow schedules animation")
        view.setStringValue("", lineDisplayTime: .nan)
        check(!view.isAnimating && view.stringValue.isEmpty, "empty text and invalid duration stop safely")
        view.frameRate = 0
        view.setStringValue(long + "静态模式", lineDisplayTime: 2)
        pump(0.15)
        check(!view.isAnimating && view.isPaging && view.currentTextOffset == 0, "static long lyric starts discrete paging without a scroll timer")
        let staticBuilds = view.bitmapBuildCount
        view.setStringValue(long + "静态换句", lineDisplayTime: 2)
        check(view.bitmapBuildCount == staticBuilds + 1 && !view.isAnimating && view.isPaging,
              "static lyric changes reset the page without starting scroll animation")
        view.frameRate = 30
        pump(0.7)
        check(view.isAnimating && view.currentTextOffset < 0, "switching from static starts current lyric scrolling")
        let rateBuilds = view.bitmapBuildCount
        for rate in [24.0, 30, 60, 90, 120] {
            view.frameRate = rate
            pump(0.02)
            check(view.isAnimating && view.bitmapBuildCount == rateBuilds,
                  "changing to \(rate) fps retains scrolling and cached text")
        }
        view.frameRate = 0
        pump(0.1)
        check(!view.isAnimating && view.currentTextOffset == 0, "switching to static resets to the first page and stops scrolling")
        view.setPlaybackPaused(true)
        view.frameRate = 60
        check(!view.isAnimating && view.currentTextOffset == 0, "changing rate does not resume paused playback")
        view.setPlaybackPaused(false)
        pump(0.7)
        check(view.isAnimating && view.currentTextOffset < 0, "paused static-to-scroll switch resumes correctly with playback")
        NSStatusBar.system.removeStatusItem(item)
    }
}
