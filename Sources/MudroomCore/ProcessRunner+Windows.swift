#if os(Windows)
import WinSDK
import Foundation

extension ProcessRunner {
    /// Runs a program on this console (so `docker run -it` gets the
    /// terminal) and returns its exit status. Ctrl+C reaches the child,
    /// which shares the console, and is ignored here so this process can
    /// still clean up when the child stops. Closing the console window, or
    /// signing out, gives the child `killAfter` seconds (at most the few
    /// Windows allows) before it is ended. `environment` adds variables to
    /// the child's environment only.
    ///
    /// Only the console handles are inherited: nothing else this process
    /// has open (the proxy's sockets, the runner lock) reaches the child.
    public static func runAttached(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                                   killAfter: TimeInterval = 10) throws -> Int32 {
        let exe = executable.replacingOccurrences(of: "/", with: "\\")
        var commandLine = Array(WindowsCommandLine.join([exe] + arguments).utf16) + [0]
        let env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        var block = WindowsCommandLine.environmentBlock(env)

        // The console handles, made inheritable, and only those.
        var handles: [HANDLE?] = []
        for which in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
            guard let h = GetStdHandle(which), h != INVALID_HANDLE_VALUE else { continue }
            if handles.contains(where: { $0 == h }) { continue }
            if SetHandleInformation(h, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)) { handles.append(h) }
        }
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let attributes = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { attributes.deallocate() }
        let list = LPPROC_THREAD_ATTRIBUTE_LIST(OpaquePointer(attributes))
        guard InitializeProcThreadAttributeList(list, 1, 0, &size) else {
            throw Win32.error("InitializeProcThreadAttributeList", executable, GetLastError())
        }
        defer { DeleteProcThreadAttributeList(list) }
        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        var info = PROCESS_INFORMATION()
        let created: Bool = handles.withUnsafeMutableBufferPointer { hs in
            if !hs.isEmpty {
                _ = UpdateProcThreadAttribute(list, 0, procThreadAttributeHandleList, hs.baseAddress,
                                              SIZE_T(hs.count * MemoryLayout<HANDLE?>.size), nil, nil)
                startup.lpAttributeList = list
            }
            return exe.withCString(encodedAs: UTF16.self) { app in
                block.withUnsafeMutableBufferPointer { envp in
                    withUnsafeMutablePointer(to: &startup) { sp in
                        sp.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { si in
                            CreateProcessW(app, &commandLine, nil, nil, !hs.isEmpty,
                                           DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(EXTENDED_STARTUPINFO_PRESENT),
                                           envp.baseAddress, nil, si, &info)
                        }
                    }
                }
            }
        }
        guard created else { throw Win32.error("CreateProcessW", executable, GetLastError()) }
        CloseHandle(info.hThread)
        defer { CloseHandle(info.hProcess) }

        consoleClosing = false
        _ = SetConsoleCtrlHandler(consoleHandler, true)
        defer { _ = SetConsoleCtrlHandler(consoleHandler, false) }

        var deadline: Date?
        var killed = false
        while WaitForSingleObject(info.hProcess, 50) == DWORD(WAIT_TIMEOUT) {
            if deadline == nil, consoleClosing { deadline = Date().addingTimeInterval(min(killAfter, 3)) }
            if let d = deadline, Date() >= d, !killed {
                TerminateProcess(info.hProcess, UINT(128 + SIGKILL))
                killed = true
            }
        }
        var code: DWORD = 0
        guard GetExitCodeProcess(info.hProcess, &code) else { throw Win32.error("GetExitCodeProcess", executable, GetLastError()) }
        return killed ? 128 + SIGKILL : Int32(bitPattern: code)
    }

    /// PROC_THREAD_ATTRIBUTE_HANDLE_LIST.
    private static let procThreadAttributeHandleList = DWORD_PTR(0x0002_0002)

    /// `which` on Windows: PATH (separated by ;) with each PATHEXT
    /// extension, .exe first, then where Docker Desktop and Podman install
    /// their CLIs.
    static func searchPath(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        func variable(_ key: String) -> String? { env.first { $0.key.uppercased() == key }?.value }
        var extensions = (variable("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD").split(separator: ";").map { $0.lowercased() }
        extensions.removeAll { $0 == ".exe" }
        extensions.insert(".exe", at: 0)
        let lower = name.lowercased()
        let names = extensions.contains(where: { lower.hasSuffix($0) }) ? [""] : extensions
        func existing(_ base: String) -> String? {
            for ext in names {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: base + ext, isDirectory: &isDir), !isDir.boolValue { return base + ext }
            }
            return nil
        }
        if name.contains("/") || name.contains("\\") { return existing(name) }
        let programFiles = variable("PROGRAMFILES") ?? #"C:\Program Files"#
        let dirs = (variable("PATH") ?? "").split(separator: ";").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            + [programFiles + #"\Docker\Docker\resources\bin"#, programFiles + #"\RedHat\Podman"#]
        for dir in dirs where !dir.isEmpty {
            if let found = existing(dir.hasSuffix("\\") ? dir + name : dir + "\\" + name) { return found }
        }
        return nil
    }
}

/// Set by the console handler when the window is closing or the user is
/// signing out.
nonisolated(unsafe) private var consoleClosing = false

private let consoleHandler: PHANDLER_ROUTINE = { (event: DWORD) -> WindowsBool in
    switch event {
    case DWORD(CTRL_C_EVENT), DWORD(CTRL_BREAK_EVENT):
        // The child got it too; it decides whether to stop.
        return true
    case DWORD(CTRL_CLOSE_EVENT), DWORD(CTRL_LOGOFF_EVENT), DWORD(CTRL_SHUTDOWN_EVENT):
        consoleClosing = true
        // Windows ends this process when the handler returns (or after
        // about five seconds): wait here so `runAttached`'s caller gets to
        // stop the sandbox and record the exit.
        Sleep(4_500)
        return true
    default:
        return false
    }
}
#endif
