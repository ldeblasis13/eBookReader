import Foundation
import GRDB
import os

/// Heuristic recipe detector that scores text chunks for recipe-like content.
/// Runs in background when books are added to cookbook collections.
actor RecipeDetector {
    private let dbPool: DatabasePool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "RecipeDetector"
    )

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Scans all text chunks for a book and stores recipe hint scores.
    func detectRecipes(forBook bookId: UUID) async {
        let chunks: [TextChunk]
        do {
            let repo = TextChunkRepository(dbPool: dbPool)
            chunks = try await repo.fetchChunks(forBook: bookId)
        } catch {
            logger.error("Failed to fetch chunks for recipe detection: \(error)")
            return
        }

        guard !chunks.isEmpty else { return }

        var hints: [(chunkId: Int64, score: Double, title: String?)] = []

        for chunk in chunks {
            guard let chunkId = chunk.id else { continue }
            let score = scoreRecipeLikelihood(chunk.text)
            if score > 0.3 {
                let title = extractPossibleTitle(from: chunk.text)
                hints.append((chunkId: chunkId, score: score, title: title))
            }
        }

        guard !hints.isEmpty else {
            logger.info("No recipe hints found for book \(bookId)")
            return
        }

        // Store hints
        do {
            try await dbPool.write { db in
                for hint in hints {
                    try db.execute(
                        sql: """
                        INSERT OR REPLACE INTO recipeHint (chunkId, score, detectedTitle, dateDetected)
                        VALUES (?, ?, ?, ?)
                        """,
                        arguments: [hint.chunkId, hint.score, hint.title, Date()]
                    )
                }
            }
            logger.info("Stored \(hints.count) recipe hints for book \(bookId)")
        } catch {
            logger.error("Failed to store recipe hints: \(error)")
        }
    }

    // MARK: - Scoring

    /// Scores a text chunk from 0 (not a recipe) to 1 (definitely a recipe).
    private func scoreRecipeLikelihood(_ text: String) -> Double {
        let lower = text.lowercased()
        var score = 0.0

        // Ingredient quantities (strong signal)
        let quantityPatterns = [
            #"\d+\s*(cup|cups|tbsp|tsp|tablespoon|teaspoon|oz|ounce|pound|lb|kg|gram|ml|liter)"#,
            #"\d+/\d+\s*(cup|tbsp|tsp)"#,
            #"\d+\s*(clove|bunch|sprig|pinch|dash|handful)"#,
        ]
        for pattern in quantityPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
                score += Double(min(matches, 5)) * 0.08
            }
        }

        // Cooking instruction keywords (moderate signal)
        let instructionWords = ["preheat", "bake", "roast", "simmer", "boil", "sauté", "saute",
                                "fry", "grill", "broil", "whisk", "stir", "fold", "knead",
                                "chop", "dice", "mince", "slice", "drain", "season",
                                "marinate", "glaze", "reduce", "deglaze", "blanch"]
        let instructionCount = instructionWords.filter { lower.contains($0) }.count
        score += Double(min(instructionCount, 6)) * 0.06

        // Time markers (moderate signal)
        let timePattern = #"\d+\s*(minute|hour|min|hr)s?"#
        if let regex = try? NSRegularExpression(pattern: timePattern, options: .caseInsensitive) {
            let matches = regex.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            score += Double(min(matches, 3)) * 0.05
        }

        // Temperature (strong signal)
        let tempPattern = #"\d+\s*°?\s*(F|C|fahrenheit|celsius|degrees)"#
        if let regex = try? NSRegularExpression(pattern: tempPattern, options: .caseInsensitive) {
            let matches = regex.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            score += Double(min(matches, 2)) * 0.1
        }

        // Section headers (moderate signal)
        let headers = ["ingredients", "instructions", "directions", "method", "preparation",
                       "serves", "servings", "yield", "makes"]
        let headerCount = headers.filter { lower.contains($0) }.count
        score += Double(min(headerCount, 3)) * 0.08

        return min(score, 1.0)
    }

    /// Tries to extract a recipe title from the beginning of a chunk.
    private func extractPossibleTitle(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // First non-empty line that's short enough to be a title
        for line in lines.prefix(3) {
            let words = line.split(separator: " ").count
            if words >= 2 && words <= 12 && !line.contains(":") {
                return line
            }
        }

        return nil
    }
}
