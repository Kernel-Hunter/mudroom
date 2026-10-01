import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import MudroomCore

/// `mudroom review`: pick files in the terminal, read their diffs, apply.
/// Plain ANSI escapes, no curses.
struct Review: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Review a session in the terminal: toggle files, read diffs, apply the selection.",
        discussion: """
        Keys: up/down (or j/k) move, space toggles, a toggles all, enter shows the diff, \
        x applies the selected paths (after a y/N prompt), q quits. Conflicting paths \
        start unselected. For per-hunk applies use `mudroom hunks` and `apply --hunks`.
        """)

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    func run() throws {
        guard isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 else {
            fail(MudroomError.invalid("review needs a terminal; use `mudroom diff` and `mudroom apply` instead"))
        }
        var handle: SessionHandle
        var state: TerminalReview
        let renderer: DiffRenderer
        let applier: Applier
        var reviewed = ReviewedChanges([])
        do {
            handle = try store().open(session)
            guard handle.hasClones else { throw MudroomError.invalid("session \(handle.session.id) was discarded") }
            let diff = try Differ.compare(base: handle.base, work: handle.work)
            applier = Applier(handle: handle)
            let dry = try applier.preflight(diff: diff)
            reviewed = ReviewedChanges(diff.changes + diff.gitMetadataChanges)
            try? reviewed.save(handle)
            state = TerminalReview(changes: diff.changes, conflicts: Dictionary(dry.conflicts.map { ($0.path, $0.reason) }) { a, _ in a })
            renderer = DiffRenderer(base: handle.base, work: handle.work)
        } catch { fail(error) }

        let term = Terminal()
        term.enter()
        defer { term.leave() }
        let title = "mudroom review \(handle.session.id)  \(handle.session.projectName)"

        var drawnSize: (Int, Int)?
        var dirty = true
        while true {
            let (cols, rows) = term.size()
            let bodyHeight = max(1, rows - 3)
            if dirty || drawnSize.map({ $0 != (cols, rows) }) ?? true {
                draw(term, state: state, title: title, cols: cols, rows: rows, bodyHeight: bodyHeight)
                drawnSize = (cols, rows)
                dirty = false
            }
            guard let key = term.readKey() else { continue }
            dirty = true
            if key == .char("\u{3}") { return } // Ctrl-C
            switch state.handle(key, height: bodyHeight) {
            case .none:
                break
            case .quit:
                return
            case .openDiff(let i):
                do { state.showDiff(try renderer.renderOne(state.items[i].change)) } catch { state.message = "\(error)" }
            case .apply(let paths):
                do {
                    try SessionGuard.ensureIdle(handle)
                    let report = try applier.apply(paths: paths, reviewed: reviewed)
                    let conflicts = Dictionary(report.conflicts.map { ($0.path, $0.reason) }) { a, _ in a }
                    state.markApplied(report.applied + report.alreadyApplied, conflicts: conflicts)
                    if !report.applied.isEmpty { try handle.setStatus(.applied) }
                    var parts = ["applied \(report.applied.count)"]
                    if !report.conflicts.isEmpty { parts.append("\(report.conflicts.count) conflict(s)") }
                    if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped") }
                    state.message = parts.joined(separator: ", ") + ". Undo with: mudroom undo \(handle.session.id)"
                } catch {
                    state.message = "apply failed: \(error)"
                }
            }
        }
    }

    func draw(_ term: Terminal, state: TerminalReview, title: String, cols: Int, rows: Int, bodyHeight: Int) {
        // Home, then overwrite each line and clear its tail: no flicker.
        var out = "\u{1b}[H"
        let selected = state.selectedPaths.count
        let header: String
        if case .diff = state.mode, let path = state.items.indices.contains(state.cursor) ? state.items[state.cursor].path : nil {
            header = "\(title)  \(path)"
        } else {
            header = "\(title)  \(state.items.count) changes, \(selected) selected"
        }
        let eol = "\u{1b}[0m\u{1b}[K\r\n"
        out += Terminal.style(String(header.prefix(cols)), .bold) + eol
        let body = state.body(width: cols, height: bodyHeight, style: Terminal.style)
        for line in body { out += line + eol }
        for _ in body.count..<bodyHeight { out += eol }
        out += String((state.message ?? "").prefix(cols)) + eol
        out += Terminal.style(String(state.footer.prefix(cols)), .dim) + "\u{1b}[K\u{1b}[J"
        term.write(out)
    }
}

private func writeOut(_ p: UnsafeRawPointer, _ n: Int) -> Int { write(STDOUT_FILENO, p, n) }

/// Raw mode, the alternate screen and key decoding.
final class Terminal {
    private var saved = termios()
    private var active = false

    func enter() {
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return }
        var raw = saved
        cfmakeraw(&raw)
        // Keep output post-processing off (cfmakeraw), we send \r\n ourselves.
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        active = true
        write("\u{1b}[?1049h\u{1b}[?25l")
    }

    func leave() {
        guard active else { return }
        write("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l")
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        active = false
    }

    deinit { leave() }

    func write(_ s: String) {
        let data = Array(s.utf8)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = writeOut(raw.baseAddress! + off, raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    /// Columns and rows, from TIOCGWINSZ; 80x24 if unknown.
    func size() -> (Int, Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    private func readByte(timeoutMs: Int32) -> UInt8? {
        var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeoutMs) > 0 else { return nil }
        var b: UInt8 = 0
        return read(STDIN_FILENO, &b, 1) == 1 ? b : nil
    }

    /// Blocks for one key. Nil on a timeout (used to redraw after a resize).
    func readKey() -> TerminalReview.Key? {
        guard let b = readByte(timeoutMs: 500) else { return nil }
        switch b {
        case 0x1b:
            guard let b2 = readByte(timeoutMs: 30) else { return .escape }
            guard b2 == UInt8(ascii: "[") || b2 == UInt8(ascii: "O") else { return .escape }
            guard let b3 = readByte(timeoutMs: 30) else { return .escape }
            switch b3 {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            case UInt8(ascii: "5"), UInt8(ascii: "6"), UInt8(ascii: "1"), UInt8(ascii: "4"):
                _ = readByte(timeoutMs: 30) // trailing ~
                return [UInt8(ascii: "5"): .pageUp, UInt8(ascii: "6"): .pageDown,
                        UInt8(ascii: "1"): .home, UInt8(ascii: "4"): .end][b3]
            default: return nil
            }
        case 0x0d, 0x0a: return .enter
        case 0x20: return .space
        case 0x7f: return .left
        default: return .char(Character(Unicode.Scalar(b)))
        }
    }

    static func style(_ s: String, _ style: TerminalReview.Style) -> String {
        let code = switch style {
        case .bold: "1"
        case .added: "32"
        case .deleted: "31"
        case .hunk: "36"
        case .cursor: "7"
        case .dim: "2"
        }
        return "\u{1b}[\(code)m\(s)\u{1b}[0m"
    }
}
