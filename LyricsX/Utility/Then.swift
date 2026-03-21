import CoreGraphics
import Foundation

public protocol Then {}

extension Then where Self: Any {
    public func with(_ block: (inout Self) throws -> Void) rethrows -> Self {
        var copy = self
        try block(&copy)
        return copy
    }

    public func `do`<T>(_ block: (Self) throws -> T) rethrows -> T {
        return try block(self)
    }
}

extension Then where Self: AnyObject {
    public func then(_ block: (Self) throws -> Void) rethrows -> Self {
        try block(self)
        return self
    }
}

extension NSObject: Then {}

extension CGPoint: Then {}
extension CGRect: Then {}
extension CGSize: Then {}
extension CGVector: Then {}
