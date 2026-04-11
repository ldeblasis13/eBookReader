import Foundation
import os

/// Pure-Swift parser for Mobi (.mobi) and KF8/AZW3 (.azw3) e-book files.
/// Extracts metadata, cover images, and HTML content for rendering in WKWebView.
actor MobiParser {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "MobiParser"
    )

    // MARK: - Public Types

    struct MobiContent: Sendable {
        let metadata: MobiMetadata
        let htmlContent: String
        let chapters: [Chapter]
        let coverImageData: Data?
    }

    struct MobiMetadata: Sendable {
        var title: String?
        var author: String?
        var language: String?
        var publisher: String?
        var description: String?
        var isbn: String?
    }

    struct Chapter: Sendable {
        let title: String
        let anchor: String // id or offset marker
    }

    enum MobiError: Error, LocalizedError {
        case fileTooSmall
        case invalidPDBHeader
        case invalidMOBIHeader
        case unsupportedCompression(UInt16)
        case decompressionFailed

        var errorDescription: String? {
            switch self {
            case .fileTooSmall: "File is too small to be a valid Mobi file"
            case .invalidPDBHeader: "Invalid PDB (Palm Database) header"
            case .invalidMOBIHeader: "Invalid MOBI header"
            case .unsupportedCompression(let t): "Unsupported compression type: \(t)"
            case .decompressionFailed: "Failed to decompress text content"
            }
        }
    }

    // MARK: - Internal Structures

    private struct PDBHeader {
        let name: String
        let numRecords: Int
        let recordOffsets: [UInt32] // byte offset for each record
    }

    private struct Record0Info {
        let compression: UInt16       // 1=none, 2=PalmDOC, 17480=HUFF/CDIC
        let textLength: UInt32
        let textRecordCount: UInt16
        let recordSize: UInt16        // usually 4096
        let encoding: UInt32          // 1252=CP1252, 65001=UTF-8
        let firstImageRecord: UInt32
        let firstNonBookRecord: UInt32
        let exthFlags: UInt32
        let fullName: String?
        let metadata: MobiMetadata
        let coverImageIndex: Int?     // relative to first image record
    }

    // MARK: - Public API

    func parse(bookURL: URL) async throws -> MobiContent {
        let data = try Data(contentsOf: bookURL)
        guard data.count >= 78 else { throw MobiError.fileTooSmall }

        let pdb = try parsePDB(data)
        guard pdb.numRecords > 0 else { throw MobiError.invalidPDBHeader }

        let record0 = try parseRecord0(data, pdb: pdb)

        // Decompress text
        let text: String
        switch record0.compression {
        case 1: // No compression
            text = try extractUncompressed(data, pdb: pdb, record0: record0)
        case 2: // PalmDOC
            text = try decompressPalmDOC(data, pdb: pdb, record0: record0)
        default:
            // HUFF/CDIC (17480) or unknown — extract metadata only
            logger.info("Unsupported compression \(record0.compression), metadata-only extraction")
            text = "<html><body><p>This Mobi file uses unsupported compression. Metadata was extracted but content cannot be displayed.</p></body></html>"
        }

        let coverData = extractCoverImage(data, pdb: pdb, record0: record0)
        let chapters = extractChapters(from: text)

        // Use EXTH title, fall back to PDB name
        var metadata = record0.metadata
        if metadata.title == nil || metadata.title?.isEmpty == true {
            metadata.title = record0.fullName ?? pdb.name
        }

        return MobiContent(
            metadata: metadata,
            htmlContent: wrapHTML(text, encoding: record0.encoding),
            chapters: chapters,
            coverImageData: coverData
        )
    }

    /// Quick metadata-only extraction (no text decompression).
    func extractMetadata(from url: URL) async -> MobiMetadata {
        do {
            let data = try Data(contentsOf: url)
            guard data.count >= 78 else { return MobiMetadata() }
            let pdb = try parsePDB(data)
            guard pdb.numRecords > 0 else { return MobiMetadata() }
            let record0 = try parseRecord0(data, pdb: pdb)
            var meta = record0.metadata
            if meta.title == nil { meta.title = record0.fullName ?? pdb.name }
            return meta
        } catch {
            logger.warning("Mobi metadata extraction failed: \(error.localizedDescription)")
            return MobiMetadata()
        }
    }

    /// Quick cover image extraction (no text decompression).
    func extractCoverImage(from url: URL) async -> Data? {
        do {
            let data = try Data(contentsOf: url)
            guard data.count >= 78 else { return nil }
            let pdb = try parsePDB(data)
            guard pdb.numRecords > 0 else { return nil }
            let record0 = try parseRecord0(data, pdb: pdb)
            return extractCoverImage(data, pdb: pdb, record0: record0)
        } catch {
            return nil
        }
    }

    // MARK: - PDB Header

    private func parsePDB(_ data: Data) throws -> PDBHeader {
        // Name: bytes 0-31 (null-terminated)
        let nameData = data.subdata(in: 0..<32)
        let name = String(data: nameData, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters) ?? ""

        // Number of records: bytes 76-77
        let numRecords = Int(readUInt16(data, offset: 76))
        guard numRecords > 0 else { throw MobiError.invalidPDBHeader }

        // Record info list starts at byte 78, each entry is 8 bytes
        let recordListEnd = 78 + numRecords * 8
        guard data.count >= recordListEnd else { throw MobiError.fileTooSmall }

        var offsets: [UInt32] = []
        for i in 0..<numRecords {
            let offset = readUInt32(data, offset: 78 + i * 8)
            offsets.append(offset)
        }

        return PDBHeader(name: name, numRecords: numRecords, recordOffsets: offsets)
    }

    // MARK: - Record 0 (MOBI Header)

    private func parseRecord0(_ data: Data, pdb: PDBHeader) throws -> Record0Info {
        let r0Start = Int(pdb.recordOffsets[0])
        let r0End = pdb.numRecords > 1 ? Int(pdb.recordOffsets[1]) : data.count
        guard r0Start + 16 <= data.count, r0End <= data.count else {
            throw MobiError.invalidMOBIHeader
        }

        // PalmDOC header (first 16 bytes of record 0)
        let compression = readUInt16(data, offset: r0Start)
        let textLength = readUInt32(data, offset: r0Start + 4)
        let textRecordCount = readUInt16(data, offset: r0Start + 8)
        let recordSize = readUInt16(data, offset: r0Start + 10)

        // MOBI header (starts at r0Start + 16)
        var encoding: UInt32 = 1252
        var firstImageRecord: UInt32 = 0
        var firstNonBookRecord: UInt32 = UInt32(pdb.numRecords)
        var exthFlags: UInt32 = 0
        var fullName: String? = nil

        let mobiStart = r0Start + 16
        if mobiStart + 4 <= data.count {
            let identifier = data.subdata(in: mobiStart..<(mobiStart + 4))
            if identifier == Data("MOBI".utf8) {
                // Valid MOBI header
                if mobiStart + 132 <= data.count {
                    let headerLength = readUInt32(data, offset: mobiStart + 4)
                    encoding = readUInt32(data, offset: mobiStart + 12)

                    if mobiStart + Int(headerLength) <= data.count {
                        if headerLength >= 68 {
                            firstNonBookRecord = readUInt32(data, offset: mobiStart + 64)
                        }
                        if headerLength >= 76 {
                            let nameOffset = Int(readUInt32(data, offset: mobiStart + 68))
                            let nameLength = Int(readUInt32(data, offset: mobiStart + 72))
                            if nameOffset > 0, nameLength > 0,
                               r0Start + nameOffset + nameLength <= data.count {
                                let nameData = data.subdata(
                                    in: (r0Start + nameOffset)..<(r0Start + nameOffset + nameLength)
                                )
                                fullName = String(data: nameData, encoding: encoding == 65001 ? .utf8 : .windowsCP1252)
                            }
                        }
                        if headerLength >= 96 {
                            firstImageRecord = readUInt32(data, offset: mobiStart + 92)
                        }
                        if headerLength >= 116 {
                            exthFlags = readUInt32(data, offset: mobiStart + 112)
                        }
                    }
                }
            }
        }

        // Parse EXTH header if present (bit 6 of exthFlags)
        var metadata = MobiMetadata()
        var coverImageIndex: Int? = nil

        if exthFlags & 0x40 != 0 {
            let parsed = parseEXTH(data, mobiStart: mobiStart, encoding: encoding)
            metadata = parsed.metadata
            coverImageIndex = parsed.coverImageIndex
        }

        return Record0Info(
            compression: compression,
            textLength: textLength,
            textRecordCount: textRecordCount,
            recordSize: recordSize,
            encoding: encoding,
            firstImageRecord: firstImageRecord,
            firstNonBookRecord: firstNonBookRecord,
            exthFlags: exthFlags,
            fullName: fullName,
            metadata: metadata,
            coverImageIndex: coverImageIndex
        )
    }

    // MARK: - EXTH Header

    private struct EXTHResult {
        var metadata: MobiMetadata
        var coverImageIndex: Int?
    }

    private func parseEXTH(_ data: Data, mobiStart: Int, encoding: UInt32) -> EXTHResult {
        let headerLength = Int(readUInt32(data, offset: mobiStart + 4))
        let exthStart = mobiStart + 4 + headerLength // EXTH follows MOBI header

        guard exthStart + 12 <= data.count else { return EXTHResult(metadata: MobiMetadata()) }
        let id = data.subdata(in: exthStart..<(exthStart + 4))
        guard id == Data("EXTH".utf8) else { return EXTHResult(metadata: MobiMetadata()) }

        let recordCount = Int(readUInt32(data, offset: exthStart + 8))
        let stringEncoding: String.Encoding = encoding == 65001 ? .utf8 : .windowsCP1252

        var meta = MobiMetadata()
        var coverIndex: Int? = nil
        var offset = exthStart + 12

        for _ in 0..<recordCount {
            guard offset + 8 <= data.count else { break }
            let type = Int(readUInt32(data, offset: offset))
            let length = Int(readUInt32(data, offset: offset + 4))
            guard length >= 8, offset + length <= data.count else { break }

            let valueData = data.subdata(in: (offset + 8)..<(offset + length))
            let stringValue = String(data: valueData, encoding: stringEncoding)

            switch type {
            case 100: meta.author = stringValue
            case 101: meta.publisher = stringValue
            case 103: meta.description = stringValue
            case 104: meta.isbn = stringValue
            case 201: // Cover offset (image index relative to first image record)
                if valueData.count >= 4 {
                    coverIndex = Int(readUInt32(valueData, offset: 0))
                }
            case 503: meta.title = stringValue
            default: break
            }

            offset += length
        }

        return EXTHResult(metadata: meta, coverImageIndex: coverIndex)
    }

    // MARK: - Text Decompression

    private func extractUncompressed(_ data: Data, pdb: PDBHeader, record0: Record0Info) throws -> String {
        let encoding: String.Encoding = record0.encoding == 65001 ? .utf8 : .windowsCP1252
        var textData = Data()
        let count = min(Int(record0.textRecordCount), pdb.numRecords - 1)

        for i in 1...count {
            let start = Int(pdb.recordOffsets[i])
            let end = (i + 1 < pdb.numRecords) ? Int(pdb.recordOffsets[i + 1]) : data.count
            guard start < end, end <= data.count else { continue }
            textData.append(data.subdata(in: start..<end))
        }

        return String(data: textData, encoding: encoding) ?? ""
    }

    private func decompressPalmDOC(_ data: Data, pdb: PDBHeader, record0: Record0Info) throws -> String {
        let encoding: String.Encoding = record0.encoding == 65001 ? .utf8 : .windowsCP1252
        var textData = Data()
        textData.reserveCapacity(Int(record0.textLength))
        let count = min(Int(record0.textRecordCount), pdb.numRecords - 1)

        for i in 1...count {
            let start = Int(pdb.recordOffsets[i])
            let end = (i + 1 < pdb.numRecords) ? Int(pdb.recordOffsets[i + 1]) : data.count
            guard start < end, end <= data.count else { continue }

            let recordData = data.subdata(in: start..<end)
            let decompressed = decompressPalmDOCRecord(recordData)
            textData.append(decompressed)
        }

        return String(data: textData, encoding: encoding) ?? ""
    }

    /// PalmDOC LZ77 decompression for a single record.
    private func decompressPalmDOCRecord(_ input: Data) -> Data {
        var output = Data()
        output.reserveCapacity(4096)
        var i = 0

        while i < input.count {
            let byte = input[i]
            i += 1

            if byte == 0 {
                // Literal null
                output.append(0)
            } else if byte <= 8 {
                // Copy next 'byte' bytes literally
                let count = Int(byte)
                let end = min(i + count, input.count)
                output.append(contentsOf: input[i..<end])
                i = end
            } else if byte <= 0x7F {
                // Literal byte
                output.append(byte)
            } else if byte <= 0xBF {
                // Back-reference: 2 bytes encode distance and length
                guard i < input.count else { break }
                let next = input[i]
                i += 1

                let distance = ((Int(byte) << 8) | Int(next)) >> 3 & 0x7FF
                let length = (Int(next) & 7) + 3

                guard distance > 0 else { continue }

                for _ in 0..<length {
                    let srcIndex = output.count - distance
                    if srcIndex >= 0, srcIndex < output.count {
                        output.append(output[srcIndex])
                    }
                }
            } else {
                // 0xC0-0xFF: space + (byte XOR 0x80)
                output.append(0x20) // space
                output.append(byte ^ 0x80)
            }
        }

        return output
    }

    // MARK: - Image Extraction

    private func extractCoverImage(_ data: Data, pdb: PDBHeader, record0: Record0Info) -> Data? {
        let firstImage = Int(record0.firstImageRecord)
        guard firstImage > 0, firstImage < pdb.numRecords else { return nil }

        // Use cover index from EXTH if available, otherwise use first image
        let imageIndex = record0.coverImageIndex ?? 0
        let recordIndex = firstImage + imageIndex
        guard recordIndex < pdb.numRecords else { return nil }

        let start = Int(pdb.recordOffsets[recordIndex])
        let end = (recordIndex + 1 < pdb.numRecords) ? Int(pdb.recordOffsets[recordIndex + 1]) : data.count
        guard start < end, end <= data.count else { return nil }

        let imageData = data.subdata(in: start..<end)

        // Verify it's actually image data (JPEG/PNG/GIF magic bytes)
        if imageData.count > 4 {
            let magic = Array(imageData.prefix(4))
            if magic[0] == 0xFF && magic[1] == 0xD8 { return imageData } // JPEG
            if magic[0] == 0x89 && magic[1] == 0x50 { return imageData } // PNG
            if magic[0] == 0x47 && magic[1] == 0x49 { return imageData } // GIF
            if magic[0] == 0x42 && magic[1] == 0x4D { return imageData } // BMP
        }

        // Try first image record as fallback
        if imageIndex != 0 {
            return extractImageRecord(data, pdb: pdb, recordIndex: firstImage)
        }

        return nil
    }

    private func extractImageRecord(_ data: Data, pdb: PDBHeader, recordIndex: Int) -> Data? {
        guard recordIndex < pdb.numRecords else { return nil }
        let start = Int(pdb.recordOffsets[recordIndex])
        let end = (recordIndex + 1 < pdb.numRecords) ? Int(pdb.recordOffsets[recordIndex + 1]) : data.count
        guard start < end, end <= data.count else { return nil }
        return data.subdata(in: start..<end)
    }

    // MARK: - Chapter Extraction

    private func extractChapters(from html: String) -> [Chapter] {
        // Extract chapters from HTML heading tags or <mbp:pagebreak> markers
        var chapters: [Chapter] = []
        let patterns = [
            "<h1[^>]*>(.*?)</h1>",
            "<h2[^>]*>(.*?)</h2>",
            "<h3[^>]*>(.*?)</h3>",
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            for match in matches {
                if let range = Range(match.range(at: 1), in: html) {
                    let title = String(html[range])
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        let anchor = "ch_\(chapters.count)"
                        chapters.append(Chapter(title: title, anchor: anchor))
                    }
                }
            }

            if !chapters.isEmpty { break } // Use the highest-level headings found
        }

        return chapters
    }

    // MARK: - HTML Wrapping

    private func wrapHTML(_ content: String, encoding: UInt32) -> String {
        // If content already looks like HTML, return it with basic styling
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHTMLTags = trimmed.lowercased().hasPrefix("<html") || trimmed.lowercased().hasPrefix("<!doctype")

        if hasHTMLTags {
            return content
        }

        // Wrap plain text or partial HTML in a basic document
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="\(encoding == 65001 ? "utf-8" : "windows-1252")">
        <style>
            body { font-family: Georgia, serif; line-height: 1.6; padding: 20px; max-width: 800px; margin: 0 auto; }
            h1, h2, h3 { margin-top: 1.5em; }
            p { margin: 0.5em 0; }
            img { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        \(content)
        </body>
        </html>
        """
    }

    // MARK: - Binary Helpers

    private func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) // Big-endian
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24 |
               UInt32(data[offset + 1]) << 16 |
               UInt32(data[offset + 2]) << 8 |
               UInt32(data[offset + 3])
    }
}
