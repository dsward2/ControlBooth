import Darwin
import Foundation

/// A child process whose stdin/stdout are a pseudo-terminal (so a curses UI
/// such as dsd-neo's terminal frontend runs normally) and whose stderr is a
/// separate pipe read line by line.
///
/// Spawned with `posix_spawn` — never `fork` in a multithreaded app — as a new
/// session. The pty is not made the child's controlling terminal (posix_spawn
/// can't issue TIOCSCTTY), so terminal-generated signals don't apply: `resize`
/// sends SIGWINCH itself, and stopping is done with explicit signals.
///
/// Callbacks run on a private queue; the owner hops to its own actor.
nonisolated final class PseudoTerminalProcess: @unchecked Sendable {
    struct SpawnError: Error, CustomStringConvertible {
        let description: String
    }

    let pid: pid_t
    private let masterFD: Int32
    private let queue = DispatchQueue(label: "PseudoTerminalProcess.io")
    private let readSource: DispatchSourceRead
    private let stderrHandle: FileHandle
    private let exited = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exitStatus: Int32?

    /// - Parameters:
    ///   - onOutput: terminal output (the pty's master side), in chunks.
    ///   - onStderrLine: each complete stderr line, without the newline.
    ///   - onExit: the raw `waitpid` status, once.
    init(executable: URL,
         arguments: [String],
         environment: [String: String],
         workingDirectory: URL,
         columns: UInt16 = 120,
         rows: UInt16 = 40,
         onOutput: @escaping @Sendable (Data) -> Void,
         onStderrLine: @escaping @Sendable (String) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) throws {

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw SpawnError(description: "openpty failed: \(String(cString: strerror(errno)))")
        }
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&errPipe) == 0 else {
            close(master); close(slave)
            throw SpawnError(description: "pipe failed: \(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, slave, 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New session; every descriptor not named above closed in the child;
        // default signal handling (the app ignores SIGPIPE) and no blocked
        // signals.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = [executable.path] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var cArgv = argv.map { strdup($0) } + [nil]
        var cEnvp = envp.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnvp.forEach { free($0) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, executable.path, &actions, &attributes, &cArgv, &cEnvp)
        close(slave)
        close(errPipe[1])
        guard rc == 0 else {
            close(master)
            close(errPipe[0])
            throw SpawnError(description: "posix_spawn \(executable.path) failed: \(String(cString: strerror(rc)))")
        }
        pid = childPID
        masterFD = master
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(errPipe[0], F_SETFD, FD_CLOEXEC)

        // Terminal output. Reading continuously matters even with nobody
        // watching: a full pty buffer would block dsd-neo's screen updates.
        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        readSource.setEventHandler { [masterFD = master, readSource] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let n = read(masterFD, &buffer, buffer.count)
            if n > 0 {
                onOutput(Data(buffer[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                readSource.cancel()   // EIO once the child has closed the slave side
            }
        }
        readSource.setCancelHandler { close(master) }
        readSource.resume()

        // Stderr, split into lines.
        stderrHandle = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
        let lineBuffer = LineBuffer()
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let tail = lineBuffer.flush() { onStderrLine(tail) }
                return
            }
            for line in lineBuffer.append(data) { onStderrLine(line) }
        }

        // Reap on a dedicated thread so stopping can wait for the exit.
        let waitedPID = childPID
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(waitedPID, &status, 0) < 0 && errno == EINTR {}
            self?.lock.lock()
            self?.exitStatus = status
            self?.lock.unlock()
            self?.exited.signal()
            onExit(status)
        }
    }

    deinit {
        readSource.cancel()
        stderrHandle.readabilityHandler = nil
    }

    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitStatus != nil
    }

    /// Keystrokes / pasted text for the program.
    func write(_ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(masterFD, bytes.baseAddress! + offset, bytes.count - offset)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                offset += n
            }
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
        kill(pid, SIGWINCH)
    }

    func signal(_ signal: Int32) {
        guard !hasExited else { return }
        kill(pid, signal)
    }

    /// SIGINT (dsd-neo's clean shutdown, which releases the RTL-SDR), then
    /// SIGKILL if it hasn't exited within `grace`. Blocks until it is gone
    /// (or `grace` + 2 s), so a replacement can open the same device.
    func terminateAndWait(grace: TimeInterval = 3) {
        guard !hasExited else { return }
        kill(pid, SIGINT)
        if exited.wait(timeout: .now() + grace) == .success { exited.signal(); return }
        kill(pid, SIGKILL)
        if exited.wait(timeout: .now() + 2) == .success { exited.signal() }
    }
}

/// Splits a byte stream into newline-terminated lines.
nonisolated final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineData = pending[pending.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
