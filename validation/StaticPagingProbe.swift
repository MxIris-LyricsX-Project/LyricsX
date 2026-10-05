import AppKit

@main enum StaticPagingProbe {
    static func main() {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            checks += 1; print("PASS: \(message)")
        }
        func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        let font = NSFont.systemFont(ofSize: 14)
        for text in ["终于做了这个决定，别人怎么说我不理", "we keep the words together until the final phrase", "👨‍👩‍👧‍👦🇨🇳👍🏽e\u{301}这是后面的歌词", "supercalifragilisticexpialidocious", "第一段\n第二段"] {
            let pages = NativeMarqueeView.paginate(text, font: font, width: 84)
            check(compact(pages.joined()) == compact(text), "all content survives paging: \(text)")
            check(pages.allSatisfy { ($0 as NSString).size(withAttributes: [.font: font]).width <= 84.5 }, "each page fits without clipping")
            check(!pages.isEmpty && pages.allSatisfy { !$0.isEmpty }, "no empty page")
        }
        let emoji = "👨‍👩‍👧‍👦🇨🇳👍🏽e\u{301}"
        check(NativeMarqueeView.paginate(emoji, font: font, width: 1) == emoji.map(String.init), "narrow widths never split composed characters")
        let words = NativeMarqueeView.paginate("one two three four", font: font, width: 65)
        check(words.allSatisfy { $0.split(separator: " ").allSatisfy { ["one", "two", "three", "four"].contains(String($0)) } }, "fitting English words remain whole")
        check(NativeMarqueeView.paginate("歌词", font: font, width: 0).isEmpty, "zero width is safe")
        check(NativeMarqueeView.paginate("歌词", font: font, width: .infinity).isEmpty, "invalid width is safe")

        let item = NSStatusBar.system.statusItem(withLength: 84)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let view = NativeMarqueeView(frame: NSRect(x: 0, y: 0, width: 84, height: 22))
        item.button!.addSubview(view)
        view.frameRate = 0
        let lyric = "一二三四五六七八九十十一十二"
        view.setStringValue(lyric, lineDisplayTime: 2.4)
        func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        check(view.staticPageCount > 1 && view.isPaging && !view.isAnimating, "long static lyric has a page deadline, not continuous animation")
        let first = view.visibleString, builds = view.bitmapBuildCount
        pump(0.1)
        check(view.visibleString == first && view.bitmapBuildCount == builds && view.currentTextOffset == 0, "holding a page does not move or rerasterize it")
        view.setPlaybackPaused(true); pump(0.9)
        check(!view.isPaging && view.visibleString == first, "pause freezes the current page and cancels deadlines")
        view.setPlaybackPaused(false)
        var visited = [view.visibleString]
        var stationary = true
        let end = Date().addingTimeInterval(2.6)
        while Date() < end {
            pump(0.03)
            if visited.last != view.visibleString { visited.append(view.visibleString) }
            stationary = stationary && !view.visibleString.isEmpty && view.currentTextOffset == 0
        }
        check(stationary, "page transition stays nonempty and stationary")
        check(compact(visited.joined()) == compact(lyric), "every page including the lyric ending appears after resume")
        check(view.currentPageIndex == view.staticPageCount - 1 && !view.isPaging, "last page remains visible without further timers")
        let final = view.visibleString
        view.setStringValue(lyric, lineDisplayTime: 2.4)
        check(view.visibleString == final && !view.isPaging, "duplicate updates do not restart completed paging")
        view.setStringValue(lyric + "新句", lineDisplayTime: 4)
        check(view.currentPageIndex == 0 && view.isPaging, "new lyric starts at page zero")
        view.removeFromSuperview()
        check(!view.isPaging, "detaching cancels the page timer")
        item.button!.addSubview(view)
        check(view.isPaging, "reattaching resumes paging")
        view.isHidden = true
        check(!view.isPaging, "hiding cancels paging")
        view.isHidden = false
        check(view.isPaging, "showing schedules the next page")
        view.setFrameSize(NSSize(width: 1000, height: 22))
        check(view.staticPageCount == 1 && view.visibleString == lyric + "新句" && !view.isPaging, "widening shows the complete lyric and cancels paging")
        view.setFrameSize(NSSize(width: 84, height: 22))
        check(view.staticPageCount > 1 && view.isPaging, "narrowing repaginates the current lyric")
        view.frameRate = 30
        check(view.visibleString == view.stringValue && !view.isPaging, "scroll mode restores full text and cancels page deadlines")
        view.frameRate = 0
        check(view.currentPageIndex == 0 && view.isPaging, "switching back starts stationary pages")
        view.setStringValue("短句", lineDisplayTime: 2)
        check(view.visibleString == "短句" && !view.isPaging && !view.isAnimating, "short static text needs no timer")
        view.setStringValue("", lineDisplayTime: .nan)
        check(view.visibleString.isEmpty && !view.isPaging, "empty or invalid input clears safely")
        print("\(checks) static paging checks passed")
    }
}
