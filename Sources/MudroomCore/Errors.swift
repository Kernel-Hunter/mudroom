#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public enum MudroomError: Error, CustomStringConvertible, Equatable {
    case posix(String, String, Int32)
    case notADirectory(String)
    case sessionNotFound(String)
    case ambiguousSession(String, [String])
    case backendUnavailable(String)
    case commandFailed(String, Int32, String)
    case nothingToUndo(String)
    case invalid(String)
    /// The VM can't reach Mudroom's proxy; `container system` needs a restart.
    case networkUnreachable(String)

    public var description: String {
        switch self {
        case .posix(let call, let path, let code):
            "\(call)(\(path)) failed: \(String(cString: strerror(code)))"
        case .notADirectory(let path):
            "not a directory: \(path)"
        case .sessionNotFound(let id):
            "no session matches '\(id)'"
        case .ambiguousSession(let id, let matches):
            "'\(id)' matches several sessions: \(matches.joined(separator: ", "))"
        case .backendUnavailable(let why):
            why
        case .commandFailed(let cmd, let code, let output):
            "\(cmd) exited with status \(code)" + (output.isEmpty ? "" : ":\n\(output)")
        case .nothingToUndo(let id):
            "session \(id) has no apply to undo"
        case .invalid(let why):
            why
        case .networkUnreachable(let why):
            "\(why). Repair it with `mudroom setup --repair-network` (restarts the container system) or the Repair network button in the app."
        }
    }
}
