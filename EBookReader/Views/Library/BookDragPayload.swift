import Foundation

/// String-encoded drag payload for moving books between the library and
/// collection sidebar items. Lives in a single helper so the format stays
/// in lockstep across BookGridItem, BookListRow, the Table rows in
/// LibraryView, and CollectionSidebarItem's drop handler.
///
/// Two formats are supported on the wire:
///   - Plain UUID string ("E4A2…") → one book, the historical encoding
///     (kept for backward compatibility with anything else that might
///     accept book drags).
///   - "BOOKS:<uuid>,<uuid>,…" → an arbitrary multi-selection. Used when
///     the dragged book is part of a selection of two or more books, so
///     all of them ride the same drop.
///
/// SwiftUI's `.dropDestination` collects every Transferable in a single
/// drag operation into an array; for multi-selection we instead pack them
/// into a single payload because a `.draggable` modifier on a row only
/// emits ONE Transferable per drag (the SwiftUI drag system doesn't
/// auto-broadcast across selected siblings).
enum BookDragPayload {
    private static let multiPrefix = "BOOKS:"

    /// Encode the drag payload for a row. If the row's book is part of a
    /// multi-selection, encode the whole selection; otherwise encode just
    /// this one book in the historical single-UUID format.
    static func encode(book bookId: UUID, selection: Set<UUID>) -> String {
        if selection.contains(bookId) && selection.count > 1 {
            // Stable order keeps logs readable and tests deterministic.
            let csv = selection.map(\.uuidString).sorted().joined(separator: ",")
            return multiPrefix + csv
        }
        return bookId.uuidString
    }

    /// Decode an array of dropped strings into a flat list of book IDs.
    /// Handles a mix of single-UUID strings and multi-payload strings in
    /// the same drop event.
    static func decode(items: [String]) -> [UUID] {
        var ids: [UUID] = []
        ids.reserveCapacity(items.count)
        for item in items {
            if item.hasPrefix(multiPrefix) {
                let csv = item.dropFirst(multiPrefix.count)
                for token in csv.split(separator: ",") {
                    if let uuid = UUID(uuidString: String(token)) { ids.append(uuid) }
                }
            } else if let uuid = UUID(uuidString: item) {
                ids.append(uuid)
            }
        }
        // De-dup while preserving first occurrence — useful when both a
        // multi payload and a stray single-UUID land in the same drop.
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
