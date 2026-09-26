#if os(macOS)
import Darwin
import Dispatch
import Foundation
import GhosttyTerminal

@MainActor
final class TerminalSessionRegistry {
    static let shared = TerminalSessionRegistry()

    private var sessions: [ObjectIdentifier: HerdrTerminalControlProcess] = [:]

    func register(_ session: HerdrTerminalControlProcess) {
        sessions[ObjectIdentifier(session)] = session
    }

    func remove(_ session: HerdrTerminalControlProcess) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    func detachAll(signal: Int32) async {
        let activeSessions = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in activeSessions {
                group.addTask { await session.detachAndWait(signal: signal) }
            }
        }
    }
}

/// Bridges Herdr's rendered ANSI frames and JSONL control commands without a local PTY.
final class HerdrTerminalControlProcess: @unchecked Sendable {
    var onFrame: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32, String) -> Void)?

    private let stateLock = NSLock()
    private let diagnosticLock = NSLock()
    private let inputQueue = DispatchQueue(label: "dev.herdrm.terminal-control-input")
    private let stdoutQueue = DispatchQueue(label: "dev.herdrm.terminal-control-stdout", qos: .userInteractive)
    private let stderrQueue = DispatchQueue(label: "dev.herdrm.terminal-control-stderr", qos: .utility)
    private var process: Process?
    private var inputHandle: FileHandle?
    private var closingInput = false
    private var didReportExit = false
    private var didExitChild = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var diagnostics = Data()
    private var closeReason: String?

    deinit {
        detach(signal: SIGHUP)
    }

    func attach(executable: String, args: [String], environment: [String: String]) throws {
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        let stderrPipe = Pipe()
        let readers = DispatchGroup()

        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = args
        child.environment = environment
        child.standardInput = input
        child.standardOutput = output
        child.standardError = stderrPipe

        stateLock.lock()
        process = child
        inputHandle = input.fileHandleForWriting
        stateLock.unlock()

        readers.enter()
        stdoutQueue.async { [weak self] in
            defer { readers.leave() }
            guard let self else { return }
            self.readFrames(from: output.fileHandleForReading.fileDescriptor)
        }
        readers.enter()
        stderrQueue.async { [weak self] in
            defer { readers.leave() }
            guard let self else { return }
            self.readDiagnostics(from: stderrPipe.fileHandleForReading.fileDescriptor)
        }

        child.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.childDidExit()
            readers.notify(queue: .global(qos: .utility)) {
                self.reportExit(terminatedProcess.terminationStatus)
            }
        }

        do {
            try child.run()
            // The parent only reads from these pipes. Closing its duplicate write
            // ends lets the readers observe EOF when Herdr or ssh exits.
            try? output.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            stateLock.lock()
            process = nil
            inputHandle = nil
            stateLock.unlock()
            throw error
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        sendCommand(["type": "terminal.input", "bytes": data.base64EncodedString()])
    }

    func resize(_ viewport: InMemoryTerminalViewport) {
        sendCommand([
            "type": "terminal.resize",
            "cols": Int(viewport.columns),
            "rows": Int(viewport.rows),
            "cell_width_px": Int(viewport.cellWidthPixels),
            "cell_height_px": Int(viewport.cellHeightPixels),
        ])
    }

    func scroll(
        direction: String,
        lines: Int,
        source: String,
        column: Int? = nil,
        row: Int? = nil,
        modifiers: Int = 0
    ) {
        guard lines > 0 else { return }
        var command: [String: Any] = [
            "type": "terminal.scroll",
            "direction": direction,
            "lines": min(lines, Int(UInt16.max)),
            "source": source,
            "modifiers": modifiers & 0x0F,
        ]
        if let column { command["column"] = min(max(column, 0), Int(UInt16.max)) }
        if let row { command["row"] = min(max(row, 0), Int(UInt16.max)) }
        sendCommand(command)
    }

    func detach(signal: Int32) {
        stateLock.lock()
        guard let child = process, !closingInput, !didReportExit, !didExitChild else {
            stateLock.unlock()
            return
        }
        closingInput = true
        let handle = inputHandle
        let pid = child.processIdentifier
        stateLock.unlock()

        // EOF after terminal.release normally makes the CLI detach cleanly. The
        // watchdogs must be armed before queued pipe writes, which can block if
        // the CLI has stopped reading stdin.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard child.isRunning, pid > 0 else { return }
            _ = Darwin.kill(pid, signal)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            guard child.isRunning, pid > 0 else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }

        if let handle {
            let release = (try? JSONSerialization.data(withJSONObject: ["type": "terminal.release"]))
                .map { $0 + Data([0x0A]) }
            inputQueue.async {
                if let release { try? handle.write(contentsOf: release) }
                try? handle.close()
            }
        }
    }

    func detachAndWait(signal: Int32) async {
        detach(signal: signal)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            let alreadyExited = didExitChild
            if !alreadyExited { exitWaiters.append(continuation) }
            stateLock.unlock()
            if alreadyExited { continuation.resume() }
        }
    }

    private func sendCommand(_ command: [String: Any]) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: command) else { return }
        let line = encoded + Data([0x0A])
        stateLock.lock()
        guard !closingInput, let handle = inputHandle else {
            stateLock.unlock()
            return
        }
        inputQueue.async {
            try? handle.write(contentsOf: line)
        }
        stateLock.unlock()
    }

    private func readFrames(from fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var pending = Data()

        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    consumeFrameRecord(line)
                }
                // A valid terminal frame is bounded by Herdr's framed transport;
                // discard a malformed, unbounded stdout record rather than growing
                // memory forever if the child is not speaking the expected protocol.
                if pending.count > 32 * 1024 * 1024 {
                    pending.removeAll(keepingCapacity: false)
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }

        if !pending.isEmpty { consumeFrameRecord(pending) }
    }

    private func consumeFrameRecord(_ line: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = record["type"] as? String
        else { return }

        if type == "terminal.frame",
           (record["encoding"] as? String == nil || record["encoding"] as? String == "ansi"),
           let encoded = record["bytes"] as? String,
           let frame = Data(base64Encoded: encoded) {
            onFrame?(frame)
        } else if type == "terminal.closed", let reason = record["reason"] as? String {
            stateLock.lock()
            closeReason = reason
            stateLock.unlock()
        }
    }

    private func readDiagnostics(from fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                diagnosticLock.lock()
                diagnostics.append(contentsOf: chunk[0..<count])
                if diagnostics.count > 16_384 {
                    diagnostics = Data(diagnostics.suffix(16_384))
                }
                diagnosticLock.unlock()
            } else if count == 0 {
                return
            } else if errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func reportExit(_ status: Int32) {
        stateLock.lock()
        guard !didReportExit else {
            stateLock.unlock()
            return
        }
        didReportExit = true
        let reason = closeReason
        inputHandle = nil
        process = nil
        stateLock.unlock()

        diagnosticLock.lock()
        let stderr = String(data: diagnostics, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        diagnosticLock.unlock()
        let message = stderr.isEmpty ? (reason ?? "") : stderr
        onExit?(status, message)
    }

    private func childDidExit() {
        stateLock.lock()
        didExitChild = true
        let waiters = exitWaiters
        exitWaiters.removeAll()
        stateLock.unlock()
        waiters.forEach { $0.resume() }
    }
}
#endif
