import MudroomCore
import SwiftUI

extension SessionNetwork {
    var label: String {
        switch (mode, enforcement) {
        case (.locked, .enforced): "Locked"
        case (.locked, _): "Locked (advisory)"
        case (.open, _): "Open"
        case (.offline, _): "Offline"
        }
    }

    var symbol: String {
        switch mode {
        case .locked: enforcement == .enforced ? "lock.shield.fill" : "lock.shield"
        case .open: "globe"
        case .offline: "wifi.slash"
        }
    }

    var color: Color {
        switch (mode, enforcement) {
        case (.locked, .enforced), (.offline, _): .green
        case (.locked, _): .orange
        case (.open, _): .orange
        }
    }

    var explanation: String {
        switch (mode, enforcement) {
        case (.locked, .enforced):
            "The VM ran on a host-only network with no route to the internet. Its only way out was Mudroom's proxy, which let through the hosts on the allowlist."
        case (.locked, _):
            "Proxy settings pointed the agent at the allowlist, but the VM had a normal route out: a program that ignores proxy settings could connect directly. Your container runtime couldn't create a host-only network."
        case (.open, _):
            "The VM had normal internet access. Nothing was filtered or logged."
        case (.offline, _):
            "The VM had no internet access at all."
        }
    }
}

/// Small capsule: "Locked", "Open", ...
struct NetworkBadge: View {
    let network: SessionNetwork
    var compact = false

    var body: some View {
        Label(network.label, systemImage: network.symbol)
            .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(network.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(network.color.opacity(0.14)))
            .fixedSize()
            .help(network.explanation)
    }
}

/// Middle column, Network tab: one row per host the VM tried to reach.
struct NetworkListColumn: View {
    @Bindable var review: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            if let net = review.handle.session.network {
                if net.mode == .open || net.enforcement == .advisory {
                    Banner(style: .warning, title: net.mode == .open ? "Network was open" : "Allowlist was advisory",
                           detail: net.explanation)
                        .padding(10)
                }
            }
            if review.networkRows.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: review.handle.session.network?.symbol ?? "network")
                } description: {
                    Text(emptyDetail)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let blocked = review.networkRows.filter { !$0.allowed }
                        let allowed = review.networkRows.filter(\.allowed)
                        if !blocked.isEmpty { sectionHeader("Blocked", blocked.count) }
                        ForEach(blocked) { row(for: $0) }
                        if !allowed.isEmpty { sectionHeader("Allowed", allowed.count) }
                        ForEach(allowed) { row(for: $0) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .safeAreaInset(edge: .bottom) { totals }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func sectionHeader(_ title: String, _ n: Int) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text("\(n)").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    func row(for r: NetworkLog.HostSummary) -> some View {
        let selected = review.focusedHostRow == r.id
        return HostRow(review: review, row: r)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : r.allowed ? Color.clear : Color.red.opacity(0.07)))
            .contentShape(Rectangle())
            .onTapGesture { review.focusedHostRow = selected ? nil : r.id }
    }

    var emptyTitle: String {
        switch review.handle.session.network?.mode {
        case nil: review.handle.session.status == .created ? "Not started" : "No network record"
        case .open?: "Not logged"
        case .offline?: "Offline"
        case .locked?: "No connections"
        }
    }

    var emptyDetail: String {
        switch review.handle.session.network?.mode {
        case nil: "Connections show up here once the agent runs."
        case .open?: "Open sessions go straight to the internet, so Mudroom can't see where."
        case .offline?: "The VM had no network."
        case .locked?: review.isRunning ? "The agent hasn't connected anywhere yet." : "The agent didn't connect anywhere."
        }
    }

    var totals: some View {
        let e = review.networkEntries
        return HStack(spacing: 8) {
            Text("\(e.count) connections")
            Spacer()
            Text("↑ \(NetworkLog.byteString(e.reduce(0) { $0 + $1.bytesOut }))  ↓ \(NetworkLog.byteString(e.reduce(0) { $0 + $1.bytesIn }))")
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct HostRow: View {
    let review: ReviewModel
    let row: NetworkLog.HostSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.allowed ? "checkmark.shield.fill" : "xmark.shield.fill")
                .foregroundStyle(row.allowed ? Color.green : Color.red)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 0) {
                Text(row.host.isEmpty ? "(no host)" : row.host).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !row.allowed, !row.host.isEmpty {
                if review.isAllowedNow(row.host) {
                    Text("Allowed now").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                        .help("On the project's allowlist for the next session")
                } else {
                    Button("Allow") { review.allowForProject(row.host) }
                        .controlSize(.small)
                        .help("Allow \(row.host) for this project")
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if row.host.isEmpty {
                EmptyView()
            } else if !review.isAllowedNow(row.host) {
                Button("Allow \(row.host) for This Project") { review.allowForProject(row.host) }
            } else if review.projectConfig?.allowedHosts.contains(where: { $0.value == row.host }) == true {
                Button("Remove \(row.host) from Project Allowlist") { review.removeFromProject(row.host) }
            }
            Button("Copy Host") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.host, forType: .string)
            }
        }
    }

    var detail: String {
        let port = row.port == 443 ? "" : ":\(row.port) · "
        let times = row.count == 1 ? "1 connection" : "\(row.count) connections"
        if row.allowed { return "\(port)\(times) · ↓ \(NetworkLog.byteString(row.bytesIn))" }
        return "\(port)\(times) blocked"
    }
}

/// Right pane, Network tab: how the VM was connected, and the connections
/// for the selected host (or all of them).
struct NetworkDetailView: View {
    let review: ReviewModel

    var entries: [NetworkLogEntry] {
        let all = review.networkEntries.sorted { $0.time > $1.time }
        guard let row = review.focusedHost else { return all }
        return all.filter { $0.host == row.host && $0.port == row.port && $0.allowed == row.allowed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let row = review.focusedHost, !row.allowed {
                blockedCallout(row)
                Divider()
            }
            if entries.isEmpty {
                allowlist
            } else {
                ConnectionTable(entries: entries)
            }
        }
        .background(Color.diffBackground)
    }


    var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if let net = review.handle.session.network {
                Image(systemName: net.symbol).font(.system(size: 20)).foregroundStyle(net.color).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Network: \(net.label)").font(.system(size: 13, weight: .semibold))
                        if net.mode == .locked {
                            Text(net.enforcement.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(net.explanation).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } else {
                Image(systemName: "network").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26)
                Text("This session has no network record.").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
    }

    func blockedCallout(_ row: NetworkLog.HostSummary) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.host) was blocked \(row.count == 1 ? "once" : "\(row.count) times")")
                    .font(.system(size: 12, weight: .semibold))
                Text("It isn't on this project's allowlist. Allowing it takes effect from the next session.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if review.isAllowedNow(row.host) {
                Label("Allowed for this project", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.green)
            } else {
                Button("Allow for This Project") { review.allowForProject(row.host) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.06))
    }

    var allowlist: some View {
        let hosts = review.handle.session.network?.allowlist ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("Allowlist for this session").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            if hosts.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(hosts, id: \.self) { h in
                    Label(h, systemImage: "checkmark.shield").font(.system(size: 12, design: .monospaced))
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Connection log as plain rows (SwiftUI's Table doesn't draw into the
/// offscreen snapshots the docs use, and this is short anyway).
struct ConnectionTable: View {
    let entries: [NetworkLogEntry]

    var body: some View {
        VStack(spacing: 0) {
            row(time: "Time", icon: nil, host: "Host", kind: "Kind", sent: "Sent", received: "Received", open: "Open", note: "Note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .background(.bar)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                        row(time: e.time.formatted(date: .omitted, time: .standard),
                            icon: e.allowed ? (e.reason == nil ? ("checkmark", Color.green) : ("exclamationmark.triangle", Color.orange)) : ("xmark", Color.red),
                            host: NetworkLog.endpoint(e.host, e.port), kind: e.method == "CONNECT" ? "HTTPS" : "HTTP \(e.method)",
                            sent: NetworkLog.byteString(e.bytesOut), received: NetworkLog.byteString(e.bytesIn),
                            open: Self.duration(e.durationMs), note: e.reason ?? "")
                            .font(.system(size: 11.5))
                            .padding(.vertical, 5)
                            .background(i % 2 == 1 ? Color.secondary.opacity(0.05) : Color.clear)
                            .background(e.allowed ? Color.clear : Color.red.opacity(0.05))
                    }
                }
            }
        }
    }

    func row(time: String, icon: (String, Color)?, host: String, kind: String, sent: String, received: String,
             open: String, note: String) -> some View {
        HStack(spacing: 10) {
            Text(time).monospacedDigit().frame(width: 72, alignment: .leading)
            Group {
                if let icon { Image(systemName: icon.0).foregroundStyle(icon.1) } else { Text("") }
            }
            .frame(width: 14)
            Text(host).lineLimit(1).truncationMode(.middle).frame(minWidth: 150, maxWidth: 260, alignment: .leading)
            Text(kind).lineLimit(1).frame(width: 84, alignment: .leading)
            Text(sent).monospacedDigit().frame(width: 60, alignment: .trailing)
            Text(received).monospacedDigit().frame(width: 64, alignment: .trailing)
            Text(open).monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(note).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
    }

    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : ms < 60_000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms / 60_000) min"
    }
}

/// "Changes since: session start ... snapshot 3 (10:15)". Picks the compare
/// point for the file list; anything but the start is read-only.
struct TimelineBar: View {
    @Bindable var review: ReviewModel

    var body: some View {
        let snaps = review.timeline
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .foregroundStyle(.secondary)
                Text("Since").foregroundStyle(.secondary)
                Text(label).fontWeight(.semibold).monospacedDigit().lineLimit(1)
                Spacer()
                if review.isTimelineView {
                    Button("Reset") { review.compareFrom = 0 }
                        .help("Show all changes since the session started")
                        .buttonStyle(.borderless)
                }
            }
            Slider(value: Binding(
                get: { Double(index) },
                set: { v in
                    let i = Int(v.rounded())
                    review.compareFrom = i == 0 ? 0 : snaps[min(i, snaps.count) - 1].number
                }), in: 0...Double(max(snaps.count, 1)), step: 1) {
                EmptyView()
            } minimumValueLabel: {
                Text("start").font(.system(size: 10)).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("#\(snaps.last?.number ?? 0)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .controlSize(.small)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    var index: Int {
        guard review.compareFrom != 0 else { return 0 }
        return (review.timeline.firstIndex { $0.number == review.compareFrom } ?? -1) + 1
    }

    var label: String {
        guard let s = review.compareSnapshot else { return "session start" }
        return "snapshot \(s.number) · \(s.date.formatted(date: .omitted, time: .shortened))"
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
