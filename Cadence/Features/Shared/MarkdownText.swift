import SwiftUI

/// Markdown as the assistant actually writes it.
///
/// `AttributedString(markdown:)` alone handles the inline half — bold, italic,
/// code, links — and nothing else, because SwiftUI's `Text` has no notion of a
/// block. Everything structural comes through as literal characters, so a reply
/// full of `**headings**` and `- bullets` reads as punctuation.
///
/// This walks the lines instead: each one is classified, styled as a block, and
/// only then handed to the inline parser. Deliberately a small subset — the
/// things a paragraph of explanation actually uses. Anything else falls through
/// as a plain line, which is the right failure for prose.
struct MarkdownText: View {
    var source: String
    var font: Font = .caption

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(Block.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .blank:
                    // A gap rather than an empty line: an empty `Text` still
                    // takes a full line's height and the spacing compounds.
                    Color.clear.frame(height: 3)

                case .heading(let text, let level):
                    inline(text)
                        .font((level <= 2 ? font.weight(.semibold) : font.weight(.medium)))
                        .padding(.top, 2)

                case .bullet(let text, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("•").font(font).foregroundStyle(.secondary)
                        inline(text).font(font)
                    }
                    .padding(.leading, CGFloat(depth) * 12)

                case .numbered(let text, let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(marker)
                            .font(font.monospacedDigit())
                            .foregroundStyle(.secondary)
                        inline(text).font(font)
                    }

                case .quote(let text):
                    inline(text)
                        .font(font)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.quaternary).frame(width: 2)
                        }

                case .plain(let text):
                    inline(text).font(font)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        Text(
            (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text)
        )
    }
}

extension MarkdownText {
    /// One line, classified. Line-based rather than a real parser: replies are
    /// prose, and the cost of getting a nested structure slightly wrong is far
    /// lower than the cost of a parser that throws away text it did not expect.
    enum Block: Equatable {
        case blank
        case heading(String, level: Int)
        case bullet(String, depth: Int)
        case numbered(String, marker: String)
        case quote(String)
        case plain(String)

        static func parse(_ source: String) -> [Block] {
            source.components(separatedBy: .newlines).map(classify)
        }

        static func classify(_ raw: String) -> Block {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return .blank }

            // A space after the hashes is what separates a heading from a
            // tag, and this app writes tags as `#backend` everywhere.
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(hashes)
                if rest.first == " " {
                    let text = String(rest).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { return .heading(text, level: hashes) }
                }
            }

            // An em dash opens a line often enough in prose — like this one —
            // that only `-`, `*` and `+` count as bullets.
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)), depth: indent >= 2 ? 1 : 0)
            }

            if line.hasPrefix("> ") {
                return .quote(String(line.dropFirst(2)))
            }

            if let dot = line.firstIndex(of: "."),
               line.distance(from: line.startIndex, to: dot) <= 2,
               line[line.startIndex..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex,
               line[line.index(after: dot)] == " " {
                return .numbered(
                    String(line[line.index(dot, offsetBy: 2)...]),
                    marker: String(line[line.startIndex...dot])
                )
            }

            return .plain(line)
        }
    }
}
