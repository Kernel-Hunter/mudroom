import Foundation

/// A packet filter set up inside the VM before the agent starts (apple
/// backend, locked and offline modes).
///
/// The host-only network's gateway is the Mac, so without it the VM could
/// connect to any service on the Mac that listens on all interfaces, and to
/// other VMs on the same network. The rules let the VM open exactly one kind
/// of connection, TCP to Mudroom's proxy (none at all in offline mode), plus
/// loopback. Everything else, IPv4 and IPv6, is rejected.
///
/// The sandbox's first process runs as root with CAP_NET_ADMIN, loads the
/// rules with `nft`, checks they are there, and then becomes the image's
/// user with `setpriv`: no capabilities, an empty bounding set and
/// no_new_privs, so neither the agent nor anything it runs (setuid binaries
/// included) can change the rules again. If any step fails, the agent is not
/// started.
public struct GuestFirewall: Sendable, Equatable {
    /// The one address and TCP port the sandbox may connect to.
    public struct Endpoint: Sendable, Equatable {
        public var address: IPAddress
        public var port: UInt16
    }

    /// nil: no connections leave the VM at all (offline mode).
    public let proxy: Endpoint?

    /// Allows only TCP to `host:port`. Nil if `host` isn't an IP address
    /// (the rules never contain a name) or the port is 0.
    public init?(proxyHost host: String, port: UInt16) {
        guard port != 0, let address = IPAddress(host) else { return nil }
        proxy = Endpoint(address: address, port: port)
    }

    /// Allows nothing but loopback.
    public static let closed = GuestFirewall(proxy: nil)

    private init(proxy: Endpoint?) { self.proxy = proxy }

    public static let table = "mudroom"

    /// The ruleset, for `nft -f -`.
    public var rules: String {
        var allow = ""
        if let proxy {
            let family = if case .v4 = proxy.address { "ip" } else { "ip6" }
            allow = "\n    \(family) daddr \(proxy.address) tcp dport \(proxy.port) accept"
        }
        return """
        table inet \(Self.table) {
          chain output {
            type filter hook output priority 0; policy drop;
            oif "lo" accept\(allow)
            reject with icmpx type admin-prohibited
          }
          chain input {
            type filter hook input priority 0; policy drop;
            iif "lo" accept
            ct state established,related accept
          }
          chain forward {
            type filter hook forward priority 0; policy drop;
          }
        }
        """
    }

    /// Lines the setup script writes to stderr when it stops, so the
    /// network probe can tell a firewall failure from a network one.
    public static let failureMarker = "mudroom-firewall: "

    /// Exit status of the setup script when it refuses to start the agent.
    public static let failureStatus: Int32 = 125

    /// The sandbox's first process (`/bin/sh -c script`). Arguments: the
    /// rules, the user and group to become (empty: the image has none, so
    /// root), "1" to set HOME from that user's passwd entry, "--", then the
    /// command. Everything is passed as arguments, never pasted into the
    /// script, so nothing in them is interpreted by the shell.
    public static let script = #"""
    fail() { echo "mudroom-firewall: $1. The agent was not started." >&2; exit 125; }
    rules=$1 u=$2 g=$3 sethome=$4
    [ "$5" = "--" ] || fail "bad arguments"
    shift 5
    command -v nft >/dev/null 2>&1 || fail "this image has no nft (the nftables package), which locked and offline modes need to firewall the VM. Rebuild Mudroom's image with \`mudroom image build\`, or add nftables to your image"
    command -v setpriv >/dev/null 2>&1 || fail "this image has no setpriv (util-linux), which locked and offline modes need to drop root before the agent starts. Rebuild Mudroom's image with \`mudroom image build\`, or add util-linux to your image"
    printf '%s\n' "$rules" | nft -f - || fail "the firewall rules could not be loaded"
    nft list table inet mudroom >/dev/null 2>&1 || fail "the firewall rules are not in place after loading them"
    [ -n "$u" ] || u=0
    if id -u "$u" >/dev/null 2>&1; then groups=--init-groups; else groups=--clear-groups; fi
    if [ -z "$g" ]; then g=$(id -g "$u" 2>/dev/null) || g=0; fi
    if [ "$sethome" = 1 ]; then
      h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
      [ -n "$h" ] || h=/
      export HOME="$h"
    fi
    exec setpriv --reuid="$u" --regid="$g" $groups --inh-caps=-all --bounding-set=-all --no-new-privs -- "$@" || fail "could not drop root"
    """#

    /// What an image runs when nothing is overridden.
    public struct ImageConfig: Sendable, Equatable {
        public var user: String
        public var entrypoint: [String]
        public var cmd: [String]
        /// True when the image sets HOME itself.
        public var setsHome: Bool

        public init(user: String = "", entrypoint: [String] = [], cmd: [String] = [], setsHome: Bool = false) {
            self.user = user
            self.entrypoint = entrypoint
            self.cmd = cmd
            self.setsHome = setsHome
        }
    }

    /// `name|uid[:group|gid]` split in two. Empty parts stay empty.
    public static func splitUser(_ user: String) -> (user: String, group: String) {
        guard let colon = user.firstIndex(of: ":") else { return (user, "") }
        return (String(user[..<colon]), String(user[user.index(after: colon)...]))
    }

    /// The command line after the image name when the sandbox's entrypoint
    /// is replaced with `/bin/sh`: the script, its arguments, then what the
    /// image would have run (its entrypoint, then `command`, or its own CMD
    /// when `command` is empty).
    public func arguments(image: ImageConfig, command: [String]) -> [String] {
        let (u, g) = Self.splitUser(image.user)
        return ["-c", Self.script, "mudroom-firewall", rules, u, g, image.setsHome ? "0" : "1", "--"]
            + image.entrypoint + (command.isEmpty ? image.cmd : command)
    }

    /// Reads an image's user, entrypoint and CMD from `container image
    /// inspect` JSON. Prefers the linux variant for `architecture`.
    public static func parseImageConfig(_ data: Data, architecture: String = "arm64") -> ImageConfig? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let obj = arr.first,
              let variants = obj["variants"] as? [[String: Any]], !variants.isEmpty else { return nil }
        func platform(_ v: [String: Any]) -> (String?, String?) {
            let p = v["platform"] as? [String: Any]
            return (p?["os"] as? String, p?["architecture"] as? String)
        }
        let variant = variants.first { platform($0) == ("linux", architecture) }
            ?? variants.first { platform($0).0 == "linux" } ?? variants[0]
        guard let outer = variant["config"] as? [String: Any] else { return nil }
        let config = outer["config"] as? [String: Any] ?? [:]
        let env = config["Env"] as? [String] ?? []
        return ImageConfig(user: config["User"] as? String ?? "",
                           entrypoint: config["Entrypoint"] as? [String] ?? [],
                           cmd: config["Cmd"] as? [String] ?? [],
                           setsHome: env.contains { $0.hasPrefix("HOME=") })
    }
}
