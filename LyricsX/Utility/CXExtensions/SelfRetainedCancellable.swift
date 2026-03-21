import Combine

extension Publisher {
    
    @discardableResult
    public func selfRetained(subscribing: (AnyPublisher<Output, Failure>) -> AnyCancellable) -> AnyCancellable {
        var retainCycle: AnyCancellable?
        let pub = handleEvents(receiveCompletion: { _ in
            retainCycle?.cancel()
            retainCycle = nil
        }, receiveCancel: {
            retainCycle?.cancel()
            retainCycle = nil
        }).eraseToAnyPublisher()
        let canceller = subscribing(pub)
        retainCycle = canceller
        return canceller
    }
}

extension Cancellable where Self: AnyObject {
    
    public func selfRetained() -> SelfRetainedCancellable<Self> {
        return SelfRetainedCancellable(wrapping: self)
    }
}

public final class SelfRetainedCancellable<Child: Cancellable & AnyObject>: Cancellable {
    
    private var wrapped: Child?
    
    private var retainCycle: SelfRetainedCancellable?
    
    public init(wrapping wrapped: Child) {
        self.wrapped = wrapped
        retainCycle = self
    }
    
    public func cancel() {
        wrapped?.cancel()
        wrapped = nil
        retainCycle = nil
    }
}
