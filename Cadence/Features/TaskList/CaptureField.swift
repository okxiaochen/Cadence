import SwiftUI

/// The new-task field, with completion for `@project` and `#tag`.
///
/// Completion is driven off the text itself rather than a rich-text control:
/// the field stays a plain `TextField`, so the capture grammar keeps working
/// and there is only one representation of what the user typed.
struct CaptureField: View {
    @Environment(AppModel.self) private var model

    var placeholder: String = "New task — try  #tag @project !2 ~45m tomorrow"
    /// Extra context shown as chips, e.g. the list the task will land in.
    var contextChips: [String] = []
    var onSubmit: (ParsedCapture) -> Void

    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    private var parsed: ParsedCapture { CaptureParser.parse(text) }

    private var completion: Completion? {
        Completion.current(in: text, projects: model.projects, tags: model.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field

            if let completion, isFocused, !completion.matches.isEmpty {
                suggestions(completion)
            } else if !chips.isEmpty {
                chipRow
            }
        }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submit)
                .onChange(of: text) { _, _ in highlighted = 0 }
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.tab) { acceptHighlighted() }
                .onKeyPress(.escape) {
                    guard completion != nil else { return .ignored }
                    // Break the token so the popup closes without losing text.
                    text += " "
                    return .handled
                }
        }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard let completion, !completion.matches.isEmpty else { return .ignored }
        let count = completion.matches.count
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    private func acceptHighlighted() -> KeyPress.Result {
        guard let completion, completion.matches.indices.contains(highlighted) else {
            return .ignored
        }
        accept(completion, completion.matches[highlighted])
        return .handled
    }

    // MARK: - Suggestions

    private func suggestions(_ completion: Completion) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(completion.matches.enumerated()), id: \.offset) { index, match in
                    Button {
                        accept(completion, match)
                    } label: {
                        HStack(spacing: 4) {
                            Dot(colorHex: match.colorHex, size: 6)
                            Text(match.name).font(.caption)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            index == highlighted ? AnyShapeStyle(.tint.opacity(0.25))
                                                 : AnyShapeStyle(.quaternary),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }

                if completion.isNewTag {
                    Text("↩ creates #\(completion.query)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: 20)
    }

    /// Replaces the partial token with the chosen name.
    private func accept(_ completion: Completion, _ match: Completion.Match) {
        // A name with spaces would not survive the grammar's word boundary.
        let safe = match.name.replacingOccurrences(of: " ", with: "-")
        text.replaceSubrange(completion.range, with: "\(completion.sigil)\(safe) ")
        highlighted = 0
    }

    // MARK: - Chips

    private var chips: [String] { contextChips + parsed.summaryChips }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }

    private func submit() {
        // Enter completes the token rather than filing a half-typed project.
        if let completion, !completion.matches.isEmpty {
            accept(completion, completion.matches[min(highlighted, completion.matches.count - 1)])
            return
        }
        let result = parsed
        guard !result.isEmpty else { return }
        onSubmit(result)
        text = ""
    }
}

// MARK: - Completion state

/// The half-typed `@…` or `#…` at the caret, and what it could become.
struct Completion {
    struct Match: Hashable {
        var name: String
        var colorHex: String
    }

    var sigil: Character
    var query: String
    var range: Range<String.Index>
    var matches: [Match]
    var isNewTag: Bool

    /// Only the token being typed at the very end counts — completing something
    /// mid-sentence would move the caret out from under the user.
    static func current(in text: String, projects: [Project], tags: [Tag]) -> Completion? {
        guard let last = text.last, !last.isWhitespace else { return nil }

        // Walk back to the sigil, giving up at whitespace.
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character.isWhitespace { return nil }
            if character == "@" || character == "#" {
                // Must start a word, so an email address is not a project.
                if previous > text.startIndex,
                   !text[text.index(before: previous)].isWhitespace { return nil }

                let query = String(text[text.index(after: previous)...])
                return make(
                    sigil: character,
                    query: query,
                    range: previous..<text.endIndex,
                    projects: projects,
                    tags: tags
                )
            }
            index = previous
        }
        return nil
    }

    private static func make(
        sigil: Character,
        query: String,
        range: Range<String.Index>,
        projects: [Project],
        tags: [Tag]
    ) -> Completion {
        let candidates: [Match] = sigil == "@"
            ? projects.map { Match(name: $0.name, colorHex: $0.colorHex) }
            : tags.map { Match(name: $0.name, colorHex: $0.colorHex) }

        let matches = query.isEmpty
            ? Array(candidates.prefix(6))
            : Array(
                candidates
                    .filter { $0.name.localizedCaseInsensitiveContains(query) }
                    // Prefixes first: typing "ca" should offer "Cadence"
                    // before "Podcast".
                    .sorted { lhs, rhs in
                        let leftPrefix = lhs.name.lowercased().hasPrefix(query.lowercased())
                        let rightPrefix = rhs.name.lowercased().hasPrefix(query.lowercased())
                        if leftPrefix != rightPrefix { return leftPrefix }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    .prefix(6)
            )

        return Completion(
            sigil: sigil,
            query: query,
            range: range,
            matches: matches,
            // Tags are created on demand; projects are not.
            isNewTag: sigil == "#" && !query.isEmpty
                && !candidates.contains { $0.name.lowercased() == query.lowercased() }
        )
    }
}
