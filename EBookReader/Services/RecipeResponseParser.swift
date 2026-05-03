import Foundation
import os

/// Parses the strict cookbook-mode LLM output into structured ParsedRecipe
/// records. The cookbook system prompt requires the model to emit:
///
///   Recipe N: <title>
///   From: <Book Title>
///   Excerpt: [excerpt N]
///   Ingredients (visible in excerpt):
///   - <ingredient 1>
///   - <ingredient 2>
///   Instructions (visible in excerpt):
///   <paragraph or numbered steps>
///   Notes: <optional>
///   Completeness: <complete recipe | partial recipe>
///
/// The parser is forgiving: small variations in spacing, casing, and missing
/// optional fields all work. Each recipe is tied back to the source chunk via
/// the "Excerpt: [excerpt N]" marker — that index maps to the original
/// HybridSearchResult so we can carry position + author through to the card.
enum RecipeResponseParser {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "RecipeResponseParser"
    )

    /// Source-chunk metadata aligned by 1-based excerpt index.
    /// excerptIndex must match the [excerpt N] number used in the prompt.
    struct ExcerptSource: Sendable {
        let excerptIndex: Int
        let bookId: UUID
        let bookTitle: String
        let author: String?
        let position: ContentPosition?
    }

    /// Parses the raw LLM response into structured recipes. Sources are
    /// looked up by excerpt number so the card can carry the right book
    /// position even when the model drifts slightly on the title spelling.
    /// Returns an empty array if no recipe blocks could be extracted (in
    /// which case ChatPanelView falls back to showing the raw text).
    static func parse(_ response: String, sources: [ExcerptSource]) -> [ChatMessage.ParsedRecipe] {
        let sourceByIndex = Dictionary(uniqueKeysWithValues: sources.map { ($0.excerptIndex, $0) })
        let blocks = splitIntoRecipeBlocks(response)
        guard !blocks.isEmpty else { return [] }

        var results: [ChatMessage.ParsedRecipe] = []
        results.reserveCapacity(blocks.count)
        for block in blocks {
            guard let recipe = parseSingleBlock(block, sourceByIndex: sourceByIndex) else { continue }
            results.append(recipe)
        }
        logger.info("Parsed \(results.count) recipe(s) from \(blocks.count) candidate block(s)")
        return results
    }

    // MARK: - Block segmentation

    /// Splits the full response into per-recipe blocks. We anchor on the
    /// "Recipe N:" header (case-insensitive). Anything before the first
    /// header (e.g. a one-line intro) is discarded.
    private static func splitIntoRecipeBlocks(_ text: String) -> [String] {
        // Find every line that starts with "Recipe <number>:" (with optional
        // leading whitespace). Use ranges so we can slice the text between
        // headers.
        let pattern = #"(?im)^\s*recipe\s+\d+\s*[:.\-—]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return [] }

        var blocks: [String] = []
        for (i, match) in matches.enumerated() {
            let start = match.range.location
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : (text as NSString).length
            let nsRange = NSRange(location: start, length: end - start)
            guard let swiftRange = Range(nsRange, in: text) else { continue }
            blocks.append(String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return blocks
    }

    // MARK: - Single-block parsing

    private static func parseSingleBlock(
        _ block: String,
        sourceByIndex: [Int: ExcerptSource]
    ) -> ChatMessage.ParsedRecipe? {
        let lines = block.components(separatedBy: "\n").map { $0 }
        guard !lines.isEmpty else { return nil }

        // ── Title (first line after "Recipe N:")
        let titleLine = lines[0]
        let title = extractAfterColon(titleLine)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        // Walk subsequent lines, tagging sections as we go.
        var sectionFrom: String?
        var sectionExcerptIndex: Int?
        var preambleLines: [String] = []
        var ingredientLines: [String] = []
        var instructionLines: [String] = []
        var notesLines: [String] = []
        var completeness: String?

        // Section labels we recognize. The parser is whitespace- and
        // punctuation-tolerant ("Ingredients:", "INGREDIENTS", "Ingredients (visible in excerpt):").
        enum Section { case preamble, ingredients, instructions, notes }
        var currentSection: Section = .preamble

        for raw in lines.dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // Blank line — preserve in instructions (paragraph break),
                // ignore elsewhere.
                if currentSection == .instructions {
                    instructionLines.append("")
                }
                continue
            }
            let lower = line.lowercased()

            // Header lines that switch section (or set metadata).
            if lower.hasPrefix("from:") {
                sectionFrom = extractAfterColon(line)?.trimmingCharacters(in: .whitespaces)
                continue
            }
            if lower.hasPrefix("excerpt") && lower.contains(":") {
                if let n = parseExcerptNumber(line) { sectionExcerptIndex = n }
                continue
            }
            if lower.hasPrefix("ingredient") {
                currentSection = .ingredients
                continue
            }
            if lower.hasPrefix("instruction") || lower.hasPrefix("method") || lower.hasPrefix("direction") || lower.hasPrefix("steps") {
                currentSection = .instructions
                continue
            }
            if lower.hasPrefix("notes") {
                currentSection = .notes
                if let val = extractAfterColon(line), !val.isEmpty {
                    notesLines.append(val)
                }
                continue
            }
            if lower.hasPrefix("completeness") {
                completeness = extractAfterColon(line)?.trimmingCharacters(in: .whitespaces)
                continue
            }

            // Body content.
            switch currentSection {
            case .preamble:
                preambleLines.append(line)
            case .ingredients:
                ingredientLines.append(stripBullet(line))
            case .instructions:
                instructionLines.append(line)
            case .notes:
                notesLines.append(line)
            }
        }

        // Look up source metadata by excerpt number. Fall back to matching
        // the "From:" book title against any source if the number is missing.
        let source: ExcerptSource? = {
            if let idx = sectionExcerptIndex, let s = sourceByIndex[idx] { return s }
            if let from = sectionFrom {
                return sourceByIndex.values.first { $0.bookTitle.caseInsensitiveCompare(from) == .orderedSame }
            }
            return nil
        }()

        // A recipe needs a real source — without it we can't produce a card
        // that opens a real book, and without ingredients OR instructions
        // there's nothing to render.
        guard let source else { return nil }
        let preamble = preambleLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let ingredients = ingredientLines.filter { !$0.isEmpty }
        let instructions = instructionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ingredients.isEmpty || !instructions.isEmpty else { return nil }

        return ChatMessage.ParsedRecipe(
            title: title,
            preamble: preamble.isEmpty ? nil : preamble,
            ingredients: ingredients,
            instructions: instructions,
            bookTitle: source.bookTitle,
            bookId: source.bookId,
            author: source.author,
            position: source.position,
            notes: notesLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            completeness: completeness?.nilIfEmpty
        )
    }

    // MARK: - Small helpers

    private static func extractAfterColon(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = line[line.index(after: colon)...]
        return String(after).trimmingCharacters(in: .whitespaces)
    }

    private static func stripBullet(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        // Remove leading bullet characters: "-", "•", "*", "·", numeric "1.", "1)".
        let leadingBullets: Set<Character> = ["-", "•", "*", "·", "—", "–"]
        if let first = s.first, leadingBullets.contains(first) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            // "1." or "1)" style numbered list.
            if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }),
               s.distance(from: s.startIndex, to: dot) <= 3,
               s[s.startIndex..<dot].allSatisfy({ $0.isNumber }) {
                s = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    private static func parseExcerptNumber(_ line: String) -> Int? {
        // Matches "[excerpt N]" or "excerpt N" or "excerpt #N".
        let pattern = #"(?i)excerpt\s*#?\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 2,
              let numRange = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[numRange])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
