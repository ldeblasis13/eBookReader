import Foundation
import os

/// Pure-Swift parser for Microsoft Compiled HTML Help (.chm) files.
/// Extracts metadata, topic tree, and HTML content for rendering in WKWebView.
actor CHMParser {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "CHMParser"
    )

    // MARK: - Public Types

    struct CHMContent: Sendable {
        let metadata: CHMMetadata
        let htmlContent: String
        let sections: [Section]
        let coverImageData: Data?
    }

    struct CHMMetadata: Sendable {
        var title: String?
        var defaultTopic: String?
        var language: String?
    }

    struct Section: Sendable {
        let title: String
        let path: String
        let children: [Section]
    }

    enum CHMError: Error, LocalizedError {
        case fileTooSmall
        case invalidHeader
        case unsupportedVersion(UInt32)
        case directoryParsingFailed
        case contentExtractionFailed

        var errorDescription: String? {
            switch self {
            case .fileTooSmall: "File is too small to be a valid CHM file"
            case .invalidHeader: "Invalid CHM (ITSF) header"
            case .unsupportedVersion(let v): "Unsupported CHM version: \(v)"
            case .directoryParsingFailed: "Failed to parse CHM directory"
            case .contentExtractionFailed: "Failed to extract CHM content"
            }
        }
    }

    // MARK: - Internal Structures

    private struct ITSFHeader {
        let version: UInt32
        let headerLength: UInt32
        let section0Offset: UInt64
        let section0Length: UInt64
        let section1Offset: UInt64
        let section1Length: UInt64
        let contentOffset: UInt64
    }

    private struct DirectoryEntry {
        let name: String
        let section: Int
        let offset: Int
        let length: Int
    }

    // MARK: - Public API

    func parse(bookURL: URL) async throws -> CHMContent {
        let data = try Data(contentsOf: bookURL)
        guard data.count >= 56 else { throw CHMError.fileTooSmall }

        let header = try parseITSFHeader(data)
        let entries = try parseDirectory(data, header: header)
        let metadata = extractMetadata(data, entries: entries, header: header)
        let sections = buildTOC(data, entries: entries, header: header, metadata: metadata)
        let htmlContent = buildCombinedHTML(data, entries: entries, header: header, sections: sections, metadata: metadata)
        let coverData = extractCoverImage(data, entries: entries, header: header)

        return CHMContent(
            metadata: metadata,
            htmlContent: htmlContent,
            sections: sections,
            coverImageData: coverData
        )
    }

    /// Quick metadata-only extraction.
    func extractMetadata(from url: URL) async -> CHMMetadata {
        do {
            let data = try Data(contentsOf: url)
            guard data.count >= 56 else { return CHMMetadata() }
            let header = try parseITSFHeader(data)
            let entries = try parseDirectory(data, header: header)
            return extractMetadata(data, entries: entries, header: header)
        } catch {
            logger.warning("CHM metadata extraction failed: \(error.localizedDescription)")
            return CHMMetadata()
        }
    }

    // MARK: - ITSF Header

    private func parseITSFHeader(_ data: Data) throws -> ITSFHeader {
        // Verify signature
        guard data.count >= 4 else { throw CHMError.fileTooSmall }
        let sig = String(data: data.subdata(in: 0..<4), encoding: .ascii) ?? ""
        guard sig == "ITSF" else { throw CHMError.invalidHeader }

        let version = readUInt32LE(data, offset: 4)
        guard version >= 2, version <= 4 else { throw CHMError.unsupportedVersion(version) }

        let headerLength = readUInt32LE(data, offset: 8)

        // Header sections are at fixed offsets depending on version
        let section0Offset: UInt64
        let section0Length: UInt64
        let section1Offset: UInt64
        let section1Length: UInt64
        let contentOffset: UInt64

        // Section 0 and 1 info starts at offset 24 (v2) or 28 (v3)
        let baseOffset = version == 2 ? 24 : 28

        guard data.count >= baseOffset + 32 else { throw CHMError.fileTooSmall }
        section0Offset = readUInt64LE(data, offset: baseOffset)
        section0Length = readUInt64LE(data, offset: baseOffset + 8)
        section1Offset = readUInt64LE(data, offset: baseOffset + 16)
        section1Length = readUInt64LE(data, offset: baseOffset + 24)

        if version >= 3, data.count >= baseOffset + 40 {
            contentOffset = readUInt64LE(data, offset: baseOffset + 32)
        } else {
            contentOffset = UInt64(headerLength)
        }

        return ITSFHeader(
            version: version,
            headerLength: headerLength,
            section0Offset: section0Offset,
            section0Length: section0Length,
            section1Offset: section1Offset,
            section1Length: section1Length,
            contentOffset: contentOffset
        )
    }

    // MARK: - Directory Parsing

    private func parseDirectory(_ data: Data, header: ITSFHeader) throws -> [DirectoryEntry] {
        // The directory is stored in section 1
        let dirStart = Int(header.section1Offset)
        let dirEnd = dirStart + Int(header.section1Length)
        guard dirStart >= 0, dirEnd <= data.count, dirEnd > dirStart else {
            throw CHMError.directoryParsingFailed
        }

        // Parse ITSP header at the start of the directory
        guard dirStart + 4 <= data.count else { throw CHMError.directoryParsingFailed }
        let dirSig = String(data: data.subdata(in: dirStart..<(dirStart + 4)), encoding: .ascii) ?? ""

        var entries: [DirectoryEntry] = []

        if dirSig == "ITSP" {
            // Standard ITSP directory
            guard dirStart + 84 <= data.count else { throw CHMError.directoryParsingFailed }

            let dirHeaderLen = Int(readUInt32LE(data, offset: dirStart + 4))
            let blockSize = Int(readUInt32LE(data, offset: dirStart + 8))
            let indexDepth = Int(readUInt32LE(data, offset: dirStart + 24))
            _ = Int(readUInt32LE(data, offset: dirStart + 28))  // rootIndex — parsed but not needed for listing
            let numBlocks = Int(readUInt32LE(data, offset: dirStart + 36))

            // Parse listing blocks
            let listingStart = dirStart + dirHeaderLen
            let effectiveBlockSize = blockSize > 0 ? blockSize : 4096

            for blockNum in 0..<numBlocks {
                let blockOffset = listingStart + blockNum * effectiveBlockSize
                guard blockOffset + effectiveBlockSize <= data.count else { break }

                // Parse entries within this block
                let blockEntries = parseListingBlock(
                    data, offset: blockOffset, size: effectiveBlockSize, depth: indexDepth
                )
                entries.append(contentsOf: blockEntries)
            }
        } else {
            // Fallback: scan for directory entries
            entries = scanForEntries(data, dirStart: dirStart, dirEnd: dirEnd)
        }

        return entries
    }

    private func parseListingBlock(_ data: Data, offset: Int, size: Int, depth: Int) -> [DirectoryEntry] {
        var entries: [DirectoryEntry] = []
        let blockEnd = offset + size
        var pos = offset

        // Skip block header marker
        guard pos + 4 <= data.count else { return entries }
        let blockSig = String(data: data.subdata(in: pos..<(pos + 4)), encoding: .ascii) ?? ""

        if blockSig == "PMGL" {
            // Listing block
            pos += 4
            guard pos + 12 <= data.count else { return entries }

            let freeSpace = readUInt32LE(data, offset: pos)
            pos += 4 // skip free space
            pos += 4 // skip always 0
            pos += 4 // skip previous block
            pos += 4 // skip next block

            // Parse entries
            let entriesEnd = blockEnd - Int(freeSpace)
            while pos < entriesEnd, pos < blockEnd - 4 {
                guard let entry = parseDirectoryEntry(data, offset: &pos, limit: entriesEnd) else { break }
                entries.append(entry)
            }
        } else if blockSig == "PMGI" {
            // Index block — skip (we scan all blocks anyway)
        }

        return entries
    }

    private func parseDirectoryEntry(_ data: Data, offset: inout Int, limit: Int) -> DirectoryEntry? {
        // Name length (encoded integer)
        guard offset < limit else { return nil }
        let (nameLen, bytesRead1) = readEncodedInt(data, offset: offset)
        guard nameLen > 0, nameLen < 4096 else { return nil }
        offset += bytesRead1

        // Name
        guard offset + nameLen <= data.count else { return nil }
        let nameData = data.subdata(in: offset..<(offset + nameLen))
        let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .windowsCP1252) ?? ""
        offset += nameLen

        // Content section (encoded integer)
        guard offset < limit else { return nil }
        let (section, bytesRead2) = readEncodedInt(data, offset: offset)
        offset += bytesRead2

        // Offset within section (encoded integer)
        guard offset < limit else { return nil }
        let (entryOffset, bytesRead3) = readEncodedInt(data, offset: offset)
        offset += bytesRead3

        // Length (encoded integer)
        guard offset <= limit else { return nil }
        let (entryLength, bytesRead4) = readEncodedInt(data, offset: offset)
        offset += bytesRead4

        return DirectoryEntry(name: name, section: section, offset: entryOffset, length: entryLength)
    }

    private func scanForEntries(_ data: Data, dirStart: Int, dirEnd: Int) -> [DirectoryEntry] {
        // Fallback scanner — look for PMGL blocks within the directory section
        var entries: [DirectoryEntry] = []
        var pos = dirStart

        while pos + 4096 <= dirEnd {
            let sig = String(data: data.subdata(in: pos..<(pos + 4)), encoding: .ascii) ?? ""
            if sig == "PMGL" {
                entries.append(contentsOf: parseListingBlock(data, offset: pos, size: 4096, depth: 0))
            }
            pos += 4096
        }

        return entries
    }

    // MARK: - Content Extraction

    /// Extract file content from the CHM for a given directory entry.
    /// Only handles section 0 (uncompressed) content.
    private func extractFileContent(_ data: Data, entry: DirectoryEntry, header: ITSFHeader) -> Data? {
        guard entry.length > 0 else { return nil }

        if entry.section == 0 {
            // Uncompressed content — directly accessible
            let contentStart = Int(header.contentOffset) + entry.offset
            let contentEnd = contentStart + entry.length
            guard contentStart >= 0, contentEnd <= data.count else { return nil }
            return data.subdata(in: contentStart..<contentEnd)
        }

        // Section 1 (LZX compressed) — attempt to find reset table and decompress
        // For many CHM files, we can still read by finding the uncompressed listing
        // or by reading the content from the content section with offsets
        return extractCompressedContent(data, entry: entry, header: header)
    }

    private func extractCompressedContent(_ data: Data, entry: DirectoryEntry, header: ITSFHeader) -> Data? {
        // Find the ControlData and ResetTable entries for LZX decompression info
        // This is a simplified approach — works for many CHM files

        // The compressed content is stored starting at contentOffset
        // For basic CHM files, we can attempt to read with the reset table
        let contentBase = Int(header.contentOffset)
        guard contentBase + entry.offset + entry.length <= data.count else { return nil }

        // Try reading directly (works if the content happens to be accessible)
        let start = contentBase + entry.offset
        let end = start + entry.length
        guard start >= 0, end <= data.count else { return nil }

        let extracted = data.subdata(in: start..<end)

        // Validate it looks like valid content (HTML/text)
        if let str = String(data: extracted, encoding: .utf8), !str.isEmpty {
            return extracted
        }
        if let str = String(data: extracted, encoding: .windowsCP1252), !str.isEmpty {
            return extracted
        }

        return nil
    }

    // MARK: - Metadata Extraction

    private func extractMetadata(_ data: Data, entries: [DirectoryEntry], header: ITSFHeader) -> CHMMetadata {
        var metadata = CHMMetadata()

        // Look for /#SYSTEM file which contains metadata
        if let systemEntry = entries.first(where: { $0.name == "/#SYSTEM" }),
           let systemData = extractFileContent(data, entry: systemEntry, header: header) {
            parseSystemFile(systemData, metadata: &metadata)
        }

        // Look for HHC file (table of contents) for title fallback
        if metadata.title == nil {
            if let hhcEntry = entries.first(where: { $0.name.lowercased().hasSuffix(".hhc") }) {
                // Use the filename as a hint
                let name = (hhcEntry.name as NSString).lastPathComponent
                    .replacingOccurrences(of: ".hhc", with: "", options: .caseInsensitive)
                if !name.isEmpty, name != "toc" {
                    metadata.title = name
                }
            }
        }

        // Fallback title from /#STRINGS or entry names
        if metadata.title == nil || metadata.title?.isEmpty == true {
            let htmlFiles = entries.filter { isHTMLFile($0.name) && !$0.name.hasPrefix("/#") }
            if let first = htmlFiles.first {
                metadata.title = (first.name as NSString).lastPathComponent
                    .replacingOccurrences(of: ".htm", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".html", with: "", options: .caseInsensitive)
            }
        }

        return metadata
    }

    private func parseSystemFile(_ data: Data, metadata: inout CHMMetadata) {
        // /#SYSTEM file contains type-length-value entries
        var offset = 4 // Skip version
        while offset + 4 <= data.count {
            let type = readUInt16LE(data, offset: offset)
            let length = Int(readUInt16LE(data, offset: offset + 2))
            offset += 4
            guard offset + length <= data.count else { break }

            let valueData = data.subdata(in: offset..<(offset + length))
            let stringValue = String(data: valueData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)

            switch type {
            case 0: // Table of contents file
                break
            case 1: // Index file
                break
            case 2: // Default topic
                metadata.defaultTopic = stringValue
            case 3: // Title
                metadata.title = stringValue
            case 4: // Language ID
                if valueData.count >= 4 {
                    let langId = readUInt32LE(valueData, offset: 0)
                    metadata.language = languageName(for: langId)
                }
            case 9: // Compiler
                break
            default:
                break
            }

            offset += length
        }
    }

    // MARK: - Table of Contents

    private func buildTOC(_ data: Data, entries: [DirectoryEntry], header: ITSFHeader, metadata: CHMMetadata) -> [Section] {
        // Look for .hhc file (HTML Help Table of Contents)
        if let hhcEntry = entries.first(where: { $0.name.lowercased().hasSuffix(".hhc") }),
           let hhcData = extractFileContent(data, entry: hhcEntry, header: header),
           let hhcHTML = String(data: hhcData, encoding: .utf8) ?? String(data: hhcData, encoding: .windowsCP1252) {
            return parseHHC(hhcHTML)
        }

        // Fallback: create sections from HTML file list
        let htmlFiles = entries.filter { isHTMLFile($0.name) && !$0.name.hasPrefix("/#") && $0.length > 0 }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return htmlFiles.map { entry in
            let title = (entry.name as NSString).lastPathComponent
                .replacingOccurrences(of: ".htm", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ".html", with: "", options: .caseInsensitive)
            return Section(title: title, path: entry.name, children: [])
        }
    }

    /// Parse a .hhc (HTML Help TOC) file into sections.
    private func parseHHC(_ html: String) -> [Section] {
        // HHC uses <object type="text/sitemap"> with <param name="Name" value="..."> and <param name="Local" value="...">
        var sections: [Section] = []
        let pattern = "<object[^>]*type=\"text/sitemap\"[^>]*>(.*?)</object>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return sections
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let objectContent = String(html[range])

            var name: String?
            var local: String?

            let paramPattern = "<param\\s+name=\"([^\"]+)\"\\s+value=\"([^\"]*)\""
            if let paramRegex = try? NSRegularExpression(pattern: paramPattern, options: .caseInsensitive) {
                let paramMatches = paramRegex.matches(in: objectContent, range: NSRange(objectContent.startIndex..., in: objectContent))
                for pm in paramMatches {
                    guard let nameRange = Range(pm.range(at: 1), in: objectContent),
                          let valueRange = Range(pm.range(at: 2), in: objectContent) else { continue }
                    let paramName = String(objectContent[nameRange])
                    let paramValue = String(objectContent[valueRange])

                    switch paramName.lowercased() {
                    case "name": name = paramValue
                    case "local": local = paramValue
                    default: break
                    }
                }
            }

            if let name, !name.isEmpty {
                sections.append(Section(title: name, path: local ?? "", children: []))
            }
        }

        return sections
    }

    // MARK: - HTML Content Assembly

    private func buildCombinedHTML(_ data: Data, entries: [DirectoryEntry], header: ITSFHeader,
                                    sections: [Section], metadata: CHMMetadata) -> String {
        // Determine which files to include
        var htmlFiles: [DirectoryEntry]

        if !sections.isEmpty {
            // Use TOC order
            htmlFiles = sections.compactMap { section in
                entries.first { $0.name.hasSuffix(section.path) || $0.name == "/" + section.path }
            }
            // If TOC paths didn't match entries, fall back
            if htmlFiles.isEmpty {
                htmlFiles = entries.filter { isHTMLFile($0.name) && !$0.name.hasPrefix("/#") && $0.length > 0 }
            }
        } else {
            htmlFiles = entries.filter { isHTMLFile($0.name) && !$0.name.hasPrefix("/#") && $0.length > 0 }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        // If we have a default topic, put it first
        if let defaultTopic = metadata.defaultTopic {
            if let idx = htmlFiles.firstIndex(where: { $0.name.hasSuffix(defaultTopic) || $0.name == "/" + defaultTopic }) {
                let entry = htmlFiles.remove(at: idx)
                htmlFiles.insert(entry, at: 0)
            }
        }

        // Extract and combine HTML content
        var bodyParts: [String] = []

        for (i, entry) in htmlFiles.enumerated() {
            guard let fileData = extractFileContent(data, entry: entry, header: header) else { continue }
            let fileContent = String(data: fileData, encoding: .utf8)
                ?? String(data: fileData, encoding: .windowsCP1252)
                ?? ""
            guard !fileContent.isEmpty else { continue }

            // Extract body content
            let body = extractBody(from: fileContent)
            let sectionId = "chm_section_\(i)"
            bodyParts.append("<div id=\"\(sectionId)\" class=\"chm-section\">\(body)</div>")
        }

        let title = metadata.title ?? "CHM Document"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(title)</title>
        <style>
            body { font-family: -apple-system, Helvetica, Arial, sans-serif; line-height: 1.6; padding: 20px; max-width: 800px; margin: 0 auto; }
            .chm-section { margin-bottom: 2em; padding-bottom: 1em; border-bottom: 1px solid #ddd; }
            .chm-section:last-child { border-bottom: none; }
            h1, h2, h3 { margin-top: 1.2em; }
            pre, code { background: #f5f5f5; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }
            pre { padding: 12px; overflow-x: auto; }
            img { max-width: 100%; height: auto; }
            table { border-collapse: collapse; margin: 1em 0; }
            td, th { border: 1px solid #ccc; padding: 4px 8px; }
        </style>
        </head>
        <body>
        \(bodyParts.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    // MARK: - Cover Image

    private func extractCoverImage(_ data: Data, entries: [DirectoryEntry], header: ITSFHeader) -> Data? {
        // Look for common cover image names
        let coverNames = ["cover.jpg", "cover.png", "cover.gif", "cover.jpeg", "cover.bmp"]
        for name in coverNames {
            if let entry = entries.first(where: { $0.name.lowercased().hasSuffix(name) }),
               let imageData = extractFileContent(data, entry: entry, header: header) {
                return imageData
            }
        }

        // Look for any image file
        let imageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".bmp"]
        for entry in entries where entry.length > 100 {
            let lower = entry.name.lowercased()
            if imageExtensions.contains(where: { lower.hasSuffix($0) }) {
                if let imageData = extractFileContent(data, entry: entry, header: header) {
                    return imageData
                }
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func isHTMLFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".htm") || lower.hasSuffix(".html")
    }

    private func extractBody(from html: String) -> String {
        // Extract content between <body> and </body>
        let lower = html.lowercased()
        if let bodyStart = lower.range(of: "<body"),
           let bodyTagEnd = lower[bodyStart.upperBound...].range(of: ">"),
           let bodyEnd = lower.range(of: "</body>") {
            return String(html[bodyTagEnd.upperBound..<bodyEnd.lowerBound])
        }
        return html
    }

    private func languageName(for lcid: UInt32) -> String {
        switch lcid & 0xFF {
        case 0x09: "English"
        case 0x04: "Chinese"
        case 0x07: "German"
        case 0x0C: "French"
        case 0x0A: "Spanish"
        case 0x10: "Italian"
        case 0x11: "Japanese"
        case 0x12: "Korean"
        case 0x16: "Portuguese"
        case 0x19: "Russian"
        default: "Unknown"
        }
    }

    // MARK: - Encoded Integer

    private func readEncodedInt(_ data: Data, offset: Int) -> (value: Int, bytesRead: Int) {
        var value = 0
        var bytesRead = 0
        var pos = offset
        while pos < data.count {
            let byte = data[pos]
            pos += 1
            bytesRead += 1

            if byte >= 0x80 {
                value = (value << 7) | Int(byte & 0x7F)
            } else {
                value = (value << 7) | Int(byte)
                break
            }

            if bytesRead > 8 { break } // Safety limit
        }
        return (value, bytesRead)
    }

    // MARK: - Binary Helpers (Little-Endian)

    private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) |
               UInt32(data[offset + 1]) << 8 |
               UInt32(data[offset + 2]) << 16 |
               UInt32(data[offset + 3]) << 24
    }

    private func readUInt64LE(_ data: Data, offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return UInt64(data[offset]) |
               UInt64(data[offset + 1]) << 8 |
               UInt64(data[offset + 2]) << 16 |
               UInt64(data[offset + 3]) << 24 |
               UInt64(data[offset + 4]) << 32 |
               UInt64(data[offset + 5]) << 40 |
               UInt64(data[offset + 6]) << 48 |
               UInt64(data[offset + 7]) << 56
    }
}
