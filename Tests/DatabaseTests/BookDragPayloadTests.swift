import XCTest
@testable import EBookReader

/// Guards the wire format used to drag books from the library into a
/// sidebar collection. Two formats coexist:
///   - plain UUID string ("E4A2…") for the historical single-book drag
///   - "BOOKS:<uuid>,<uuid>,…" for multi-selection drag
/// Both must round-trip cleanly and the decoder must tolerate a mix
/// (different draggable rows could in theory contribute different
/// formats to the same drop event).
final class BookDragPayloadTests: XCTestCase {

    // MARK: - encode

    func testSingleBookEncodesAsRawUUID() {
        let id = UUID()
        let payload = BookDragPayload.encode(book: id, selection: [])
        XCTAssertEqual(payload, id.uuidString, "no selection → plain UUID, backward-compat with the old format")
    }

    func testBookOutsideSelectionEncodesAsRawUUID() {
        // The dragged book isn't part of the multi-selection — drag should
        // only carry this one book (matches Finder behaviour).
        let dragged = UUID()
        let other1 = UUID()
        let other2 = UUID()
        let payload = BookDragPayload.encode(book: dragged, selection: [other1, other2])
        XCTAssertEqual(payload, dragged.uuidString)
    }

    func testSingleSelectionEncodesAsRawUUID() {
        // Selection of size 1 = no real multi-drag; keep the simpler format.
        let id = UUID()
        let payload = BookDragPayload.encode(book: id, selection: [id])
        XCTAssertEqual(payload, id.uuidString)
    }

    func testMultiSelectionUsesBOOKSPrefix() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let payload = BookDragPayload.encode(book: a, selection: [a, b, c])
        XCTAssertTrue(payload.hasPrefix("BOOKS:"), "multi-selection must use the BOOKS: prefix")
        // All three IDs must be in the payload, in some order.
        for id in [a, b, c] {
            XCTAssertTrue(payload.contains(id.uuidString), "payload missing \(id)")
        }
    }

    func testMultiSelectionOrderIsDeterministic() {
        // Stable order makes logs / tests reproducible. The implementation
        // sorts uuid strings lexicographically.
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let payload1 = BookDragPayload.encode(book: a, selection: [a, b, c])
        let payload2 = BookDragPayload.encode(book: b, selection: [c, a, b])
        XCTAssertEqual(payload1, payload2, "same selection set produces same payload regardless of order")
    }

    // MARK: - decode

    func testDecodesRawUUID() {
        let id = UUID()
        let result = BookDragPayload.decode(items: [id.uuidString])
        XCTAssertEqual(result, [id])
    }

    func testDecodesBOOKSCsv() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let csv = [a, b, c].map(\.uuidString).joined(separator: ",")
        let result = BookDragPayload.decode(items: ["BOOKS:" + csv])
        XCTAssertEqual(Set(result), Set([a, b, c]))
        XCTAssertEqual(result.count, 3)
    }

    func testDecodesMixedFormats() {
        // A drop event could contain both a multi-payload (from a multi-
        // selection drag) AND stray single UUIDs from another source. The
        // decoder must handle both in one call.
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let result = BookDragPayload.decode(items: [
            "BOOKS:\(a.uuidString),\(b.uuidString)",
            c.uuidString
        ])
        XCTAssertEqual(Set(result), Set([a, b, c]))
    }

    func testDecodeDeduplicates() {
        // Same UUID in both a multi-payload and a stray single must
        // surface only once — otherwise addBooksToCollection runs the
        // INSERT twice (which would be harmless but noisy).
        let dup = UUID()
        let extra = UUID()
        let result = BookDragPayload.decode(items: [
            "BOOKS:\(dup.uuidString),\(extra.uuidString)",
            dup.uuidString
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result), Set([dup, extra]))
    }

    func testDecodeIgnoresGarbageItems() {
        let valid = UUID()
        let result = BookDragPayload.decode(items: [
            valid.uuidString,
            "not-a-uuid",
            "BOOKS:also-not-a-uuid,still-not-a-uuid",
            "BOOKS:" // empty list
        ])
        XCTAssertEqual(result, [valid], "non-UUID tokens must be silently dropped")
    }

    func testEmptyItemsYieldsEmpty() {
        XCTAssertTrue(BookDragPayload.decode(items: []).isEmpty)
    }

    // MARK: - round trip

    func testEncodeDecodeRoundTripPreservesSelection() {
        let ids = (0..<10).map { _ in UUID() }
        let payload = BookDragPayload.encode(book: ids[0], selection: Set(ids))
        let decoded = BookDragPayload.decode(items: [payload])
        XCTAssertEqual(Set(decoded), Set(ids), "every selected book must round-trip through the wire")
        XCTAssertEqual(decoded.count, ids.count)
    }
}
