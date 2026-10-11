import Foundation

/// How a Windows program gets its arguments and environment: one command
/// line string that the program splits itself (the Microsoft C runtime's
/// rules, which Go programs like docker.exe follow too), and one block of
/// NAME=value strings. Plain string code, so it is tested on every
/// platform.
public enum WindowsCommandLine {
    /// Quotes one argument so CommandLineToArgvW and the C runtime read it
    /// back unchanged.
    public static func quote(_ arg: String) -> String {
        if !arg.isEmpty && !arg.contains(where: { " \t\n\u{0B}\"".contains($0) }) { return arg }
        var out = "\""
        var backslashes = 0
        for c in arg {
            if c == "\\" {
                backslashes += 1
                continue
            }
            if c == "\"" {
                // Backslashes before a quote are doubled, and the quote escaped.
                out += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
            } else {
                out += String(repeating: "\\", count: backslashes) + String(c)
            }
            backslashes = 0
        }
        // Backslashes before the closing quote are doubled too.
        out += String(repeating: "\\", count: backslashes * 2) + "\""
        return out
    }

    public static func join(_ args: [String]) -> String {
        args.map(quote).joined(separator: " ")
    }

    /// The environment block CreateProcessW takes: NAME=value strings, each
    /// ending in a NUL, sorted by name without regard to case, then one
    /// more NUL.
    public static func environmentBlock(_ env: [String: String]) -> [UInt16] {
        var block: [UInt16] = []
        for (k, v) in env.sorted(by: { ($0.key.uppercased(), $0.key) < ($1.key.uppercased(), $1.key) }) {
            block += Array("\(k)=\(v)".utf16)
            block.append(0)
        }
        if block.isEmpty { block.append(0) }
        block.append(0)
        return block
    }
}
