import Foundation
import Darwin

@main enum PhoneWorkerIsolationProbe {
    static func main() {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(name)")
        }
        func pump(_ duration: Double) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        var frames = PhoneWorkerFrames(limit: 32)
        let frame = PhoneWorkerMessage(kind: .open).encoded()!
        check((try? frames.append(frame.prefix(3)))?.isEmpty == true, "partial IPC frame waits for completion")
        check((try? frames.append(frame.dropFirst(3)))?.first?.kind == .open, "split IPC frame decodes once complete")
        check((try? frames.append(frame + frame))?.count == 2, "multiple IPC frames in a pipe read decode independently")
        check((try? frames.append(Data(repeating: 65, count: 33))) == nil, "unterminated IPC frame is bounded")

        var ticks = 0, worstGap = 0.0, lastTick = ProcessInfo.processInfo.systemUptime
        let uiClock = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            worstGap = max(worstGap, now - lastTick); lastTick = now; ticks += 1
        }
        RunLoop.main.add(uiClock, forMode: .common)
        defer { uiClock.invalidate() }
        let stalled = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["hang"] }, heartbeatTimeout: 0.5)
        var failureCount = 0, childPID: Int32?
        stalled.onMessage = { if $0.kind == .status { childPID = Int32($0.text ?? "") } }
        stalled.onFailure = { failureCount += 1 }
        let started = ProcessInfo.processInfo.systemUptime
        stalled.start(role: .media)
        check(ProcessInfo.processInfo.systemUptime - started < 0.1, "child startup returns immediately to UI")
        pump(1.8)
        check(failureCount == 1, "stalled child reports one heartbeat timeout")
        check(ticks > 40 && worstGap < 0.2, "UI timer remains responsive while native-equivalent child is blocked")
        let exited = childPID.map { pid -> Bool in
            let result = Darwin.kill(pid, 0)
            if result == 0 || errno != ESRCH { print("DIAGNOSTIC: child pid=\(pid), kill(0)=\(result), errno=\(errno)") }
            return result != 0 && errno == ESRCH
        } ?? false
        if childPID == nil { print("DIAGNOSTIC: child had not emitted its PID before timeout") }
        check(exited, "child ignoring SIGTERM is forcibly reaped")
        stalled.stop()

        for mode in ["malformed", "wrong-role", "oversized", "exit"] {
            let worker = PhoneWorkerProcess(executable: fixture, arguments: { _ in [mode] }, heartbeatTimeout: 0.4)
            var failed = 0
            worker.onFailure = { failed += 1 }
            worker.start(role: .media)
            let limit = Date().addingTimeInterval(2)
            while failed == 0 && Date() < limit { pump(0.05) }
            check(failed == 1, "\(mode) child fails once without blocking parent")
            worker.stop()
        }

        let waiting = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["connect-timeout"] }, heartbeatTimeout: 0.3, operationTimeout: 0.2)
        var waitingFailed = 0
        waiting.onFailure = { waitingFailed += 1 }
        waiting.start(role: .media); pump(0.55)
        check(waitingFailed == 1, "live heartbeat cannot mask a connection deadline")
        waiting.stop()

        let paging = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["hang"] }, heartbeatTimeout: 0.1, operationTimeout: 0.7)
        var pagingFailed = 0
        paging.onFailure = { pagingFailed += 1 }
        paging.start(role: .media, address: "00-00-00-00-00-01"); pump(0.35)
        check(pagingFailed == 0, "initial native connection may outlast the steady heartbeat within its hard deadline")
        pump(0.65)
        check(pagingFailed == 1, "initial native connection without heartbeat still ends at its hard deadline")
        paging.stop()

        let restarting = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["cover-restart-hang"] }, heartbeatTimeout: 0.3, operationTimeout: 0.25)
        var restartReady = false, restartFailed = 0
        restarting.onMessage = { if $0.kind == .ready { restartReady = true } }
        restarting.onFailure = { restartFailed += 1 }
        restarting.start(role: .cover); pump(0.15)
        check(restartReady && restartFailed == 0, "cover worker establishes a session before reset fault")
        restarting.send(PhoneWorkerMessage(kind: .restartSession)); pump(0.6)
        check(restartFailed == 1, "live heartbeat cannot mask a stalled OBEX session restart")
        restarting.stop()

        let media = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["active"] })
        let cover = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["cover-hang"] }, heartbeatTimeout: 0.2)
        var mediaOpen = false, mediaFailure = false, echoed = false, coverFailed = false
        media.onMessage = {
            if $0.kind == .open { mediaOpen = true }
            if $0.kind == .data { echoed = $0.bytes == Data([1,2,3]) }
        }
        media.onFailure = { mediaFailure = true }
        cover.onFailure = { coverFailed = true }
        media.start(role: .media); cover.start(role: .cover); pump(0.5)
        media.send(PhoneWorkerMessage(kind: .send, bytes: Data([1,2,3]))); pump(0.2)
        check(mediaOpen && !mediaFailure && coverFailed && echoed, "cover worker stall leaves media worker and commands operational")
        media.stop(); cover.stop()

        let replaced = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["active"] })
        var opened = 0, staleStatus = false, oldPID: String?
        replaced.onMessage = { message in
            if message.kind == .open {
                opened += 1
                if opened == 1 {
                    oldPID = message.text; replaced.stop(); replaced.start(role: .media)
                }
            }
            if message.kind == .status, message.text == "late:" + (oldPID ?? "") { staleStatus = true }
        }
        replaced.start(role: .media); pump(0.7)
        check(opened == 2 && !staleStatus, "queued previous-session callbacks cannot cross disconnect and reconnect")
        replaced.stop()

        let eofWorker = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["eof-hang"] })
        var eofPID: Int32?
        eofWorker.onMessage = { if $0.kind == .status { eofPID = Int32($0.text ?? "") } }
        eofWorker.start(role: .media); pump(0.4); eofWorker.stop(); pump(0.25)
        check(eofPID.map({ Darwin.kill($0, 0) != 0 && errno == ESRCH }) == true, "parent pipe closure ends an orphan while child main thread is blocked")

        var abandoned: PhoneWorkerProcess? = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["active"] })
        var abandonedPID: Int32?
        abandoned?.onMessage = { if $0.kind == .status, let pid = Int32($0.text ?? "") { abandonedPID = pid } }
        abandoned?.start(role: .media); pump(0.4); abandoned = nil; pump(0.7)
        check(abandonedPID.map({ Darwin.kill($0, 0) != 0 && errno == ESRCH }) == true, "releasing a supervisor does not leave its child running")

        let fullPipe = PhoneWorkerProcess(executable: fixture, arguments: { _ in ["no-reader"] })
        var fullFailed = false
        fullPipe.onFailure = { fullFailed = true }
        fullPipe.start(role: .media); pump(0.1)
        let beforeFlood = ProcessInfo.processInfo.systemUptime
        for _ in 0..<80 { fullPipe.send(PhoneWorkerMessage(kind: .send, bytes: Data(repeating: 1, count: 4096))) }
        check(ProcessInfo.processInfo.systemUptime - beforeFlood < 0.1, "full child stdin never blocks UI commands")
        pump(0.25)
        check(fullFailed, "pending command bytes have a finite backpressure bound")
        fullPipe.stop(); pump(0.6)
        check(worstGap < 0.2, "all worker failure paths preserve UI timer responsiveness")
        print("\(checks) checks passed; \(ticks) UI ticks, max gap \(String(format: "%.3f", worstGap)) seconds")
    }
}
