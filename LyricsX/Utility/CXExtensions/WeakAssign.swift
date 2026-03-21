import Combine
import Foundation

extension Publisher where Failure == Never {
    
    /// Assigns a publisher’s output to a property of an object. The object is
    /// weakly captured.
    public func assign<Root: AnyObject>(to keyPath: ReferenceWritableKeyPath<Root, Output>, weaklyOn object: Root) -> AnyCancellable {
        let assign = Subscribers.WeakAssign(object: object, keyPath: keyPath)
        self.subscribe(assign)
        return AnyCancellable(assign)
    }
}

extension Subscribers {
    
    /// Similar to `Subscribers.Assign`, but captures its target weakly.
    public final class WeakAssign<Root: AnyObject, Input>: Subscriber, Cancellable, CustomStringConvertible, CustomReflectable, CustomPlaygroundDisplayConvertible {
        
        public typealias Failure = Never
        
        /// The object that contains the property to assign.
        public private(set) weak var object: Root?
        
        /// The key path that indicates the property to assign.
        public let keyPath: ReferenceWritableKeyPath<Root, Input>
        
        private let lock = NSLock()
        private var subscription: Subscription?
        
        public init(object: Root, keyPath: ReferenceWritableKeyPath<Root, Input>) {
            self.object = object
            self.keyPath = keyPath
        }
        
        public func receive(subscription: Subscription) {
            self.lock.lock()
            if self.subscription == nil {
                self.subscription = subscription
                self.lock.unlock()
                subscription.request(.unlimited)
            } else {
                self.lock.unlock()
                subscription.cancel()
            }
        }
        
        public func receive(_ value: Input) -> Subscribers.Demand {
            self.lock.lock()
            if self.subscription == nil {
                self.lock.unlock()
            } else {
                let obj = self.object
                self.lock.unlock()
                
                obj?[keyPath: self.keyPath] = value
            }
            return .none
        }
        
        public func receive(completion: Subscribers.Completion<Never>) {
            self.cancel()
        }
        
        public func cancel() {
            self.lock.lock()
            guard let subscription = self.subscription else {
                self.lock.unlock()
                return
            }
            
            self.subscription = nil
            self.object = nil
            self.lock.unlock()
            
            subscription.cancel()
        }
        
        public var description: String {
            return "WeakAssign \(Root.self)"
        }
        
        public var customMirror: Mirror {
            return Mirror(self, children: [
                "object": self.object as Any,
                "keyPath": self.keyPath,
                "upstreamSubscription": self.subscription as Any
            ])
        }
        
        public var playgroundDescription: Any {
            return self.description
        }
    }
}
