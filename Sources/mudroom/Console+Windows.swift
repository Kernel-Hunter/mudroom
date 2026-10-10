#if os(Windows)
import WinSDK
import Foundation

// The Windows console, for the bits of the CLI that use termios and poll
// elsewhere: raw keys for `mudroom review`, echo off for pasted tokens,
// waiting for input with a timeout.

let STDIN_FILENO: Int32 = 0
let STDOUT_FILENO: Int32 = 1
let STDERR_FILENO: Int32 = 2

@discardableResult
func usleep(_ microseconds: UInt32) -> Int32 {
    Sleep(DWORD(max(1, microseconds / 1000)))
    return 0
}

enum WindowsConsole {
    // Console mode flags (consoleapi.h).
    static let processedInput: DWORD = 0x0001
    static let lineInput: DWORD = 0x0002
    static let echoInput: DWORD = 0x0004
    static let virtualTerminalInput: DWORD = 0x0200
    static let virtualTerminalProcessing: DWORD = 0x0004
    static let noAutoReturn: DWORD = 0x0008

    static var input: HANDLE? { GetStdHandle(STD_INPUT_HANDLE) }
    static var output: HANDLE? { GetStdHandle(STD_OUTPUT_HANDLE) }

    /// UTF-8 both ways, and ANSI escape sequences (colors, cursor moves)
    /// understood by the classic console as well as Windows Terminal.
    static func setUp() {
        _ = SetConsoleOutputCP(65001)
        _ = SetConsoleCP(65001)
        for which in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
            var mode: DWORD = 0
            if let h = GetStdHandle(which), GetConsoleMode(h, &mode) {
                _ = SetConsoleMode(h, mode | virtualTerminalProcessing)
            }
        }
    }

    /// Keys one at a time, as VT sequences, without echo, Ctrl+C as a
    /// byte. Returns the modes to restore, or nil without a console.
    static func enterRaw() -> (DWORD, DWORD)? {
        guard let i = input, let o = output else { return nil }
        var inMode: DWORD = 0, outMode: DWORD = 0
        guard GetConsoleMode(i, &inMode), GetConsoleMode(o, &outMode) else { return nil }
        _ = SetConsoleMode(i, (inMode & ~(echoInput | lineInput | processedInput)) | virtualTerminalInput)
        _ = SetConsoleMode(o, outMode | virtualTerminalProcessing | noAutoReturn)
        return (inMode, outMode)
    }

    static func restore(_ modes: (DWORD, DWORD)) {
        if let i = input { _ = SetConsoleMode(i, modes.0) }
        if let o = output { _ = SetConsoleMode(o, modes.1) }
    }

    /// Typing isn't shown until `restoreEcho`. Nil without a console.
    static func echoOff() -> DWORD? {
        var mode: DWORD = 0
        guard let i = input, GetConsoleMode(i, &mode) else { return nil }
        _ = SetConsoleMode(i, mode & ~echoInput)
        return mode
    }

    static func restoreEcho(_ mode: DWORD) {
        if let i = input { _ = SetConsoleMode(i, mode) }
    }

    /// Columns and rows of the visible window.
    static func size() -> (Int, Int)? {
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        guard let o = output, GetConsoleScreenBufferInfo(o, &info) else { return nil }
        let cols = Int(info.srWindow.Right) - Int(info.srWindow.Left) + 1
        let rows = Int(info.srWindow.Bottom) - Int(info.srWindow.Top) + 1
        return cols > 0 && rows > 0 ? (cols, rows) : nil
    }

    /// Waits up to `ms` milliseconds (-1: forever) for something to read.
    /// The console also reports focus changes, mouse moves and key
    /// releases; those are dropped here.
    static func waitForInput(_ ms: Int32) -> Bool {
        guard let i = input else { return false }
        let deadline = ms < 0 ? nil : Date().addingTimeInterval(Double(ms) / 1000)
        while true {
            let wait = deadline.map { DWORD(max(0, $0.timeIntervalSinceNow * 1000)) } ?? INFINITE
            guard WaitForSingleObject(i, wait) == WAIT_OBJECT_0 else { return false }
            // A pipe or a file: there is data.
            if GetFileType(i) != DWORD(FILE_TYPE_CHAR) { return true }
            var record = INPUT_RECORD()
            var n: DWORD = 0
            guard PeekConsoleInputW(i, &record, 1, &n) else { return false }
            if n == 0 { continue }
            if record.EventType == WORD(KEY_EVENT), record.Event.KeyEvent.bKeyDown.boolValue,
               record.Event.KeyEvent.uChar.UnicodeChar != 0 {
                return true
            }
            _ = ReadConsoleInputW(i, &record, 1, &n)
            if let d = deadline, d.timeIntervalSinceNow <= 0 { return false }
        }
    }

    static func readByte() -> UInt8? {
        var b: UInt8 = 0
        var n: DWORD = 0
        guard let i = input, ReadFile(i, &b, 1, &n, nil), n == 1 else { return nil }
        return b
    }

    /// Writes bytes as they are (no newline translation).
    static func write(_ p: UnsafeRawPointer, _ count: Int) -> Int {
        var n: DWORD = 0
        guard let o = output, WriteFile(o, p, DWORD(count), &n, nil) else { return -1 }
        return Int(n)
    }
}
#endif
