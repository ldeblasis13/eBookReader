import XCTest
@testable import EBookReader

/// Malformed Mobi files used to crash background scanning: a file with no
/// text records made `for i in 1...count` trap on `1...0`, and an untrusted
/// textLength went straight into `reserveCapacity`. Each test builds a
/// minimal PDB/Mobi buffer in memory; nothing touches the filesystem.
final class MobiParserTests: XCTestCase {

    // MARK: - Zero text records

    func testPalmDOCWithOnlyRecord0Throws() async throws {
        // Header claims 5 text records, but the PDB holds only record 0.
        let data = makeMobi(records: [
            makeRecord0(compression: 2, textLength: 1000, textRecordCount: 5),
        ])
        try await assertThrowsNoTextRecords(data)
    }

    func testUncompressedWithOnlyRecord0Throws() async throws {
        let data = makeMobi(records: [
            makeRecord0(compression: 1, textLength: 1000, textRecordCount: 5),
        ])
        try await assertThrowsNoTextRecords(data)
    }

    func testZeroTextRecordCountThrows() async throws {
        // A text record exists, but record 0 says there are none.
        let data = makeMobi(records: [
            makeRecord0(compression: 2, textLength: 5, textRecordCount: 0),
            Data("Hello".utf8),
        ])
        try await assertThrowsNoTextRecords(data)
    }

    // MARK: - Valid files still parse

    func testPalmDOCWithHugeTextLengthParses() async throws {
        // textLength = 4 GB must not be passed to reserveCapacity unclamped.
        // Bytes 0x09…0x7F are PalmDOC literals, so "Hello" encodes as itself.
        let data = makeMobi(records: [
            makeRecord0(compression: 2, textLength: .max, textRecordCount: 1),
            Data("Hello".utf8),
        ])
        let content = try await MobiParser().parse(data: data)
        XCTAssertTrue(content.htmlContent.contains("Hello"))
    }

    func testUncompressedSingleRecordParses() async throws {
        let data = makeMobi(records: [
            makeRecord0(compression: 1, textLength: 5, textRecordCount: 1),
            Data("Hello".utf8),
        ])
        let content = try await MobiParser().parse(data: data)
        XCTAssertTrue(content.htmlContent.contains("Hello"))
    }

    // MARK: - Helpers

    private func assertThrowsNoTextRecords(_ data: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await MobiParser().parse(data: data)
            XCTFail("Expected MobiError.noTextRecords", file: file, line: line)
        } catch MobiParser.MobiError.noTextRecords {
            // expected
        }
    }

    /// PDB container: 78-byte header, an 8-byte entry per record, then the records.
    private func makeMobi(records: [Data]) -> Data {
        var data = Data(count: 78)
        let name = Array("Test".utf8)
        data.replaceSubrange(0..<name.count, with: name)
        data.replaceSubrange(76..<78, with: bigEndian(UInt16(records.count)))

        var offset = 78 + records.count * 8
        for record in records {
            data.append(contentsOf: bigEndian(UInt32(offset)))
            data.append(contentsOf: [0, 0, 0, 0]) // attributes + unique ID
            offset += record.count
        }
        for record in records {
            data.append(record)
        }
        return data
    }

    /// 16-byte PalmDOC header with no MOBI header after it.
    private func makeRecord0(compression: UInt16, textLength: UInt32, textRecordCount: UInt16) -> Data {
        var record = Data()
        record.append(contentsOf: bigEndian(compression))
        record.append(contentsOf: [0, 0])
        record.append(contentsOf: bigEndian(textLength))
        record.append(contentsOf: bigEndian(textRecordCount))
        record.append(contentsOf: bigEndian(UInt16(4096))) // record size
        record.append(contentsOf: [0, 0, 0, 0])
        return record
    }

    private func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}
