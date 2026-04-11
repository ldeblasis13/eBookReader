import Foundation
import PDFKit

/// Shared state for in-book search, observable by the find bar and results panel.
@Observable
@MainActor
final class InBookSearchState {
    var query: String = ""
    var currentMatchIndex: Int = 0
    var totalMatches: Int = 0
    var results: [SearchMatch] = []
    var isSearching: Bool = false

    struct SearchMatch: Identifiable {
        let id = UUID()
        let pageLabel: String   // "Page 5" or "Chapter 2"
        let context: String     // surrounding text snippet
        let index: Int          // match index for navigation
        let chapterIndex: Int?  // ePub spine index (nil for PDF / single-chapter)

        init(pageLabel: String, context: String, index: Int, chapterIndex: Int? = nil) {
            self.pageLabel = pageLabel
            self.context = context
            self.index = index
            self.chapterIndex = chapterIndex
        }
    }

    func clear() {
        query = ""
        currentMatchIndex = 0
        totalMatches = 0
        results = []
        isSearching = false
    }

    func goToNext() {
        guard totalMatches > 0 else { return }
        currentMatchIndex = (currentMatchIndex + 1) % totalMatches
        let chapter = results.indices.contains(currentMatchIndex) ? results[currentMatchIndex].chapterIndex : nil
        NotificationCenter.default.post(
            name: .ebookReaderFindNavigate,
            object: FindNavigationRequest(index: currentMatchIndex, direction: .next, chapterIndex: chapter)
        )
    }

    func goToPrevious() {
        guard totalMatches > 0 else { return }
        currentMatchIndex = (currentMatchIndex - 1 + totalMatches) % totalMatches
        let chapter = results.indices.contains(currentMatchIndex) ? results[currentMatchIndex].chapterIndex : nil
        NotificationCenter.default.post(
            name: .ebookReaderFindNavigate,
            object: FindNavigationRequest(index: currentMatchIndex, direction: .previous, chapterIndex: chapter)
        )
    }

    func goToMatch(at index: Int) {
        guard index >= 0, index < totalMatches else { return }
        currentMatchIndex = index
        let chapter = results.indices.contains(index) ? results[index].chapterIndex : nil
        NotificationCenter.default.post(
            name: .ebookReaderFindNavigate,
            object: FindNavigationRequest(index: index, direction: .next, chapterIndex: chapter)
        )
    }

    func performSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            totalMatches = 0
            currentMatchIndex = 0
            results = []
            return
        }
        isSearching = true
        NotificationCenter.default.post(
            name: .ebookReaderFindInBook,
            object: q
        )
    }
}

/// Direction for find navigation
enum FindDirection {
    case next, previous
}

/// Request to navigate to a specific match
class FindNavigationRequest: @unchecked Sendable {
    let index: Int
    let direction: FindDirection
    let chapterIndex: Int?
    init(index: Int, direction: FindDirection, chapterIndex: Int? = nil) {
        self.index = index
        self.direction = direction
        self.chapterIndex = chapterIndex
    }
}

extension Notification.Name {
    static let ebookReaderFindNavigate = Notification.Name("ebookReaderFindNavigate")
}
