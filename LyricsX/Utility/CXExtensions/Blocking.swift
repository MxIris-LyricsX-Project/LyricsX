import Combine
import Foundation
import Dispatch
import CoreFoundation

extension Publisher {
    
    /// Get element from a publisher synchronously.
    ///
    /// Calling this method itself is not blocking. Request next value is
    /// blocking, however.
    ///
    ///     let subscriber = publisher.blocking() // not blocking
    ///
    ///     let value = subscriber.next() // blocking
    ///
    ///     for value in subscriber { // blocking
    ///         print(value)
    ///     }
    ///
    public func blocking() -> Subscribers.Blocking<Output, Failure> {
        let blocking = Subscribers.Blocking<Output, Failure>()
        self.subscribe(blocking)
        return blocking
    }
}

extension Subscribers {
    
    /// A subscriber that transform asynchronous `Publisher` to synchronous
    /// `Sequence`.
    ///
    /// When you request a value by calling `next()` method, the subscriber
    /// request one value from upstream publisher, blocks current thread until
    /// upstream publisher produces an element or terminates.
    ///
    /// Simultaneous access by different threads is not allowed.
    public class Blocking<Input, Failure: Error>: Subscriber, Cancellable, Sequence, IteratorProtocol {
        
        private enum SubscribingState {
            case awaitingSubscription
            case connected(Subscription)
            case finished(Subscribers.Completion<Failure>)
            case cancelled
        }
        
        private enum DemandingState {
            case idle
            case demanding(DispatchSemaphore)
            case recived(Input?)
        }
        
        private let lock = NSLock()
        private var subscribingState = SubscribingState.awaitingSubscription
        private var demandingState = DemandingState.idle
        
        // @testable
        var completion: Subscribers.Completion<Failure>? {
            lock.lock()
            defer { lock.unlock() }
            switch subscribingState {
            case let  .finished(completion):
                return completion
            default:
                return nil
            }
        }
        
        public init() {}
        
        public func receive(subscription: Subscription) {
            lock.lock()
            guard case .awaitingSubscription = subscribingState else {
                lock.unlock()
                subscription.cancel()
                return
            }
            subscribingState = .connected(subscription)
            lock.unlock()
        }
        
        public func receive(_ input: Input) -> Subscribers.Demand {
            lock.lock()
            guard case .demanding = demandingState else {
                lock.unlock()
                preconditionFailure("upstream publisher send more value than demand")
            }
            lockedSignal(input)
            return .none
        }
        
        public func receive(completion: Subscribers.Completion<Failure>) {
            lock.lock()
            switch subscribingState {
            case .awaitingSubscription:
                lock.unlock()
                preconditionFailure("receive completion before subscribing")
            case .finished, .cancelled:
                lock.unlock()
                return
            case .connected:
                subscribingState = .finished(completion)
                switch demandingState {
                case .idle, .recived:
                    lock.unlock()
                case .demanding:
                    lockedSignal(nil)
                }
            }
        }
        
        public func cancel() {
            self.lock.lock()
            guard case let .connected(subscription) = subscribingState else {
                self.lock.unlock()
                return
            }
            subscribingState = .cancelled
            switch demandingState {
            case .idle, .recived:
                lock.unlock()
            case .demanding:
                lockedSignal(nil)
            }
            subscription.cancel()
        }
        
        public func next() -> Input? {
            lock.lock()
            // TODO: calling next() simultaneously from different thread.
            // We need to store multiple `DispatchSemaphore`.
            guard case .idle = demandingState else {
                lock.unlock()
                preconditionFailure("simultaneous access by different threads")
            }
            switch subscribingState {
            case .awaitingSubscription:
                lock.unlock()
                preconditionFailure("request value before subscribing")
            case .finished, .cancelled:
                lock.unlock()
                return nil
            case let .connected(subscription):
                return lockedWait(subscription)
            }
        }
        
        func lockedWait(_ subscription: Subscription) -> Input? {
            let semaphore = DispatchSemaphore(value: 0)
            demandingState = .demanding(semaphore)
            lock.unlock()
            subscription.request(.max(1))
            semaphore.wait()
            lock.lock()
            guard case let .recived(value) = demandingState else {
                fatalError("Internal Inconsistency")
            }
            demandingState = .idle
            lock.unlock()
            return value
        }
        
        func lockedSignal(_ value: Input?) {
            guard case let .demanding(semaphore) = demandingState else {
                fatalError("Internal Inconsistency")
            }
            demandingState = .recived(value)
            lock.unlock()
            semaphore.signal()
        }
    }
}

#if false
extension Subscribers {
    
    class AwaitNonBlockingRunLoop: Await {
        override func lockedWait(_ subscription: Subscription) -> Input? {
            // demandingState = .demanding(???)
            lock.unlock()
            subscription.request(.max(1))
            #if canImport(Darwin)
            let runLoopMode = CFRunLoopMode.defaultMode
            let result = CFRunLoopRunResult.stopped
            #else
            let runLoopMode = kCFRunLoopDefaultMode
            let result = kCFRunLoopRunStopped
            #endif
            while true {
                guard CFRunLoopRunInMode(runLoopMode, .infinity, false) == result else {
                    continue
                }
                lock.lock()
                if case let .recived(value) = demandingState {
                    demandingState = .idle
                    lock.unlock()
                    return value
                }
                lock.unlock()
            }
        }
        
        override func lockedSignal(_ value: Input?) {
            
        }
    }
}
#endif
