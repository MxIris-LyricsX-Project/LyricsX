import AppKit

// These trait can be customized with Interface Builder.

extension NSMenuItem {
    @IBInspectable
    var isHiddenInMASVersion: Bool {
        get { return true }
        set {
            #if IS_FOR_MAS
            if newValue, isFromMacAppStore {
                isHidden = true
            }
            #endif
        }
    }

    @IBInspectable
    var isHiddenDuringMASReview: Bool {
        get { return true }
        set {
            #if IS_FOR_MAS
            if newValue, defaults[.isInMASReview] != false {
                isHidden = true
            }
            #endif
        }
    }
}

extension NSView {
    @IBInspectable
    var isRemovedDuringMASReview: Bool {
        get { return true }
        set {
            #if IS_FOR_MAS
            if newValue, defaults[.isInMASReview] != false {
                removeFromSuperview()
            }
            #endif
        }
    }
}
