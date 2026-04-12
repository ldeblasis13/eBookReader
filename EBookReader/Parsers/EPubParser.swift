import Foundation
import ZIPFoundation
import os

/// Parses ePub files: extracts ZIP, reads OPF metadata/spine/manifest, and parses TOC (NCX or nav).
actor EPubParser {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "EPubParser"
    )

    // MARK: - Data Types

    struct EPubContent: Sendable {
        let metadata: EPubMetadata
        let manifest: [ManifestItem]
        let spine: [SpineItem]
        let toc: [TOCItem]
        let extractedBaseURL: URL
        let opfDirectoryURL: URL
    }

    struct EPubMetadata: Sendable {
        var title: String?
        var author: String?
        var language: String?
        var publisher: String?
        var description: String?
        var coverHref: String?
    }

    struct ManifestItem: Sendable {
        let id: String
        let href: String
        let mediaType: String
    }

    struct SpineItem: Sendable {
        let idref: String
        let href: String
        let mediaType: String
    }

    struct TOCItem: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let href: String
        let children: [TOCItem]
    }

    enum EPubError: Error {
        case extractionFailed
        case containerNotFound
        case opfNotFound
        case invalidStructure
    }

    // MARK: - Public API

    /// Parses an ePub file and returns its content structure.
    /// Extracts the ZIP to `~/Library/Caches/EBookReader/EPubExtracted/{bookID}/`.
    func parse(bookURL: URL, bookID: UUID) throws -> EPubContent {
        let extractDir = Constants.Directories.epubExtractedCache
            .appendingPathComponent(bookID.uuidString, isDirectory: true)

        // Extract if not already cached
        if !FileManager.default.fileExists(atPath: extractDir.path) {
            try extractEPub(from: bookURL, to: extractDir)
        }

        // Parse container.xml to find OPF path
        let opfRelativePath = try parseContainer(at: extractDir)
        let opfURL = extractDir.appendingPathComponent(opfRelativePath)
        let opfDirectory = opfURL.deletingLastPathComponent()

        // Parse OPF
        let opfData = try Data(contentsOf: opfURL)
        let opfDocument = try XMLDocument(data: opfData)
        let metadata = parseOPFMetadata(opfDocument)
        let manifest = parseOPFManifest(opfDocument)
        let spine = parseOPFSpine(opfDocument, manifest: manifest)

        // Parse TOC (try NCX first, then nav)
        let toc = parseTOC(manifest: manifest, opfDocument: opfDocument, opfDirectory: opfDirectory)

        return EPubContent(
            metadata: metadata,
            manifest: manifest,
            spine: spine,
            toc: toc,
            extractedBaseURL: extractDir,
            opfDirectoryURL: opfDirectory
        )
    }

    /// Returns the file URL for a specific spine item, suitable for loading in WKWebView.
    func chapterURL(for content: EPubContent, spineIndex: Int) -> URL? {
        guard spineIndex >= 0, spineIndex < content.spine.count else { return nil }
        let href = content.spine[spineIndex].href
        return content.opfDirectoryURL.appendingPathComponent(href)
    }

    /// Extracts cover image data from the ePub.
    func extractCoverImage(from content: EPubContent) -> Data? {
        guard let coverHref = content.metadata.coverHref else { return nil }
        let coverURL = content.opfDirectoryURL.appendingPathComponent(coverHref)
        return try? Data(contentsOf: coverURL)
    }

    /// Builds a single HTML document combining all spine items for seamless scroll mode.
    /// Each chapter's body content is wrapped in a `<div class="eb-chapter">`.
    /// The file is cached — rebuilt only when missing.
    func buildCombinedDocument(for content: EPubContent) throws -> URL {
        let combinedURL = content.opfDirectoryURL.appendingPathComponent("__eb_combined.html")

        if FileManager.default.fileExists(atPath: combinedURL.path) {
            return combinedURL
        }

        var styleLinks = Set<String>()
        var bodyParts: [String] = []

        for (index, spineItem) in content.spine.enumerated() {
            let chapterURL = content.opfDirectoryURL.appendingPathComponent(spineItem.href)
            guard let data = try? Data(contentsOf: chapterURL),
                  let html = String(data: data, encoding: .utf8) else { continue }

            // Chapter's directory relative to the OPF directory
            let chapterDir: String
            if let slashIdx = spineItem.href.lastIndex(of: "/") {
                chapterDir = String(spineItem.href[...slashIdx])
            } else {
                chapterDir = ""
            }

            // Extract <link> stylesheet hrefs, resolve paths relative to OPF dir
            let linkRE = try! NSRegularExpression(
                pattern: #"<link[^>]+href=["']([^"']+)["'][^>]*>"#, options: .caseInsensitive)
            for match in linkRE.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                if let range = Range(match.range(at: 1), in: html) {
                    var href = String(html[range])
                    if !href.hasPrefix("http") && !href.hasPrefix("/") {
                        href = chapterDir + href
                    }
                    styleLinks.insert("<link rel=\"stylesheet\" href=\"\(href)\">")
                }
            }

            // Extract body content
            let body = Self.extractBodyContent(from: html)
            bodyParts.append(
                "<div class=\"eb-chapter\" data-chapter=\"\(index)\" data-base=\"\(chapterDir)\">\(body)</div>"
            )
        }

        let combined = """
        <!DOCTYPE html>
        <html><head><meta charset="UTF-8">
        \(styleLinks.sorted().joined(separator: "\n"))
        </head><body>
        \(bodyParts.joined(separator: "\n"))
        </body></html>
        """

        try combined.write(to: combinedURL, atomically: true, encoding: .utf8)
        logger.info("Built combined document: \(content.spine.count) chapters")
        return combinedURL
    }

    /// Extracts content between <body> and </body> tags.
    private static func extractBodyContent(from html: String) -> String {
        guard let bodyStart = html.range(of: "<body", options: .caseInsensitive),
              let tagEnd = html.range(of: ">", range: bodyStart.upperBound..<html.endIndex),
              let bodyEnd = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) else {
            return html
        }
        return String(html[tagEnd.upperBound..<bodyEnd.lowerBound])
    }

    /// Removes the extracted cache for a book.
    func clearCache(bookID: UUID) {
        let extractDir = Constants.Directories.epubExtractedCache
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
    }

    // MARK: - ZIP Extraction

    private func extractEPub(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: sourceURL, to: destinationURL)
        logger.info("Extracted ePub to \(destinationURL.lastPathComponent)")
    }

    // MARK: - Container Parsing

    private func parseContainer(at extractDir: URL) throws -> String {
        let containerURL = extractDir
            .appendingPathComponent("META-INF")
            .appendingPathComponent("container.xml")

        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw EPubError.containerNotFound
        }

        let containerData = try Data(contentsOf: containerURL)
        let document = try XMLDocument(data: containerData)

        // Look for <rootfile full-path="..."/> using local-name() to avoid namespace issues
        let rootfiles = try document.nodes(
            forXPath: "//*[local-name()='rootfile']/@full-path"
        )
        guard let path = rootfiles.first?.stringValue, !path.isEmpty else {
            throw EPubError.opfNotFound
        }
        return path
    }

    // MARK: - OPF Parsing

    private func parseOPFMetadata(_ document: XMLDocument) -> EPubMetadata {
        var metadata = EPubMetadata()

        // Use local-name() to handle XML namespaces without needing prefix registration
        metadata.title = xpathText(document, "//*[local-name()='metadata']/*[local-name()='title']")
        metadata.author = xpathText(document, "//*[local-name()='metadata']/*[local-name()='creator']")
        metadata.language = xpathText(document, "//*[local-name()='metadata']/*[local-name()='language']")
        metadata.publisher = xpathText(document, "//*[local-name()='metadata']/*[local-name()='publisher']")
        metadata.description = xpathText(document, "//*[local-name()='metadata']/*[local-name()='description']")

        // Cover image: look for <meta name="cover" content="cover-image-id"/>
        let coverID = xpathText(document, "//*[local-name()='meta'][@name='cover']/@content")
        if let coverID {
            // Find manifest item with this ID
            let coverHref = xpathText(
                document,
                "//*[local-name()='item'][@id='\(coverID)']/@href"
            )
            metadata.coverHref = coverHref
        }

        // Fallback: look for manifest item with properties="cover-image" (ePub 3)
        if metadata.coverHref == nil {
            metadata.coverHref = xpathText(
                document,
                "//*[local-name()='item'][@properties='cover-image']/@href"
            )
        }

        return metadata
    }

    private func parseOPFManifest(_ document: XMLDocument) -> [ManifestItem] {
        var items: [ManifestItem] = []
        let nodes = (try? document.nodes(forXPath: "//*[local-name()='item']")) ?? []
        for node in nodes {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue,
                  let mediaType = element.attribute(forName: "media-type")?.stringValue else {
                continue
            }
            items.append(ManifestItem(id: id, href: href, mediaType: mediaType))
        }
        return items
    }

    private func parseOPFSpine(_ document: XMLDocument, manifest: [ManifestItem]) -> [SpineItem] {
        var items: [SpineItem] = []
        let manifestMap = Dictionary(uniqueKeysWithValues: manifest.map { ($0.id, $0) })

        let nodes = (try? document.nodes(forXPath: "//*[local-name()='itemref']")) ?? []
        for node in nodes {
            guard let element = node as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue,
                  let manifestItem = manifestMap[idref] else {
                continue
            }
            items.append(SpineItem(
                idref: idref,
                href: manifestItem.href,
                mediaType: manifestItem.mediaType
            ))
        }
        return items
    }

    // MARK: - TOC Parsing

    private func parseTOC(manifest: [ManifestItem], opfDocument: XMLDocument, opfDirectory: URL) -> [TOCItem] {
        // Try ePub 3 nav document first
        if let navItem = manifest.first(where: { item in
            let props = (try? opfDocument.nodes(
                forXPath: "//*[local-name()='item'][@id='\(item.id)']/@properties"
            ))?.first?.stringValue
            return props?.contains("nav") == true
        }) {
            let navURL = opfDirectory.appendingPathComponent(navItem.href)
            if let items = parseNavDocument(at: navURL), !items.isEmpty {
                return items
            }
        }

        // Fallback to NCX (ePub 2)
        if let ncxItem = manifest.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            let ncxURL = opfDirectory.appendingPathComponent(ncxItem.href)
            return parseNCX(at: ncxURL)
        }

        return []
    }

    private func parseNavDocument(at url: URL) -> [TOCItem]? {
        guard let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data, options: [.documentTidyHTML]) else {
            return nil
        }

        // Find the nav element with epub:type="toc"
        let navNodes = (try? document.nodes(forXPath: "//nav")) ?? []
        for navNode in navNodes {
            guard let navElement = navNode as? XMLElement else { continue }
            let epubType = navElement.attribute(forName: "epub:type")?.stringValue
                ?? navElement.attribute(forName: "type")?.stringValue
            if epubType == "toc" || navNodes.count == 1 {
                if let ol = navElement.elements(forName: "ol").first {
                    return parseNavOL(ol)
                }
            }
        }

        // Broader fallback: find any <ol> inside a <nav>
        if let firstNav = navNodes.first as? XMLElement,
           let ol = firstNav.elements(forName: "ol").first {
            return parseNavOL(ol)
        }

        return nil
    }

    private func parseNavOL(_ ol: XMLElement) -> [TOCItem] {
        var items: [TOCItem] = []
        for li in ol.elements(forName: "li") {
            let anchor = li.elements(forName: "a").first
            let title = anchor?.stringValue ?? "Untitled"
            let href = anchor?.attribute(forName: "href")?.stringValue ?? ""
            let childOL = li.elements(forName: "ol").first
            let children = childOL.map { parseNavOL($0) } ?? []
            items.append(TOCItem(title: title, href: href, children: children))
        }
        return items
    }

    private func parseNCX(at url: URL) -> [TOCItem] {
        guard let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data) else {
            return []
        }

        let navMap = (try? document.nodes(forXPath: "//*[local-name()='navMap']"))?.first as? XMLElement
        guard let navMap else { return [] }
        return parseNCXNavPoints(navMap)
    }

    private func parseNCXNavPoints(_ element: XMLElement) -> [TOCItem] {
        var items: [TOCItem] = []
        for child in element.children ?? [] {
            guard let navPoint = child as? XMLElement,
                  navPoint.localName == "navPoint" else { continue }

            let title = navPoint.elements(forName: "navLabel").first?
                .elements(forName: "text").first?.stringValue ?? "Untitled"
            let href = navPoint.elements(forName: "content").first?
                .attribute(forName: "src")?.stringValue ?? ""
            let children = parseNCXNavPoints(navPoint)
            items.append(TOCItem(title: title, href: href, children: children))
        }
        return items
    }

    // MARK: - XPath Helpers

    private func xpathText(_ document: XMLDocument, _ xpath: String) -> String? {
        let nodes = try? document.nodes(forXPath: xpath)
        let text = nodes?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}
