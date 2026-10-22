import XCTest
@testable import EBookReader

/// Malformed CHM files used to crash background scanning: header offsets are
/// UInt64 and directory entry offsets are encoded ints that can reach Int.max,
/// and both went through `Int(UInt64)` and unchecked `+`. Each test builds a
/// minimal ITSF/ITSP/PMGL buffer in memory in the layout CHMParser reads.
final class CHMParserTests: XCTestCase {

    private struct Entry {
        let name: String
        let section: Int
        let offset: Int
        let length: Int
    }

    private let dirStart = 128
    private let dirHeaderLength = 84
    private let blockSize = 256

    // MARK: - Directory offsets → throw

    func testSection1OffsetBeyondIntMaxThrows() async throws {
        let data = makeCHM(section1Offset: .max, entries: [])
        try await assertThrowsDirectoryParsingFailed(data)
    }

    func testSection1LengthOverflowingDirStartThrows() async throws {
        // dirStart (128) + Int.max overflows Int.
        let data = makeCHM(section1Length: UInt64(Int.max), entries: [])
        try await assertThrowsDirectoryParsingFailed(data)
    }

    // MARK: - Content offsets → skip the entry, don't crash

    func testContentOffsetBeyondIntMaxIsSkipped() async throws {
        let data = makeCHM(contentOffset: .max, entries: hugeOffsetEntries())
        let content = try await CHMParser().parse(data: data)
        XCTAssertFalse(content.htmlContent.contains("chm_section_"))
        XCTAssertNil(content.coverImageData)
    }

    func testEntryOffsetOverflowingContentOffsetIsSkipped() async throws {
        // contentOffset 0 + offset Int.max fits, but adding the length overflows.
        let data = makeCHM(contentOffset: 0, entries: hugeOffsetEntries())
        let content = try await CHMParser().parse(data: data)
        XCTAssertFalse(content.htmlContent.contains("chm_section_"))
        XCTAssertNil(content.metadata.defaultTopic)
    }

    // MARK: - Valid file still parses

    func testValidSection0EntryIsExtracted() async throws {
        let page = Data("<html><body><p>Hello CHM</p></body></html>".utf8)
        let data = makeCHM(
            entries: [Entry(name: "/index.html", section: 0, offset: 0, length: page.count)],
            content: page
        )
        let content = try await CHMParser().parse(data: data)
        XCTAssertTrue(content.htmlContent.contains("chm_section_0"))
        XCTAssertTrue(content.htmlContent.contains("Hello CHM"))
    }

    // MARK: - Helpers

    /// One uncompressed (#SYSTEM, read for metadata) and one "compressed"
    /// (HTML page, read for content) entry, both at offset Int.max.
    private func hugeOffsetEntries() -> [Entry] {
        [
            Entry(name: "/#SYSTEM", section: 0, offset: .max, length: 16),
            Entry(name: "/index.html", section: 1, offset: .max, length: 16),
        ]
    }

    private func assertThrowsDirectoryParsingFailed(_ data: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await CHMParser().parse(data: data)
            XCTFail("Expected CHMError.directoryParsingFailed", file: file, line: line)
        } catch CHMParser.CHMError.directoryParsingFailed {
            // expected
        }
    }

    /// v3 ITSF header (section table at byte 28, as CHMParser reads it), then
    /// an ITSP directory with one PMGL listing block, then `content`.
    /// nil header fields default to a well-formed file.
    private func makeCHM(
        section1Offset: UInt64? = nil,
        section1Length: UInt64? = nil,
        contentOffset: UInt64? = nil,
        entries: [Entry],
        content: Data = Data()
    ) -> Data {
        let dirLength = dirHeaderLength + blockSize

        var data = Data(count: dirStart)
        put(Array("ITSF".utf8), into: &data, at: 0)
        put(UInt32(3), into: &data, at: 4)                 // version
        put(UInt32(dirStart), into: &data, at: 8)          // header length
        put(section1Offset ?? UInt64(dirStart), into: &data, at: 44)
        put(section1Length ?? UInt64(dirLength), into: &data, at: 52)
        put(contentOffset ?? UInt64(dirStart + dirLength), into: &data, at: 60)

        var itsp = Data(count: dirHeaderLength)
        put(Array("ITSP".utf8), into: &itsp, at: 0)
        put(UInt32(dirHeaderLength), into: &itsp, at: 4)
        put(UInt32(blockSize), into: &itsp, at: 8)
        put(UInt32(1), into: &itsp, at: 24)                // index depth
        put(UInt32(1), into: &itsp, at: 36)                // number of blocks

        var listing: [UInt8] = []
        for entry in entries {
            let name = Array(entry.name.utf8)
            listing += encodedInt(name.count) + name
            listing += encodedInt(entry.section) + encodedInt(entry.offset) + encodedInt(entry.length)
        }
        let blockHeaderLength = 20
        var block = Data(count: blockSize)
        put(Array("PMGL".utf8), into: &block, at: 0)
        put(UInt32(blockSize - blockHeaderLength - listing.count), into: &block, at: 4) // free space
        put(listing, into: &block, at: blockHeaderLength)

        data.append(itsp)
        data.append(block)
        data.append(content)
        return data
    }

    /// CHM encoded integer: big-endian 7-bit groups, high bit set on all but the last.
    private func encodedInt(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return bytes
    }

    private func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
        put(withUnsafeBytes(of: value.littleEndian, Array.init), into: &data, at: offset)
    }

    private func put(_ bytes: [UInt8], into data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
