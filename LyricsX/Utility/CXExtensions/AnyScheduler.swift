import Combine

// MARK: - AnyScheduler

/// A type-erasing scheduler.
///
/// Do not use `SchedulerTimeType` across different `AnyScheduler` instance.
///
///     let scheduler1 = AnyScheduler(DispatchQueue.main.cx)
///     let scheduler2 = AnyScheduler(RunLoop.main.cx)
///
///     // DON'T DO THIS! Will crash.
///     scheduler2.schedule(after: scheduler1.now) { ... }
///
public final class AnyScheduler: Scheduler {
    
    public typealias SchedulerOptions = Never
    public typealias SchedulerTimeType = AnySchedulerTimeType
    
    private let _now: () -> SchedulerTimeType
    private let _minimumTolerance: () -> SchedulerTimeType.Stride
    private let _schedule_action: (@escaping () -> Void) -> Void
    private let _schedule_after_tolerance_action: (SchedulerTimeType, SchedulerTimeType.Stride, @escaping () -> Void) -> Void
    private let _schedule_after_interval_tolerance_action: (SchedulerTimeType, SchedulerTimeType.Stride, SchedulerTimeType.Stride, @escaping () -> Void) -> Cancellable
    
    public init<S: Scheduler>(_ scheduler: S, options: S.SchedulerOptions? = nil) {
        _now = {
            SchedulerTimeType(wrapping: scheduler.now)
        }
        _minimumTolerance = {
            SchedulerTimeType.Stride(wrapping: scheduler.minimumTolerance)
        }
        _schedule_action = { action in
            scheduler.schedule(options: options, action)
        }
        _schedule_after_tolerance_action = { date, tolerance, action in
            scheduler.schedule(after: date.wrapped as! S.SchedulerTimeType, tolerance: tolerance.asType(S.SchedulerTimeType.Stride.self), options: options, action)
        }
        _schedule_after_interval_tolerance_action = { date, interval, tolerance, action in
            scheduler.schedule(after: date.wrapped as! S.SchedulerTimeType, interval: interval.asType(S.SchedulerTimeType.Stride.self), tolerance: tolerance.asType(S.SchedulerTimeType.Stride.self), options: options, action)
        }
    }
    
    public var now: SchedulerTimeType {
        return _now()
    }
    
    public var minimumTolerance: SchedulerTimeType.Stride {
        return _minimumTolerance()
    }
    
    public func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void) {
        return _schedule_action(action)
    }
    
    public func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, options: SchedulerOptions?, _ action: @escaping () -> Void) {
        return _schedule_after_tolerance_action(date, tolerance, action)
    }
    
    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride, options: SchedulerOptions?, _ action: @escaping () -> Void) -> Cancellable {
        return _schedule_after_interval_tolerance_action(date, interval, tolerance, action)
    }
}

// MARK: - AnySchedulerTimeType

/// A type-erasing `SchedulerTimeType` for `AnyScheduler`.
///
/// Instance of `AnySchedulerTimeType` from different scheduler is NOT
/// interactable
///
///     let time1 = AnyScheduler(DispatchQueue.main.cx).now
///     let time2 = AnyScheduler(RunLoop.main.cx).now
///
///     // DON'T DO THIS! Will crash.
///     time1.distance(to: time2)
///
public struct AnySchedulerTimeType: Strideable {
    
    fileprivate let wrapped: Any
    
    private let _distance_to: (Any) -> Stride
    private let _advanced_by: (Stride) -> AnySchedulerTimeType
    
    fileprivate init<T: Strideable>(wrapping opaque: T) where T.Stride: SchedulerTimeIntervalConvertible {
        self.wrapped = opaque
        self._distance_to = { other in
            return Stride(wrapping: opaque.distance(to: other as! T))
        }
        self._advanced_by = { n in
            return AnySchedulerTimeType(wrapping: opaque.advanced(by: n.asType(T.Stride.self)))
        }
    }
    
    public func distance(to other: AnySchedulerTimeType) -> Stride {
        return _distance_to(other)
    }
    
    public func advanced(by n: Stride) -> AnySchedulerTimeType {
        return _advanced_by(n)
    }
}

// MARK: - AnySchedulerTimeType.Stride

extension AnySchedulerTimeType {
    
    public struct Stride: Comparable, SignedNumeric, SchedulerTimeIntervalConvertible {
        
        private struct Opaque {
            
            let wrapped: Any
            
            let _init: (SchedulerTimeLiteral) -> Opaque
            let _lessThan: (Any) -> Bool
            let _equalTo: (Any) -> Bool
            let _add: (Any) -> Opaque
            let _subtract: (Any) -> Opaque
            let _multiply: (Any) -> Opaque
            let _magnitude: () -> Opaque
            
            init<T: Comparable & SignedNumeric & SchedulerTimeIntervalConvertible>(_ content: T) {
                wrapped = content
                _init = { Opaque(T.time(literal: $0)) }
                _lessThan = { content < ($0 as! T) }
                _equalTo = { content < ($0 as! T) }
                _add = { Opaque(content + ($0 as! T)) }
                _subtract = { Opaque(content - ($0 as! T)) }
                _multiply = { Opaque(content * ($0 as! T)) }
                // Get magnitude and create Self from it. It's only possible on
                // BinaryInteger or BinaryFloatingPoint, fail fast otherwise.
                //
                // This is the best we can do for arbitrary SignedNumeric type.
                _magnitude = { Opaque(content.magnitudeAsSelfIfBinaryIntegerOrBinaryFloatingPoint!) }
            }
        }
        
        private enum Wrapped {
            case opaque(Opaque)
            case literal(SchedulerTimeLiteral)
        }
        
        private var wrapped: Wrapped
        
        private init(_ value: Wrapped) {
            wrapped = value
        }
        
        fileprivate init<T: Comparable & SignedNumeric & SchedulerTimeIntervalConvertible>(wrapping opaque: T) {
            wrapped = .opaque(.init(opaque))
        }
        
        fileprivate func asType<T: Comparable & SignedNumeric & SchedulerTimeIntervalConvertible>(_ type: T.Type) -> T {
            switch wrapped {
            case let .opaque(opaque):
                guard let result = opaque.wrapped as? T else {
                    preconditionFailure("Use AnySchedulerTimeType across different AnyScheduler instance is not supported.")
                }
                return result
            case let .literal(literal):
                return T.time(literal: literal)
            }
        }
        
        public init(integerLiteral value: Int) {
            wrapped = .literal(.seconds(value))
        }
        
        public init?<T: BinaryInteger>(exactly source: T) {
            guard let value = Int(exactly: source) else {
                return nil
            }
            self.init(integerLiteral: value)
        }
        
        public var magnitude: Stride {
            switch self.wrapped {
            case let .opaque(v):
                return .init(.opaque(v._magnitude()))
            case let .literal(v):
                return .seconds(v.timeInterval.magnitude)
            }
        }
        
        private static func withWrapped<T>(_ lhs: Stride, _ rhs: Stride, body: (Opaque, Opaque) -> T, fallback: (SchedulerTimeLiteral, SchedulerTimeLiteral) -> T) -> T {
            switch (lhs.wrapped, rhs.wrapped) {
            case let (.opaque(l), .opaque(r)):
                return body(l, r)
            case let (.opaque(l), .literal(r)):
                return body(l, l._init(r))
            case let (.literal(l), .opaque(r)):
                return body(r._init(l), r)
            case let (.literal(l), .literal(r)):
                return fallback(l, r)
            }
        }
        
        public static func == (lhs: Stride, rhs: Stride) -> Bool {
            return withWrapped(lhs, rhs, body: {
                $0._equalTo($1.wrapped)
            }, fallback: {
                // TODO: potential precision loss
                $0.timeInterval == $1.timeInterval
            })
        }
        
        public static func < (lhs: Stride, rhs: Stride) -> Bool {
            return withWrapped(lhs, rhs, body: {
                $0._lessThan($1.wrapped)
            }, fallback: {
                // TODO: potential precision loss
                $0.timeInterval < $1.timeInterval
            })
        }
        
        public static func + (lhs: Stride, rhs: Stride) -> Stride {
            return withWrapped(lhs, rhs, body: {
                .init(.opaque($0._add($1.wrapped)))
            }, fallback: {
                // TODO: potential precision loss
                .seconds($0.timeInterval + $1.timeInterval)
            })
        }
        
        public static func - (lhs: Stride, rhs: Stride) -> Stride {
            return withWrapped(lhs, rhs, body: {
                .init(.opaque($0._subtract($1.wrapped)))
            }, fallback: {
                // TODO: potential precision loss
                .seconds($0.timeInterval - $1.timeInterval)
            })
        }
        
        public static func * (lhs: Stride, rhs: Stride) -> Stride {
            return withWrapped(lhs, rhs, body: {
                .init(.opaque($0._multiply($1.wrapped)))
            }, fallback: {
                // TODO: potential precision loss
                .seconds($0.timeInterval * $1.timeInterval)
            })
        }
        
        public static func += (lhs: inout Stride, rhs: Stride) {
            lhs = lhs + rhs
        }
        
        public static func -= (lhs: inout Stride, rhs: Stride) {
            lhs = lhs - rhs
        }
        
        public static func *= (lhs: inout Stride, rhs: Stride) {
            lhs = lhs * rhs
        }
        
        public static func seconds(_ s: Double) -> Stride {
            return Stride(.literal(.interval(s)))
        }
        
        public static func seconds(_ s: Int) -> Stride {
            return Stride(.literal(.seconds(s)))
        }
        
        public static func milliseconds(_ ms: Int) -> Stride {
            return Stride(.literal(.milliseconds(ms)))
        }
        
        public static func microseconds(_ us: Int) -> Stride {
            return Stride(.literal(.microseconds(us)))
        }
        
        public static func nanoseconds(_ ns: Int) -> Stride {
            return Stride(.literal(.nanoseconds(ns)))
        }
    }
}

// MARK: - SchedulerTimeLiteral

private enum SchedulerTimeLiteral {
    
    case seconds(Int)
    case milliseconds(Int)
    case microseconds(Int)
    case nanoseconds(Int)
    case interval(Double)
    
    var timeInterval: Double {
        switch self {
        case let .seconds(s):       return Double(s)
        case let .milliseconds(ms): return Double(ms) * 1_000
        case let .microseconds(us): return Double(us) * 1_000_000
        case let .nanoseconds(ns):  return Double(ns) * 1_000_000_000
        case let .interval(s):      return s
        }
    }
}

private extension SchedulerTimeIntervalConvertible {
    
    static func time(literal: SchedulerTimeLiteral) -> Self {
        switch literal {
        case let .seconds(s):       return .seconds(s)
        case let .milliseconds(ms): return .milliseconds(ms)
        case let .microseconds(us): return .microseconds(us)
        case let .nanoseconds(ns):  return .nanoseconds(ns)
        case let .interval(s):      return .seconds(s)
        }
    }
}

// MARK: - Magnitude

// https://gist.github.com/dabrahams/852dfdb0b628e68567b4d97499f196f9

private struct Dispatch<Model> {
    func apply<A, R0, R1>(_ a: A, _ f: (Model)->R0) -> R1 {
        f(a as! Model) as! R1
    }
}

private protocol BinaryIntegerDispatch {
    func magnitude<N>(_: N) -> N
}

private protocol BinaryFloatingPointDispatch {
    func magnitude<N>(_: N) -> N
}

extension Dispatch: BinaryIntegerDispatch where Model: BinaryInteger {
    func magnitude<N>(_ x: N) -> N { apply(x) { Model($0.magnitude) } }
}

extension Dispatch: BinaryFloatingPointDispatch where Model: BinaryFloatingPoint {
    func magnitude<N>(_ x: N) -> N { apply(x) { Model($0.magnitude) } }
}

private extension SignedNumeric {
    var magnitudeAsSelfIfBinaryIntegerOrBinaryFloatingPoint: Self? {
        (Dispatch<Self>() as? BinaryIntegerDispatch)?.magnitude(self) ??
        (Dispatch<Self>() as? BinaryFloatingPointDispatch)?.magnitude(self)
    }
}
