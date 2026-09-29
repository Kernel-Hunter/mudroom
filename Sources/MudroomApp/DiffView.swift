import MudroomCore
import SwiftUI

private let codeFont = Font.system(size: 12, design: .monospaced)
private let numberFont = Font.system(size: 11, design: .monospaced)

/// Right pane: header, conflict warning and the diff of the focused file.
struct FileDetailView: View {
    @Bindable var review: ReviewModel
    let entry: FileEntry
    @AppStorage("diffLayout") private var layout: DiffLayout = .unified

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let conflict = entry.conflict {
                Banner(style: .warning,
                       title: FileEntry.conflictTitle(conflict),
                       detail: "Mudroom won't overwrite your version, so this change can't be applied. Copy the parts you want by hand.")
                    .help(conflict)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider()
            }
            content
        }
        .background(Color.diffBackground)
    }

    var header: some View {
        HStack(spacing: 10) {
            KindTag(entry: entry)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 13, weight: .semibold))
                if !entry.directory.isEmpty {
                    Text(entry.directory).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            if entry.isApplied {
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            DiffStat(added: entry.added, removed: entry.removed)
            if case .text = entry.content {
                Picker("Layout", selection: $layout) {
                    ForEach(DiffLayout.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder var content: some View {
        switch entry.content {
        case .text(let hunks, let partial):
            if hunks.isEmpty {
                placeholder("doc", "Empty file", "The file has no content.")
            } else {
                DiffScroll(review: review, entry: entry, hunks: hunks, partial: partial, layout: layout)
            }
        case .binary(let before, let after):
            placeholder("doc.zipper", "Binary file",
                        "\(DiffRenderer.sizeString(before)) → \(DiffRenderer.sizeString(after)). Mudroom applies binary files whole.")
        case .tooLarge(let size):
            placeholder("doc.text.magnifyingglass", "Large file", "\(DiffRenderer.sizeString(size)) is too big to show. It can still be applied whole.")
        case .meta(let title, let detail):
            VStack(spacing: 10) {
                Image(systemName: entry.change.kind == .modeChanged ? "lock.shield" : "arrow.triangle.branch")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text(detail).font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffScroll: View {
    let review: ReviewModel
    let entry: FileEntry
    let hunks: [Hunk]
    let partial: Bool
    let layout: DiffLayout

    var gutterWidth: CGFloat {
        let maxLine = hunks.map { max($0.oldRange.upperBound, $0.newRange.upperBound) }.max() ?? 1
        return CGFloat(max(3, String(maxLine).count)) * 7.3 + 14
    }

    var body: some View {
        ScrollView(.vertical) {
            // Small diffs render eagerly (smoother scrolling, complete
            // snapshots); big ones lazily.
            if hunks.reduce(0, { $0 + $1.lines.count }) < 1500 {
                VStack(alignment: .leading, spacing: 0) { sections }
            } else {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) { sections }
            }
        }
    }

    @ViewBuilder var sections: some View {
                ForEach(hunks) { hunk in
                    let selected = !partial || review.isHunkSelected(entry.path, hunk.id) || entry.appliedHunks.contains(hunk.id)
                    Section {
                        Group {
                            switch layout {
                            case .unified:
                                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                    UnifiedRow(line: line, gutter: gutterWidth)
                                }
                            case .split:
                                ForEach(Array(SplitRow.pair(hunk.lines).enumerated()), id: \.offset) { _, row in
                                    SplitRowView(row: row, gutter: gutterWidth)
                                }
                            }
                        }
                        .opacity(selected || entry.isApplied ? 1 : 0.45)
                        .saturation(selected || entry.isApplied ? 1 : 0.2)
                    } header: {
                        HunkHeaderRow(review: review, entry: entry, hunk: hunk, partial: partial, count: hunks.count)
                    }
                }
                Color.clear.frame(height: 24)
    }
}

private struct HunkHeaderRow: View {
    let review: ReviewModel
    let entry: FileEntry
    let hunk: Hunk
    let partial: Bool
    let count: Int

    var body: some View {
        let applied = entry.appliedHunks.contains(hunk.id) || entry.isApplied
        HStack(spacing: 8) {
            if partial {
                CheckBox(state: applied || review.isHunkSelected(entry.path, hunk.id) ? .on : .off,
                         disabled: applied || !entry.canApply) {
                    review.toggleHunk(entry.path, hunk.id)
                }
                .help("Include this hunk in Apply Selected")
            }
            Text("Hunk \(hunk.id) of \(count)")
                .font(.system(size: 11, weight: .semibold))
            Text(hunk.header)
                .font(numberFont)
                .foregroundStyle(.secondary)
            if applied && partial {
                Text("Applied").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }
            Spacer()
            DiffStat(added: hunk.added, removed: hunk.removed)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.hunkHeader)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

private struct UnifiedRow: View {
    let line: DiffLine
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign)
                .font(codeFont)
                .foregroundStyle(signColor)
                .frame(width: 18)
            Text(line.text.isEmpty ? " " : line.text)
                .font(codeFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
            if line.missingNewline {
                Image(systemName: "return.left")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("No newline at end of file")
                    .padding(.trailing, 8).padding(.top, 3)
            }
        }
        .padding(.vertical, 1)
        .background(fill)
    }

    func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(numberFont)
            .foregroundStyle(.tertiary)
            .frame(width: gutter, alignment: .trailing)
            .padding(.trailing, 6)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(gutterFill)
    }

    var sign: String {
        switch line.kind { case .added: "+"; case .removed: "−"; case .context: "" }
    }
    var signColor: Color {
        switch line.kind { case .added: .addedText; case .removed: .removedText; case .context: .secondary }
    }
    var fill: Color {
        switch line.kind { case .added: .addedFill; case .removed: .removedFill; case .context: .clear }
    }
    var gutterFill: Color {
        switch line.kind { case .added: .addedGutter; case .removed: .removedGutter; case .context: .clear }
    }
}

/// One row of the side-by-side layout: base on the left, work on the right.
struct SplitRow {
    let left: DiffLine?
    let right: DiffLine?

    /// Context lines sit on both sides; a run of removals is paired with the
    /// run of additions that follows it.
    static func pair(_ lines: [DiffLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if l.kind == .context {
                rows.append(SplitRow(left: l, right: l))
                i += 1
                continue
            }
            var removed: [DiffLine] = []
            var added: [DiffLine] = []
            while i < lines.count, lines[i].kind == .removed { removed.append(lines[i]); i += 1 }
            while i < lines.count, lines[i].kind == .added { added.append(lines[i]); i += 1 }
            for k in 0..<max(removed.count, added.count) {
                rows.append(SplitRow(left: k < removed.count ? removed[k] : nil,
                                     right: k < added.count ? added[k] : nil))
            }
        }
        return rows
    }
}

private struct SplitRowView: View {
    let row: SplitRow
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(row.left, number: row.left?.oldNumber)
            Divider()
            cell(row.right, number: row.right?.newNumber)
        }
    }

    func cell(_ line: DiffLine?, number: Int?) -> some View {
        let kind = line?.kind
        let fill: Color = switch kind {
        case .added: .addedFill
        case .removed: .removedFill
        case .context: .clear
        case nil: Color.secondary.opacity(0.06)
        }
        let gutterFill: Color = switch kind {
        case .added: .addedGutter
        case .removed: .removedGutter
        default: .clear
        }
        return HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(numberFont)
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(gutterFill)
            Text(line.map { $0.text.isEmpty ? " " : $0.text } ?? " ")
                .font(codeFont)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill)
    }
}

extension FileEntry {
    static func conflictTitle(_ reason: String) -> String {
        if reason.hasPrefix("project changed since the session started") {
            return "This file changed in your project after the session started"
        }
        if reason.contains("is not a plain directory") { return "A folder on this path is a symlink in your project" }
        return reason
    }
}
