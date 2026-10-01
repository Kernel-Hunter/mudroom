import MudroomCore
import SwiftUI

extension SessionPhase {
    var color: Color {
        switch self {
        case .notStarted: .secondary
        case .running: .blue
        case .readyToReview: .orange
        case .applied: .green
        case .discarded: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .notStarted: "circle.dashed"
        case .running: "circle.dotted.circle"
        case .readyToReview: "eye"
        case .applied: "checkmark"
        case .discarded: "xmark"
        }
    }
}

struct StatusBadge: View {
    let phase: SessionPhase
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if phase == .running {
                PulsingDot(color: phase.color)
            } else {
                Image(systemName: phase.symbol).font(.system(size: 8, weight: .bold))
            }
            if !compact { Text(phase.title) }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(phase == .discarded || phase == .notStarted ? Color.secondary : phase.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(phase.color.opacity(phase == .discarded ? 0.10 : 0.15)))
        .fixedSize()
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Rounded tile with an SF Symbol standing in for the agent.
struct AgentIcon: View {
    let session: Session
    var size: CGFloat = 26

    var style: (symbol: String, color: Color) {
        let label = session.agentLabel.lowercased()
        let cmd = session.command.first?.lowercased() ?? ""
        if label.contains("claude") || cmd == "claude" { return ("sparkle", .orange) }
        if label.contains("codex") || cmd == "codex" { return ("chevron.left.forwardslash.chevron.right", .teal) }
        if label.contains("gemini") || cmd == "gemini" { return ("diamond", .indigo) }
        return ("terminal", .gray)
    }

    var body: some View {
        let s = style
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(s.color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: s.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

struct CheckBox: View {
    let state: CheckState
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state == .off || disabled ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(state == .on ? "Selected" : state == .mixed ? "Partly selected" : "Not selected")
    }

    var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}

struct DiffStat: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 5) {
            if added > 0 { Text("+\(added)").foregroundStyle(Color.addedText) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Color.removedText) }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
    }
}

extension ChangeGroup {
    var color: Color {
        switch self {
        case .added: .green
        case .modified: .blue
        case .deleted: .red
        case .other: .purple
        }
    }

    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .other: "P"
        }
    }
}

extension FileEntry {
    var kindLetter: String {
        switch change.kind {
        case .symlinkChanged: "L"
        case .typeChanged: "T"
        case .unreadable: "?"
        default: group.letter
        }
    }
}

/// Git-client style status letter in a small tinted square.
struct KindTag: View {
    let entry: FileEntry

    var body: some View {
        Text(entry.kindLetter)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(entry.group.color)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(entry.group.color.opacity(0.16)))
    }
}

extension Color {
    static let addedText = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(red: 0.40, green: 0.85, blue: 0.50, alpha: 1)
            : NSColor(red: 0.10, green: 0.55, blue: 0.22, alpha: 1)
    })
    static let removedText = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(red: 1.0, green: 0.48, blue: 0.45, alpha: 1)
            : NSColor(red: 0.78, green: 0.16, blue: 0.16, alpha: 1)
    })
    static let addedFill = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(red: 0.20, green: 0.65, blue: 0.35, alpha: 0.13)
            : NSColor(red: 0.20, green: 0.70, blue: 0.35, alpha: 0.13)
    })
    static let removedFill = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(red: 0.90, green: 0.30, blue: 0.30, alpha: 0.13)
            : NSColor(red: 0.90, green: 0.25, blue: 0.25, alpha: 0.11)
    })
    static let addedGutter = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(red: 0.20, green: 0.65, blue: 0.35, alpha: 0.22)
            : NSColor(red: 0.20, green: 0.70, blue: 0.35, alpha: 0.22)
    })
    static let removedGutter = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(red: 0.90, green: 0.30, blue: 0.30, alpha: 0.22)
            : NSColor(red: 0.90, green: 0.25, blue: 0.25, alpha: 0.19)
    })
    static let hunkHeader = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(white: 1, alpha: 0.06) : NSColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1)
    })
    static let diffBackground = Color(nsColor: .textBackgroundColor)
}

struct Banner: View {
    enum Style { case warning, success, info, running }
    let style: Style
    let title: String
    var detail: String?
    var actions: AnyView?

    var color: Color {
        switch style {
        case .warning: .orange
        case .success: .green
        case .info: .blue
        case .running: .blue
        }
    }

    var symbol: String {
        switch style {
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .running: "hourglass"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            Spacer(minLength: 8)
            if let actions { actions }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color.opacity(0.25)))
        )
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        if abs(timeIntervalSinceNow) < 45 { return "just now" }
        return f.localizedString(for: self, relativeTo: Date())
    }
}
