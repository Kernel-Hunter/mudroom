#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
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
            "\(why). Repair it with `mudroom setup --repair-network` (restarts the VM runtime) or the Repair Network button in Setup."
        }
    }

    /// Text for a person: ours as written, Foundation's localized message
    /// instead of an `Error Domain=NSCocoaErrorDomain Code=… UserInfo={…}` dump.
    public static func message(_ error: Error) -> String {
        if let e = error as? MudroomError { return e.description }
        if error is CocoaError || error is POSIXError || type(of: error) == NSError.self {
            let ns = error as NSError
            let text = ns.localizedDescription
            // Linux Foundation's messages leave out the file name.
            let path = (ns.userInfo[NSFilePathErrorKey] as? String) ?? (ns.userInfo[NSURLErrorKey] as? URL)?.path
            if let path, !text.contains((path as NSString).lastPathComponent) { return "\(text) (\(path))" }
            return text
        }
        return "\(error)"
    }
}
