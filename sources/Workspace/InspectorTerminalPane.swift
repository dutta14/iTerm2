//
//  InspectorTerminalPane.swift
//  iTerm2SharedARC
//
//  The inspector's Terminal tab: a second shell in the session's repo. It runs on a dumb terminal
//  and shows plain text, which covers git, builds and scripts. Full-screen programs belong in a
//  regular terminal tab.
//

import AppKit
import Darwin

/// A login shell on its own pseudo-terminal.
final class InspectorShell {
    private let masterFD: Int32
    private let pid: pid_t
    private var readSource: DispatchSourceRead?
    private var exited = false
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?

    init?(directory: String, columns: Int = 80, rows: Int = 24) {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        var slaveName = [CChar](repeating: 0, count: 128)
        guard ttyname_r(slave, &slaveName, slaveName.count) == 0 else {
            close(master)
            close(slave)
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        environment["NO_COLOR"] = "1"
        let shell = environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // A new session whose first opened terminal becomes its controlling terminal, so job
        // control and Ctrl+C work.
        // Close everything else inherited from this app (session ptys, sockets), and reset signal
        // dispositions so the shell does not inherit ignored or blocked signals.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        let arguments = [shell, "-l", "-i"]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, shell, &actions, &attributes, argv, envp)
        close(slave)
        guard status == 0 else {
            close(master)
            return nil
        }
        masterFD = master
        pid = child

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        readSource = source
        source.resume()
    }

    deinit {
        terminate()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(masterFD, &buffer, buffer.count)
        if count > 0 {
            onOutput?(Data(buffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            finish()
        }
    }

    private func finish() {
        guard !exited else { return }
        exited = true
        readSource?.cancel()
        readSource = nil
        close(masterFD)
        reap()
        onExit?()
    }

    func write(_ data: Data) {
        guard !exited else { return }
        data.withUnsafeBytes { pointer in
            guard var base = pointer.baseAddress else { return }
            var remaining = pointer.count
            while remaining > 0 {
                let written = Darwin.write(masterFD, base, remaining)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                base += written
                remaining -= written
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard !exited else { return }
        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    /// True when something other than the shell itself is running in the foreground.
    var hasForegroundJob: Bool {
        guard !exited else { return false }
        let group = tcgetpgrp(masterFD)
        return group > 0 && group != pid
    }

    func terminate() {
        guard !exited else { return }
        exited = true
        readSource?.cancel()
        readSource = nil
        kill(pid, SIGHUP)
        close(masterFD)
        reap()
    }

    /// Collects the child so it doesn't linger, escalating if it ignores the hangup.
    private func reap() {
        let child = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<20 {
                if waitpid(child, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(child, SIGKILL)
            waitpid(child, &status, 0)
        }
    }
}

private final class InspectorTerminalTextView: NSTextView {
    var onInput: ((Data) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        var bytes: String?
        switch event.keyCode {
        case 36, 76: bytes = "\r"
        case 51: bytes = "\u{7F}"
        case 48: bytes = flags.contains(.shift) ? "\u{1B}[Z" : "\t"
        case 53: bytes = "\u{1B}"
        case 126: bytes = "\u{1B}[A"
        case 125: bytes = "\u{1B}[B"
        case 124: bytes = "\u{1B}[C"
        case 123: bytes = "\u{1B}[D"
        default:
            bytes = event.characters
        }
        if let bytes, let data = bytes.data(using: .utf8) {
            onInput?(data)
        }
    }

    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), let data = text.data(using: .utf8) {
            onInput?(data)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // Dead keys and input methods arrive here.
        if let text = insertString as? String, let data = text.data(using: .utf8) {
            onInput?(data)
        }
    }
}

final class InspectorTerminalPane: NSView {
    private let scrollView = NSScrollView()
    private let textView = InspectorTerminalTextView()
    private var shell: InspectorShell?
    private var buffer = TerminalTextBuffer()
    private var redrawScheduled = false
    private var directory: String?
    private var exitedNotice = false
    var onShellExit: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Workspace.Inspector.Terminal.A11y",
                                     defaultValue: "Terminal",
                                     comment: "Accessibility label of the inspector's terminal"))
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(String(localized: "Workspace.Inspector.Terminal.Output.A11y",
                                              defaultValue: "Shell output",
                                              comment: "Accessibility label of the inspector terminal's output area"))
        textView.onInput = { [weak self] data in
            self?.send(data)
        }
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    deinit {
        shell?.terminate()
    }

    var hasForegroundJob: Bool {
        return shell?.hasForegroundJob ?? false
    }

    var focusView: NSView { textView }

    /// Starts the shell on first use.
    func start(in directory: String) {
        guard shell == nil else { return }
        self.directory = directory
        launch()
    }

    private func launch() {
        guard let directory else { return }
        buffer.clear()
        exitedNotice = false
        let size = terminalSize()
        guard let newShell = InspectorShell(directory: directory, columns: size.columns, rows: size.rows) else {
            textView.string = String(localized: "Workspace.Inspector.Terminal.StartFailed",
                                     defaultValue: "Couldn't start a shell.",
                                     comment: "Shown in the inspector terminal when the shell can't be started")
            return
        }
        newShell.onOutput = { [weak self] data in
            guard let self else { return }
            self.buffer.append(data)
            self.scheduleRedraw()
        }
        newShell.onExit = { [weak self] in
            guard let self else { return }
            self.shell = nil
            self.exitedNotice = true
            self.scheduleRedraw()
            self.onShellExit?()
        }
        shell = newShell
    }

    func shutDown() {
        shell?.terminate()
        shell = nil
    }

    private func send(_ data: Data) {
        if shell == nil, exitedNotice {
            launch()
        }
        shell?.write(data)
    }

    private func terminalSize() -> (columns: Int, rows: Int) {
        let font = textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let cell = ("M" as NSString).size(withAttributes: [.font: font])
        let columns = Int(max(20, (scrollView.bounds.width - 20) / max(1, cell.width)))
        let rows = Int(max(5, scrollView.bounds.height / max(1, cell.height)))
        return (columns, rows)
    }

    private func scheduleRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.redraw()
        }
    }

    private func redraw() {
        redrawScheduled = false
        var text = buffer.text
        if exitedNotice {
            text += "\n" + String(localized: "Workspace.Inspector.Terminal.Exited",
                                  defaultValue: "[Shell exited. Press any key to start a new one.]",
                                  comment: "Shown in the inspector terminal after its shell ends")
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: WorkspaceColor.textPrimary,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textView.scrollToEndOfDocument(nil)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let size = terminalSize()
        shell?.resize(columns: size.columns, rows: size.rows)
    }
}
