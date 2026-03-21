import Combine

extension Publisher {
    
    /// Emits a signal (`Void()`) whenever upstream publisher produce an element.
    public func signal() -> Publishers.Signal<Self> {
        return .init(upstream: self)
    }
}

extension Publishers {
    
    /// A publisher that emits a signal (`Void()`) whenever upstream publisher
    /// produce an element.
    public struct Signal<Upstream: Publisher>: Publisher {
        
        public typealias Output = Void
        public typealias Failure = Upstream.Failure
        
        public let upstream: Upstream
        
        public init(upstream: Upstream) {
            self.upstream = upstream
        }
        
        public func receive<S: Subscriber>(subscriber: S) where Failure == S.Failure, Output == S.Input {
            self.upstream
                .map { _ in Void() }
                .receive(subscriber: subscriber)
        }
    }
}
