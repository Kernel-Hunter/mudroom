import Foundation

/// Which process in the sandbox opened each proxy connection.
///
/// The proxy on the host sees a connection come in from the VM's address
/// and a source port, nothing more. A small watcher inside the VM looks for
/// new TCP connections to the proxy in /proc/net/tcp and tcp6, finds the
/// process holding each socket (/proc/<pid>/fd), and sends the proxy one
/// line per connection over its own connection: source port, pid and the
/// command lines of that process and its parents up to the agent. The proxy
/// matches the line to the connection by source port and time, and the log
/// entry gets `pid`, `command` and `parents`.
///
/// This is information, not enforcement: the allowlist decision is made on
/// the host and never depends on it. The watcher polls, so a connection that
/// opens and closes between two looks is missed; such entries carry no
/// command. A program can also rename itself (its command line is its own
/// memory), so a hostile agent can mislead it.
public struct ConnectionWatch: Sendable, Equatable {
    /// Shared secret the watcher sends first, so a program in the sandbox
    /// can't pose as the watcher. Only the watcher's environment has it.
    public var token: String
    /// Where the sandbox reaches the proxy (HTTPS_PROXY's address and port).
    public var proxyAddress: IPAddress
    public var proxyPort: UInt16

    /// Nil if `host` isn't an IP address or the port is 0.
    public init?(token: String, proxyHost host: String, port: UInt16) {
        guard port != 0, let a = IPAddress(host), Self.isToken(token) else { return nil }
        self.token = token
        proxyAddress = a
        proxyPort = port
    }

    /// 32 random hex digits.
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<2).map { _ in
            let s = String(g.next() as UInt64, radix: 16)
            return String(repeating: "0", count: 16 - s.count) + s
        }.joined()
    }

    static func isToken(_ s: String) -> Bool {
        s.count >= 16 && s.count <= 128 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// The first line the watcher sends, before the records.
    public static let greeting = "MUDROOM-WATCH"

    /// The proxy's address and port as /proc/net/tcp and /proc/net/tcp6
    /// write a connection's remote end: "0180A8C0:C822" for
    /// 192.168.128.1:51234, and the IPv4-mapped form for tcp6. Each 32-bit
    /// word of the address is printed in the guest's byte order, which is
    /// little-endian on the arm64 and x86-64 machines these VMs run on.
    public static func procNetAddresses(_ a: IPAddress, port: UInt16) -> [String] {
        func word(_ b: ArraySlice<UInt8>) -> String {
            b.reversed().map { String(format: "%02X", $0) }.joined()
        }
        let p = String(format: "%04X", port)
        switch a {
        case .v4(let v):
            let bytes = [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
            let v4 = word(bytes[...])
            return ["\(v4):\(p)", "0000000000000000FFFF0000\(v4):\(p)"]
        case .v6(let b):
            let v6 = stride(from: 0, to: 16, by: 4).map { word(b[$0..<($0 + 4)]) }.joined()
            var out = ["\(v6):\(p)"]
            if let v4 = a.asIPv4 { out.insert(contentsOf: procNetAddresses(.v4(v4), port: port).prefix(1), at: 0) }
            return out
        }
    }

    /// The watcher's arguments after the token: proxy host and port, then
    /// the /proc/net spellings of the proxy's address. Only hex digits,
    /// colons, dots and digits, so the shell can split them on spaces.
    public var arguments: [String] {
        ["\(proxyAddress)", "\(proxyPort)"] + Self.procNetAddresses(proxyAddress, port: proxyPort)
    }

    /// The watcher, a bash script (bash's /dev/tcp, `mapfile`, `read -t`
    /// and associative arrays keep it to one process while idle). It runs
    /// as root with only CAP_SYS_PTRACE and CAP_DAC_READ_SEARCH, which it
    /// needs to read the agent's /proc/<pid>/fd. Arguments: proxy host,
    /// proxy port, the agent's pid (where a chain of parents stops), then
    /// the proxy's /proc/net addresses. The token comes in
    /// MUDROOM_WATCH_TOKEN (and the script itself in MUDROOM_WATCH, so it
    /// doesn't fill the process list).
    ///
    /// It reads TCP's ActiveOpens counter in /proc/net/snmp every 100 ms
    /// (every 20 ms for a second after a connection was opened) and only
    /// reads the connection tables when it changed. New connections to the
    /// proxy are resolved to a process with one `find` over /proc/*/fd.
    /// Each line it sends: port, tab, pid (or "-" when the socket was gone
    /// before its process was found), then a tab before each command line,
    /// the process first and the agent last. Control characters in command
    /// lines become spaces; each is cut to 256 bytes.
    public static let script = #"""
    set -f
    host=$1 port=$2 top=$3
    shift 3
    pats=" $* "
    exec 3<>"/dev/tcp/$host/$port" || exit 1
    printf 'MUDROOM-WATCH %s\r\n\r\n' "$MUDROOM_WATCH_TOKEN" >&3 || exit 1
    unset MUDROOM_WATCH_TOKEN MUDROOM_WATCH
    # read -t on a pipe that never gets data: a sleep without a process.
    exec 4<> <(:)
    declare -A seen=()
    opens= quick=0 me=$$ line=

    # line=the command lines of $1 and its parents, up to the agent.
    chain() {
      local p=$1 n=0 s c
      local -a a
      line=
      while (( n < 8 )) && [[ $p =~ ^[1-9][0-9]*$ ]]; do
        a=()
        mapfile -d '' -t a < "/proc/$p/cmdline" 2>/dev/null
        c="${a[*]}"
        c=${c//[[:cntrl:]]/ }
        line+=$'\t'"${c:0:256}"
        (( p == top )) && break
        read -r s < "/proc/$p/stat" 2>/dev/null || break
        s=${s##*) }
        set -- $s
        p=$2
        n=$((n + 1))
      done
    }

    # Finds the processes holding the sockets "port/inode" and reports them.
    # A socket held by several processes (a shell and the child it forked)
    # goes to the oldest, the one that opened it.
    resolve() {
      local - k ino out l tgt pid port
      local -a expr=()
      local -A owner=()
      for k in "$@"; do expr+=(-o -lname "socket:\[${k#*/}\]"); done
      set +f
      out=$(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 \( "${expr[@]:1}" \) -printf '%h %l\n' 2>/dev/null 3>&- 4>&-)
      set -f
      while read -r l tgt; do
        [[ $l ]] || continue
        pid=${l#/proc/} pid=${pid%/fd}
        ino=${tgt#socket:[} ino=${ino%]}
        if [[ $pid == "$me" ]]; then owner[$ino]=self; continue; fi
        [[ ${owner[$ino]} == self ]] && continue
        [[ ${owner[$ino]} ]] && (( ${owner[$ino]} < pid )) && continue
        owner[$ino]=$pid
      done <<< "$out"
      for k in "$@"; do
        port=${k%/*} ino=${k#*/}
        pid=${owner[$ino]}
        [[ $pid == self ]] && continue
        if [[ $pid ]]; then chain "$pid"; else line= pid=-; fi
        printf '%s\t%s%s\n' "$port" "$pid" "$line" >&3 || exit 0
      done
    }

    # Connections to the proxy not seen before, as "port/inode".
    scan() {
      local f l k
      local -a rows new=()
      local -A now=()
      for f in /proc/net/tcp /proc/net/tcp6; do
        mapfile -t rows < "$f" 2>/dev/null || continue
        for l in "${rows[@]:1}"; do
          set -- $l
          [[ $pats == *" $3 "* && ${10} != 0 ]] || continue
          k="$((16#${2##*:}))/${10}"
          now[$k]=1
          [[ ${seen[$k]} ]] || new+=("$k")
        done
      done
      seen=()
      for k in "${!now[@]}"; do seen[$k]=1; done
      (( ${#new[@]} )) && resolve "${new[@]}"
    }

    while :; do
      mapfile -t snmp < /proc/net/snmp
      for l in "${snmp[@]}"; do
        case $l in "Tcp: "[0-9-]*) set -- $l; break;; esac
      done
      if [[ $6 != "$opens" ]]; then opens=$6 quick=50; scan; fi
      if (( quick > 0 )); then quick=$((quick - 1)); read -t 0.02 -u 4; else read -t 0.1 -u 4; fi
    done
    """#
}

/// The process that opened a connection, as the watcher reported it.
public struct ConnectionOrigin: Sendable, Equatable {
    public var pid: Int
    /// Its command line, then its parents' (nearest first), up to the agent.
    public var commands: [String]

    public init(pid: Int, commands: [String]) {
        self.pid = pid
        self.commands = commands
    }

    static let maxCommands = 8
    static let maxCommandLength = 256

    /// One watcher line: "port\tpid\tcmd\tparent...", or "port\t-" for a
    /// connection whose process was gone. Nil for anything malformed.
    /// Command lines are the sandbox's to choose, so they are cleaned
    /// here too: no control characters (a terminal would act on escape
    /// sequences) and no bidirectional overrides.
    static func parse(_ line: Substring) -> (port: UInt16, origin: ConnectionOrigin?)? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2, let port = UInt16(fields[0]), port != 0 else { return nil }
        if fields[1] == "-" { return (port, nil) }
        guard let pid = Int(fields[1]), pid > 0 else { return nil }
        let commands = fields.dropFirst(2).prefix(maxCommands).map { clean(String($0)) }
        return (port, ConnectionOrigin(pid: pid, commands: commands))
    }

    /// Control and bidirectional-formatting characters become spaces; runs
    /// of spaces collapse; the result is cut to `maxCommandLength`.
    public static func clean(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for u in s.unicodeScalars {
            let v = u.value
            let bad = v < 0x20 || (v >= 0x7f && v < 0xa0) || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
                || v == 0x200e || v == 0x200f || v == 0x061c
            let c: Unicode.Scalar = bad ? " " : u
            if c == " " {
                if lastSpace { continue }
                lastSpace = true
            } else {
                lastSpace = false
            }
            out.unicodeScalars.append(c)
            if out.unicodeScalars.count >= maxCommandLength { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// What the watcher reported, kept by the proxy to fill in log entries.
/// Records are matched by source port and the time they arrived.
final class ConnectionOrigins: @unchecked Sendable {
    struct Record: Sendable {
        var port: UInt16
        var origin: ConnectionOrigin?
        var time: Date
    }

    private let cond = NSCondition()
    private var byPort: [UInt16: [Record]] = [:]
    private var arrivals: [UInt16] = []
    private var arrivalsStart = 0
    private var count = 0
    /// Records kept at most (oldest go first), and per port.
    let limit: Int
    static let perPort = 4

    init(limit: Int = 20_000) {
        self.limit = limit
    }

    func add(_ port: UInt16, _ origin: ConnectionOrigin?, at time: Date = Date()) {
        cond.withLock {
            var list = byPort[port] ?? []
            list.append(Record(port: port, origin: origin, time: time))
            count += 1
            if list.count > Self.perPort {
                count -= list.count - Self.perPort
                list.removeFirst(list.count - Self.perPort)
            }
            byPort[port] = list
            arrivals.append(port)
            while count > limit, arrivalsStart < arrivals.count {
                let p = arrivals[arrivalsStart]
                arrivalsStart += 1
                if var l = byPort[p], !l.isEmpty {
                    l.removeFirst()
                    byPort[p] = l.isEmpty ? nil : l
                    count -= 1
                }
            }
            if arrivalsStart > 4096 {
                arrivals.removeFirst(arrivalsStart)
                arrivalsStart = 0
            }
            cond.broadcast()
        }
    }

    /// The record for a connection from `port` that started at `start`:
    /// the one that arrived closest to `start`, between a second before it
    /// and `end`. The watcher sees a socket when the client opens it, which
    /// is around when the proxy accepts it; a record from long before is
    /// an earlier connection that happened to use the same port.
    func find(port: UInt16, start: Date, end: Date) -> Record? {
        cond.withLock { match(port: port, start: start, end: end) }
    }

    /// `find`, waiting until `deadline` for the record to arrive.
    func wait(port: UInt16, start: Date, deadline: Date, cancelled: () -> Bool = { false }) -> Record? {
        cond.withLock {
            while true {
                if let r = match(port: port, start: start, end: deadline) { return r }
                if cancelled() || Date() >= deadline { return nil }
                _ = cond.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
            }
        }
    }

    private func match(port: UInt16, start: Date, end: Date) -> Record? {
        let from = start.addingTimeInterval(-1)
        return byPort[port]?.filter { $0.time >= from && $0.time <= end }
            .min { abs($0.time.timeIntervalSince(start)) < abs($1.time.timeIntervalSince(start)) }
    }

    /// Reads watcher lines from a stream until it ends. `read` returns
    /// bytes, or nil at the end.
    func consume(_ read: () -> Data?) {
        var partial = Data()
        while let data = read() {
            partial.append(data)
            while let nl = partial.firstIndex(of: 0x0A) {
                let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                partial = Data(partial[partial.index(after: nl)...])
                if let (port, origin) = ConnectionOrigin.parse(Substring(line)) { add(port, origin) }
            }
            // One line is a few KB at most; anything longer is junk.
            if partial.count > 64 << 10 { partial = Data() }
        }
    }
}

extension NetworkLog {
    /// A short name for the program in a command line: "curl" for
    /// "curl -sI https://github.com", the script for an interpreter
    /// ("npm" for "node /usr/local/bin/npm install", "pip" for
    /// "python3 -m pip install"), the shell itself for "bash -c ...".
    public static func programName(_ command: String) -> String {
        var args = command.split(separator: " ").map(String.init)
        func base(_ s: String) -> String { s.split(separator: "/").last.map(String.init) ?? s }
        if let first = args.first, base(first) == "env" {
            args = Array(args.dropFirst().drop { $0.hasPrefix("-") || $0.contains("=") })
        }
        guard let first = args.first else { return "?" }
        let prog = base(first)
        guard isInterpreter(prog) else { return prog }
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "-m", i + 1 < args.count { return args[i + 1] }
            if ["-c", "-e", "--eval", "-p", "--print", "-"].contains(a) { return prog }
            if a.hasPrefix("-") {
                i += 1
                continue
            }
            var script = base(a)
            for ext in [".js", ".mjs", ".cjs", ".py", ".rb", ".pl", ".sh"] where script.hasSuffix(ext) && script.count > ext.count {
                script.removeLast(ext.count)
            }
            return script
        }
        return prog
    }

    static func isInterpreter(_ p: String) -> Bool {
        if ["node", "nodejs", "bun", "deno", "ruby", "perl", "php", "sh", "bash", "dash", "zsh"].contains(p) { return true }
        // python, python3, python3.12
        return p.hasPrefix("python") && p.dropFirst(6).allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Whether a log has any processes in it (a session ran with the
    /// connection watcher).
    public static func hasProcesses(_ entries: [NetworkLogEntry]) -> Bool {
        entries.contains { $0.command != nil }
    }

    /// "claude > bash > curl": the program names from the agent down to
    /// the process that connected.
    public static func programChain(_ e: NetworkLogEntry) -> String? {
        guard let command = e.command else { return nil }
        return ((e.parents ?? []).reversed() + [command]).map(programName).joined(separator: " > ")
    }
}

extension NetworkLog.HostSummary {
    mutating func add(program e: NetworkLogEntry) {
        guard let command = e.command else {
            unattributed += 1
            return
        }
        let name = NetworkLog.programName(command)
        if !programs.contains(name) { programs.append(name) }
    }
}
