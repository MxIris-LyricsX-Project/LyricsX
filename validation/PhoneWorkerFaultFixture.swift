import Foundation
import Darwin

/// Synthetic child only; no Bluetooth or UI calls. Exercises the real supervisor.
@main enum PhoneWorkerFaultFixture {
    nonisolated static func emit(_ message: PhoneWorkerMessage) { FileHandle.standardOutput.write(message.encoded()!) }
    static func main() {
        let mode = CommandLine.arguments.last ?? "active"
        let pid = String(getpid())
        if mode == "malformed" {
            FileHandle.standardOutput.write(Data("invalid JSON\n".utf8)); Thread.sleep(forTimeInterval: 10); return
        }
        if mode == "wrong-role" { emit(PhoneWorkerMessage(kind: .ready)); Thread.sleep(forTimeInterval: 10); return }
        if mode == "exit" { return }
        if mode == "oversized" {
            FileHandle.standardOutput.write(Data(repeating: 65, count: 4 * 1024 * 1024 + 1))
            Thread.sleep(forTimeInterval: 10); return
        }
        if mode == "cover-hang" || mode == "cover-restart-hang" { emit(PhoneWorkerMessage(kind: .artworkState, artworkState: .connecting)) }
        else { emit(PhoneWorkerMessage(kind: .status, text: pid)) }
        emit(PhoneWorkerMessage(kind: .heartbeat))
        if mode == "eof-hang" {
            signal(SIGTERM, SIG_IGN)
            FileHandle.standardInput.readabilityHandler = { handle in
                if handle.availableData.isEmpty { exit(0) }
            }
            Thread.sleep(forTimeInterval: 30); return
        }
        if mode == "hang" || mode == "cover-hang" {
            signal(SIGTERM, SIG_IGN)
            Thread.sleep(forTimeInterval: 30); return
        }
        let heartbeat = Timer(timeInterval: 0.03, repeats: true) { _ in emit(PhoneWorkerMessage(kind: .heartbeat)) }
        RunLoop.main.add(heartbeat, forMode: .common)
        if mode != "connect-timeout" && mode != "no-reader" {
            if mode == "cover-restart-hang" { emit(PhoneWorkerMessage(kind: .ready)) }
            else {
                emit(PhoneWorkerMessage(kind: .open, text: pid))
                emit(PhoneWorkerMessage(kind: .status, text: "late:" + pid))
            }
            var frames = PhoneWorkerFrames(limit: 128 * 1024)
            FileHandle.standardInput.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { exit(0) }
                guard let messages = try? frames.append(data) else { exit(1) }
                for message in messages where message.kind == .send {
                    emit(PhoneWorkerMessage(kind: .data, bytes: message.bytes))
                }
            }
        }
        RunLoop.main.run()
    }
}
