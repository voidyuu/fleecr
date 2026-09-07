#if os(macOS)
import Darwin
import Dispatch
import Foundation

final class LocalPTYProcess: @unchecked Sendable {
    struct Size: Equatable, Sendable {
        var columns: Int
        var rows: Int
        static let `default` = Size(columns: 80, rows: 24)
    }

    enum PTYError: LocalizedError {
        case failedToCreatePTY(Int32)
        case failedToFork(Int32)

        var errorDescription: String? {
            switch self {
            case .failedToCreatePTY(let err): return "Failed to open PTY: errno \(err)"
            case .failedToFork(let err): return "Failed to fork child process: errno \(err)"
            }
        }
    }

    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    private(set) var shellPid: pid_t = 0
    private var masterFd: Int32 = -1
    private let readQueue = DispatchQueue(label: "dev.bybee.fleecr.pty-read")
    private let writeQueue = DispatchQueue(label: "dev.bybee.fleecr.pty-write")
    private let stateLock = NSLock()
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var isTerminated = false

    deinit {
        terminate()
    }

    func start(
        executable: String,
        args: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        initialSize: Size = .default
    ) throws {
        terminate()

        stateLock.lock()
        isTerminated = false
        stateLock.unlock()

        var win = winsize(
            ws_row: UInt16(max(1, min(initialSize.rows, Int(UInt16.max)))),
            ws_col: UInt16(max(1, min(initialSize.columns, Int(UInt16.max)))),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // Pre-allocate all C strings before forkpty so the child never calls
        // malloc or Swift runtime functions in a multithreaded process.
        let cExecutable = strdup(executable)
        let fullArgs = [executable] + args
        let cArgs: [UnsafeMutablePointer<CChar>?] = fullArgs.map { strdup($0) } + [nil]
        let envStrings: [String] = environment.map { "\($0.key)=\($0.value)" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        let cWorkingDir: UnsafeMutablePointer<CChar>? = workingDirectory.flatMap {
            $0.isEmpty ? nil : strdup($0)
        }
        let hasSlash = executable.contains("/")

        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &win)
        guard pid >= 0 else {
            free(cExecutable)
            cArgs.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
            if let p = cWorkingDir { free(p) }
            throw PTYError.failedToFork(errno)
        }

        if pid == 0 {
            // Child process: execute directly with async-signal-safe calls only
            if let cWorkingDir {
                _ = chdir(cWorkingDir)
            }

            signal(SIGPIPE, SIG_DFL)
            signal(SIGCHLD, SIG_DFL)

            cArgs.withUnsafeBufferPointer { argsPtr in
                cEnv.withUnsafeBufferPointer { envPtr in
                    let argv = UnsafeMutablePointer(mutating: argsPtr.baseAddress!)
                    let envp = UnsafeMutablePointer(mutating: envPtr.baseAddress!)
                    execve(cExecutable, argv, envp)
                    // If execve failed and executable is not an absolute path, try execvp
                    if !hasSlash {
                        execvp(cExecutable, argv)
                    }
                }
            }

            _exit(127)
        }

        // Parent process: free allocated argument and environment arrays
        free(cExecutable)
        cArgs.forEach { if let p = $0 { free(p) } }
        cEnv.forEach { if let p = $0 { free(p) } }
        if let p = cWorkingDir { free(p) }

        stateLock.lock()
        shellPid = pid
        masterFd = master
        stateLock.unlock()

        let flags = fcntl(master, F_GETFL)
        if flags >= 0 {
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        }

        configureSources()
    }

    func send(_ data: Data) {
        stateLock.lock()
        let fd = masterFd
        stateLock.unlock()
        guard fd >= 0, !data.isEmpty else { return }

        let payload = data
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let currentFd = self.masterFd
            self.stateLock.unlock()
            guard currentFd >= 0 else { return }

            payload.withUnsafeBytes { rawBuffer in
                guard var ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var stalled = 0
                while remaining > 0 {
                    let written = Darwin.write(currentFd, ptr, remaining)
                    if written > 0 {
                        remaining -= written
                        ptr = ptr.advanced(by: written)
                        stalled = 0
                    } else if written == -1 && errno == EINTR {
                        continue
                    } else if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        if stalled >= 1_000_000 { break }
                        usleep(2_000)
                        stalled += 2_000
                    } else {
                        break
                    }
                }
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        stateLock.lock()
        let fd = masterFd
        stateLock.unlock()
        guard fd >= 0 else { return }

        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let currentFd = self.masterFd
            self.stateLock.unlock()
            guard currentFd >= 0 else { return }

            var win = winsize(
                ws_row: UInt16(max(1, min(rows, Int(UInt16.max)))),
                ws_col: UInt16(max(1, min(columns, Int(UInt16.max)))),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(currentFd, TIOCSWINSZ, &win)
        }
    }

    func terminate(signal: Int32 = SIGHUP) {
        stateLock.lock()
        guard !isTerminated else {
            stateLock.unlock()
            return
        }
        isTerminated = true
        let pid = shellPid
        stateLock.unlock()

        if pid > 0 {
            kill(pid, signal)
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                for _ in 0..<20 {
                    if waitpid(pid, &status, WNOHANG) != 0 { return }
                    usleep(50_000)
                }
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
        }
        cleanup()
    }

    private func configureSources() {
        stateLock.lock()
        let fd = masterFd
        let pid = shellPid
        stateLock.unlock()

        guard fd >= 0, pid > 0 else { return }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        readSource.setEventHandler { [weak self] in
            self?.drainOutput()
        }
        readSource.setCancelHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            if self.masterFd >= 0 {
                close(self.masterFd)
                self.masterFd = -1
            }
            self.stateLock.unlock()
        }
        readSource.resume()
        self.readSource = readSource

        let processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        processSource.setEventHandler { [weak self] in
            self?.handleProcessExit()
        }
        processSource.resume()
        self.processSource = processSource
    }

    private func drainOutput() {
        stateLock.lock()
        let fd = masterFd
        stateLock.unlock()
        guard fd >= 0 else { return }

        var buf = [UInt8](repeating: 0, count: 8192)
        var pending = Data()
        var isEOF = false

        while true {
            let count = Darwin.read(fd, &buf, buf.count)
            if count > 0 {
                pending.append(contentsOf: buf[0..<count])
                if pending.count >= 64 * 1024 {
                    let chunk = pending
                    pending = Data()
                    onOutput?(chunk)
                }
            } else if count == 0 {
                isEOF = true
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                // EIO indicates PTY slave closed on macOS
                isEOF = true
                break
            }
        }

        if !pending.isEmpty {
            onOutput?(pending)
        }

        if isEOF {
            readSource?.cancel()
        }
    }

    private func handleProcessExit() {
        // Drain any remaining output in PTY buffer before closing
        drainOutput()

        stateLock.lock()
        let pid = shellPid
        stateLock.unlock()

        var status: Int32 = 0
        let waited = pid > 0 ? waitpid(pid, &status, 0) : -1
        let exitCode: Int32
        if waited <= 0 {
            exitCode = 1
        } else if (status & 0x7f) == 0 {
            exitCode = (status >> 8) & 0xff
        } else {
            exitCode = 128 + (status & 0x7f)
        }

        cleanup()
        onExit?(exitCode)
    }

    private func cleanup() {
        readSource?.cancel()
        readSource = nil

        processSource?.cancel()
        processSource = nil

        stateLock.lock()
        shellPid = 0
        stateLock.unlock()
    }
}
#endif
