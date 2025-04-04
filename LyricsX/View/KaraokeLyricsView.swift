//
//  KaraokeLyricsView.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import SnapKit
import OSLog

class KaraokeLyricsView: NSView {
    
//    static let logger = Logger(subsystem: "com.JH.LyricsX", category: "\(KaraokeLyricsView.self)")
    
    private let backgroundView: NSView
    private let stackView: NSStackView
    
    @objc dynamic var isVertical = false {
        didSet {
            stackView.orientation = isVertical ? .horizontal : .vertical
            (isVertical ? displayLine2 : displayLine1).map { stackView.insertArrangedSubview($0, at: 0) }
            updateFontSize()
        }
    }
    
    @objc dynamic var drawFurigana = false
    @objc dynamic var drawRomajin = false
    
    @objc dynamic var font = NSFont.labelFont(ofSize: 24) { didSet { updateFontSize() } }
    @objc dynamic var textColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)
    @objc dynamic var shadowColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)
    @objc dynamic var progressColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)
    @objc dynamic var backgroundColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.6018835616) {
        didSet {
            backgroundView.layer?.backgroundColor = backgroundColor.cgColor
        }
    }
    
    @objc dynamic var shouldHideWithMouse = true {
        didSet {
            updateTrackingAreas()
        }
    }
    
    var displayLine1: KaraokeLabel?
    var displayLine2: KaraokeLabel?
    
    override init(frame frameRect: NSRect) {
        stackView = NSStackView(frame: frameRect)
        stackView.orientation = .vertical
        stackView.autoresizingMask = [.width, .height]
        backgroundView = NSView() //NSVisualEffectView(frame: frameRect)
//        backgroundView.material = .dark
//        backgroundView.state = .active
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(backgroundView)
        backgroundView.addSubview(stackView)
        backgroundView.layer?.cornerRadius = 12
    }
    
    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func updateFontSize() {
        var insetX = font.pointSize
        var insetY = insetX / 3
        if isVertical {
            (insetX, insetY) = (insetY, insetX)
        }
        stackView.snp.remakeConstraints {
            $0.edges.equalToSuperview().inset(NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX))
        }
        stackView.spacing = font.pointSize / 3
        backgroundView.layer?.cornerRadius = font.pointSize / 2
//        cornerRadius = font.pointSize / 2
    }
    
    private func lyricsLabel(_ content: String) -> KaraokeLabel {
        if let view = stackView.subviews.lazy.compactMap({ $0 as? KaraokeLabel }).first(where: { !stackView.arrangedSubviews.contains($0) }) {
            view.alphaValue = 0
            view.stringValue = content
            view.removeProgressAnimation()
            view.removeFromSuperview()
            return view
        }
        return KaraokeLabel(labelWithString: content).then {
            $0.bind(\.font, to: self, withKeyPath: \.font)
            $0.bind(\.textColor, to: self, withKeyPath: \.textColor)
            $0.bind(\.progressColor, to: self, withKeyPath: \.progressColor)
            $0.bind(\._shadowColor, to: self, withKeyPath: \.shadowColor)
            $0.bind(\.isVertical, to: self, withKeyPath: \.isVertical)
            $0.bind(\.drawFurigana, to: self, withKeyPath: \.drawFurigana)
            $0.bind(\.drawRomajin, to: self, withKeyPath: \.drawRomajin)
            $0.alphaValue = 0
        }
    }
    
    func displayLrc(_ firstLine: String, secondLine: String = "") {
//        Self.logger.info("\(firstLine) \(secondLine)")
        var toBeHide = stackView.arrangedSubviews.compactMap { $0 as? KaraokeLabel }
        var toBeShow: [NSTextField] = []
        var shouldHideAll = false
        
        let index = isVertical ? 0 : 1
        if firstLine.trimmingCharacters(in: .whitespaces).isEmpty {
            displayLine1 = nil
            shouldHideAll = true
        } else if toBeHide.count == 2, toBeHide[index].stringValue == firstLine {
            displayLine1 = toBeHide[index]
            toBeHide.remove(at: index)
        } else {
            let label = lyricsLabel(firstLine)
            displayLine1 = label
            toBeShow.append(label)
        }
        
        if !secondLine.trimmingCharacters(in: .whitespaces).isEmpty {
            let label = lyricsLabel(secondLine)
            displayLine2 = label
            toBeShow.append(label)
        } else {
            displayLine2 = nil
        }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            context.timingFunction = .swiftOut
            toBeHide.forEach {
                stackView.removeArrangedSubview($0)
                $0.isHidden = true
                $0.alphaValue = 0
                $0.removeProgressAnimation()
            }
            toBeShow.forEach {
                if isVertical {
                    stackView.insertArrangedSubview($0, at: 0)
                } else {
                    stackView.addArrangedSubview($0)
                }
                $0.isHidden = false
                $0.alphaValue = 1
            }
            isHidden = shouldHideAll
            layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.mouseTest()
        })
    }
    
    // MARK: - Event
    
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
//        Self.logger.debug("\(Date()): \(#function)")
        trackingArea.map(removeTrackingArea)
        if shouldHideWithMouse {
            let trackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .assumeInside]
            trackingArea = NSTrackingArea(rect: bounds, options: trackingOptions, owner: self)
            trackingArea.map(addTrackingArea)
        }
        mouseTest()
    }
    
    private func mouseTest() {
        if shouldHideWithMouse,
            let point = NSEvent.mouseLocation(in: self),
            bounds.contains(point) {
            animator().alphaValue = 0
        } else {
            animator().alphaValue = 1
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
//        Self.logger.debug("\(Date()): \(#function)")
        if alphaValue != 0 {
            animator().alphaValue = 0
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
//        Self.logger.debug("\(Date()): \(#function)")
        animator().alphaValue = 0
    }
    
    override func mouseExited(with event: NSEvent) {
//        Self.logger.debug("\(Date()): \(#function)")
        animator().alphaValue = 1        
    }
    
}

extension NSEvent {
    
    class func mouseLocation(in view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        let windowLocation = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return view.convert(windowLocation, from: nil)
    }
}

extension NSTextField {
    
    // swiftlint:disable:next identifier_name
    @objc dynamic var _shadowColor: NSColor? {
        get {
            return shadow?.shadowColor
        }
        set {
            shadow = newValue.map { color in
                NSShadow().then {
                    $0.shadowBlurRadius = 3
                    $0.shadowColor = color
                    $0.shadowOffset = .zero
                }
            }
        }
    }
}
