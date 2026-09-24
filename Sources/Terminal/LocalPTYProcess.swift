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
        case executableNotFound(String)

        var errorDescription: String? {
            switch self {
            case .failedToCreatePTY(let err): return "Failed to open PTY: errno \(err)"
            case .failedToFork(let err): return "Failed to fork child process: errno \(err)"
            case .executableNotFound(let executable): return "Executable not found in PATH: \(executable)"
            }
        }
    }

    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    private(set) var shellPid: pid_t = 0
    private var masterFd: Int32 = -1
    private let readQueue = DispatchQueue(label: "cc.cassiel.fleecr.pty-read")
    private let writeQueue = DispatchQueue(label: "cc.cassiel.fleecr.pty-write")
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

        // Keep all Swift work and allocation on the parent side of forkpty.
        // The child only dereferences these buffers before execve.
        guard let resolvedExecutable = Self.resolveExecutable(
            executable,
            environment: environment,
            workingDirectory: workingDirectory
        ) else {
            throw PTYError.executableNotFound(executable)
        }
        let hasSlash = executable.contains("/")
        let cExecutable = strdup(resolvedExecutable)
        let cShellExecutable = strdup("/bin/sh")
        let fullArgs = [executable] + args
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: fullArgs.count + 1)
        for (index, value) in fullArgs.enumerated() {
            argv[index] = strdup(value)
        }
        argv[fullArgs.count] = nil
        let shellArgs = ["/bin/sh", resolvedExecutable] + args
        let shellArgv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: shellArgs.count + 1)
        for (index, value) in shellArgs.enumerated() {
            shellArgv[index] = strdup(value)
        }
        shellArgv[shellArgs.count] = nil
        let envStrings: [String] = environment.map { "\($0.key)=\($0.value)" }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envStrings.count + 1)
        for (index, value) in envStrings.enumerated() {
            envp[index] = strdup(value)
        }
        envp[envStrings.count] = nil
        let cWorkingDir: UnsafeMutablePointer<CChar>? = workingDirectory.flatMap {
            $0.isEmpty ? nil : strdup($0)
        }

        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &win)
        guard pid >= 0 else {
            let error = errno
            Darwin.free(cExecutable)
            Darwin.free(cShellExecutable)
            Self.freeVector(argv, count: fullArgs.count)
            Self.freeVector(shellArgv, count: shellArgs.count)
            Self.freeVector(envp, count: envStrings.count)
            if let p = cWorkingDir { Darwin.free(p) }
            throw PTYError.failedToFork(error)
        }

        if pid == 0 {
            // Child path avoids Swift collections and only calls async-signal-safe libc APIs.
            if let cWorkingDir {
                _ = chdir(cWorkingDir)
            }

            signal(SIGPIPE, SIG_DFL)
            signal(SIGCHLD, SIG_DFL)

            execve(cExecutable, UnsafePointer(argv), UnsafePointer(envp))
            if errno == ENOEXEC && !hasSlash {
                execve(cShellExecutable, UnsafePointer(shellArgv), UnsafePointer(envp))
            }
            _exit(127)
        }

        // Parent process: free allocated argument and environment arrays
        Darwin.free(cExecutable)
        Darwin.free(cShellExecutable)
        Self.freeVector(argv, count: fullArgs.count)
        Self.freeVector(shellArgv, count: shellArgs.count)
        Self.freeVector(envp, count: envStrings.count)
        if let p = cWorkingDir { Darwin.free(p) }

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
            self?.drainOutput(from: fd)
        }
        readSource.setCancelHandler {
            close(fd)
        }
        readSource.resume()
        self.readSource = readSource

        let processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        processSource.setEventHandler { [weak self] in
            self?.handleProcessExit(pid: pid)
        }
        processSource.resume()
        self.processSource = processSource
    }

    private func drainOutput(from fd: Int32) {
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
            stateLock.lock()
            let source: DispatchSourceRead?
            if masterFd == fd {
                masterFd = -1
                source = readSource
            } else {
                source = nil
            }
            stateLock.unlock()
            source?.cancel()
        }
    }

    private func handleProcessExit(pid: pid_t) {
        // Drain any remaining output in PTY buffer before closing
        stateLock.lock()
        let isCurrentProcess = shellPid == pid
        let fd = masterFd
        stateLock.unlock()
        guard isCurrentProcess else { return }
        if fd >= 0 { drainOutput(from: fd) }

        var status: Int32 = 0
        let waited = waitpid(pid, &status, 0)
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
        stateLock.lock()
        let readSource = self.readSource
        let processSource = self.processSource
        self.readSource = nil
        self.processSource = nil
        masterFd = -1
        shellPid = 0
        stateLock.unlock()

        readSource?.cancel()
        processSource?.cancel()
    }

    private static func freeVector(
        _ vector: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        count: Int
    ) {
        for index in 0..<count {
            if let value = vector[index] { Darwin.free(value) }
        }
        vector.deallocate()
    }

    private static func resolveExecutable(
        _ executable: String,
        environment: [String: String],
        workingDirectory: String?
    ) -> String? {
        guard !executable.contains("/") else { return executable }
        let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let workingDirectory = workingDirectory.map {
            URL(fileURLWithPath: $0, relativeTo: currentDirectory).standardizedFileURL
        } ?? currentDirectory

        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = directory.isEmpty
                ? workingDirectory.appendingPathComponent(executable)
                : URL(fileURLWithPath: String(directory), relativeTo: workingDirectory)
                    .appendingPathComponent(executable)
                    .standardizedFileURL
            if access(candidate.path, X_OK) == 0 { return candidate.path }
        }
        return nil
    }
}
#endif
