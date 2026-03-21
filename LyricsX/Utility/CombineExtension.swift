import Combine

extension Publisher where Output == Void {
    func prepend() -> Publishers.Concatenate<Publishers.Sequence<[Void], Failure>, Self> {
        prepend(())
    }
}
