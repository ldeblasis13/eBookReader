import Foundation
import os

/// Parses FB2 (FictionBook 2) XML files and converts them to HTML for rendering.
actor FB2Parser {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "FB2Parser"
    )

    // MARK: - Data Types

    struct FB2Content: Sendable {
        let metadata: FB2Metadata
        let htmlContent: String
        let sections: [FB2Section]
    }

    struct FB2Metadata: Sendable {
        var title: String?
        var author: String?
        var language: String?
        var annotation: String?
        var coverImageData: Data?
    }

    struct FB2Section: Identifiable, Sendable {
        let id: String
        let title: String?
        let children: [FB2Section]
    }

    enum FB2Error: Error {
        case parseError
        case noBody
    }

    // MARK: - Public API

    func parse(bookURL: URL) throws -> FB2Content {
        let data = try Data(contentsOf: bookURL)
        let document = try XMLDocument(data: data)

        let metadata = extractMetadata(from: document)
        let binaries = extractBinaries(from: document)
        let (html, sections) = convertBodyToHTML(document: document, binaries: binaries)

        return FB2Content(
            metadata: metadata,
            htmlContent: html,
            sections: sections
        )
    }

    // MARK: - Metadata Extraction

    private func extractMetadata(from document: XMLDocument) -> FB2Metadata {
        var metadata = FB2Metadata()

        // Title
        metadata.title = xpathText(document, "//*[local-name()='title-info']/*[local-name()='book-title']")

        // Author
        let firstName = xpathText(document, "//*[local-name()='title-info']/*[local-name()='author']/*[local-name()='first-name']")
        let lastName = xpathText(document, "//*[local-name()='title-info']/*[local-name()='author']/*[local-name()='last-name']")
        let middleName = xpathText(document, "//*[local-name()='title-info']/*[local-name()='author']/*[local-name()='middle-name']")
        metadata.author = [firstName, middleName, lastName]
            .compactMap { $0 }
            .joined(separator: " ")
        if metadata.author?.isEmpty == true { metadata.author = nil }

        // Language
        metadata.language = xpathText(document, "//*[local-name()='title-info']/*[local-name()='lang']")

        // Annotation
        let annotationNodes = (try? document.nodes(forXPath: "//*[local-name()='title-info']/*[local-name()='annotation']")) ?? []
        if let annotationElement = annotationNodes.first {
            metadata.annotation = annotationElement.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Cover image
        let coverHref = xpathText(document, "//*[local-name()='coverpage']/*[local-name()='image']/@*[local-name()='href']")
        if let coverHref {
            let binaryID = coverHref.hasPrefix("#") ? String(coverHref.dropFirst()) : coverHref
            let binaries = extractBinaries(from: document)
            metadata.coverImageData = binaries[binaryID]
        }

        return metadata
    }

    // MARK: - Binary Extraction

    private func extractBinaries(from document: XMLDocument) -> [String: Data] {
        var binaries: [String: Data] = [:]
        let binaryNodes = (try? document.nodes(forXPath: "//*[local-name()='binary']")) ?? []
        for node in binaryNodes {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let base64String = element.stringValue else { continue }
            let cleaned = base64String.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            if let data = Data(base64Encoded: cleaned) {
                binaries[id] = data
            }
        }
        return binaries
    }

    // MARK: - HTML Conversion

    private func convertBodyToHTML(document: XMLDocument, binaries: [String: Data]) -> (String, [FB2Section]) {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body {
                font-family: -apple-system, 'Helvetica Neue', sans-serif;
                line-height: 1.6;
                padding: 20px 40px;
                max-width: 800px;
                margin: 0 auto;
            }
            h1, h2, h3 { margin-top: 1.5em; }
            p { margin: 0.5em 0; text-indent: 1.5em; }
            p:first-child { text-indent: 0; }
            .section { margin-bottom: 2em; }
            .section-title { text-indent: 0; font-weight: bold; font-size: 1.2em; margin-bottom: 0.5em; }
            .epigraph { font-style: italic; margin: 1em 2em; }
            .poem { margin: 1em 2em; }
            .stanza { margin-bottom: 1em; }
            .verse { text-indent: 0; }
            .cite { margin: 1em 2em; border-left: 3px solid #ccc; padding-left: 1em; }
            .text-author { text-align: right; font-style: italic; }
            .subtitle { text-align: center; font-style: italic; margin: 1em 0; }
            .empty-line { height: 1em; }
            img { max-width: 100%; height: auto; display: block; margin: 1em auto; }
        </style>
        </head>
        <body>

        """

        var sections: [FB2Section] = []
        var sectionCounter = 0

        let bodyNodes = (try? document.nodes(forXPath: "//*[local-name()='body']")) ?? []
        for bodyNode in bodyNodes {
            guard let bodyElement = bodyNode as? XMLElement else { continue }
            let (bodyHTML, bodySections) = convertElement(bodyElement, binaries: binaries, sectionCounter: &sectionCounter)
            html += bodyHTML
            sections.append(contentsOf: bodySections)
        }

        html += "</body></html>"
        return (html, sections)
    }

    private func convertElement(_ element: XMLElement, binaries: [String: Data], sectionCounter: inout Int) -> (String, [FB2Section]) {
        var html = ""
        var sections: [FB2Section] = []

        for child in element.children ?? [] {
            if child.kind == .text {
                html += escapeHTML(child.stringValue ?? "")
                continue
            }

            guard let childElement = child as? XMLElement else { continue }
            let localName = childElement.localName ?? childElement.name ?? ""

            switch localName {
            case "section":
                sectionCounter += 1
                let sectionID = "section-\(sectionCounter)"
                let sectionTitle = extractSectionTitle(childElement)
                html += "<div class=\"section\" id=\"\(sectionID)\">"
                var childSections: [FB2Section] = []
                let (innerHTML, innerSections) = convertElement(childElement, binaries: binaries, sectionCounter: &sectionCounter)
                html += innerHTML
                childSections.append(contentsOf: innerSections)
                html += "</div>"
                sections.append(FB2Section(id: sectionID, title: sectionTitle, children: childSections))

            case "title":
                html += "<h2 class=\"section-title\">"
                for p in childElement.children ?? [] {
                    html += (p as? XMLElement)?.stringValue ?? p.stringValue ?? ""
                    html += "<br>"
                }
                html += "</h2>"

            case "p":
                html += "<p>"
                let (innerHTML, _) = convertElement(childElement, binaries: binaries, sectionCounter: &sectionCounter)
                html += innerHTML
                html += "</p>"

            case "emphasis":
                html += "<em>"
                html += childElement.stringValue ?? ""
                html += "</em>"

            case "strong":
                html += "<strong>"
                html += childElement.stringValue ?? ""
                html += "</strong>"

            case "strikethrough":
                html += "<s>"
                html += childElement.stringValue ?? ""
                html += "</s>"

            case "sub":
                html += "<sub>\(childElement.stringValue ?? "")</sub>"

            case "sup":
                html += "<sup>\(childElement.stringValue ?? "")</sup>"

            case "code":
                html += "<code>\(escapeHTML(childElement.stringValue ?? ""))</code>"

            case "a":
                let href = childElement.attribute(forName: "href")?.stringValue
                    ?? childElement.attribute(forLocalName: "href", uri: "http://www.w3.org/1999/xlink")?.stringValue
                    ?? "#"
                html += "<a href=\"\(escapeHTML(href))\">\(childElement.stringValue ?? "")</a>"

            case "image":
                let imageHref = childElement.attribute(forName: "href")?.stringValue
                    ?? childElement.attribute(forLocalName: "href", uri: "http://www.w3.org/1999/xlink")?.stringValue
                    ?? ""
                let binaryID = imageHref.hasPrefix("#") ? String(imageHref.dropFirst()) : imageHref
                if let imageData = binaries[binaryID] {
                    let contentType = childElement.attribute(forName: "content-type")?.stringValue ?? "image/jpeg"
                    let base64 = imageData.base64EncodedString()
                    html += "<img src=\"data:\(contentType);base64,\(base64)\" alt=\"\">"
                }

            case "empty-line":
                html += "<div class=\"empty-line\"></div>"

            case "epigraph":
                html += "<div class=\"epigraph\">"
                let (innerHTML, _) = convertElement(childElement, binaries: binaries, sectionCounter: &sectionCounter)
                html += innerHTML
                html += "</div>"

            case "cite":
                html += "<div class=\"cite\">"
                let (innerHTML, _) = convertElement(childElement, binaries: binaries, sectionCounter: &sectionCounter)
                html += innerHTML
                html += "</div>"

            case "poem":
                html += "<div class=\"poem\">"
                let (innerHTML, _) = convertElement(childElement, binaries: binaries, sectionCounter: &sectionCounter)
                html += innerHTML
                html += "</div>"

            case "stanza":
                html += "<div class=\"stanza\">"
                let (innerHTML, _) = convertElement(childElement, binaries: binaries, sectionCounter: &sectionCounter)
                html += innerHTML
                html += "</div>"

            case "v":
                html += "<p class=\"verse\">\(childElement.stringValue ?? "")</p>"

            case "text-author":
                html += "<p class=\"text-author\">\(childElement.stringValue ?? "")</p>"

            case "subtitle":
                html += "<p class=\"subtitle\">\(childElement.stringValue ?? "")</p>"

            case "annotation":
                html += "<div class=\"epigraph\">"
                let (innerHTML, _) = convertElement(childElement, binaries: binaries, sectionCounter: &sectionCounter)
                html += innerHTML
                html += "</div>"

            default:
                let (innerHTML, innerSections) = convertElement(childElement, binaries: binaries, sectionCounter: &sectionCounter)
                html += innerHTML
                sections.append(contentsOf: innerSections)
            }
        }

        return (html, sections)
    }

    private func extractSectionTitle(_ section: XMLElement) -> String? {
        guard let titleElement = section.elements(forName: "title").first else { return nil }
        return titleElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func xpathText(_ document: XMLDocument, _ xpath: String) -> String? {
        let text = (try? document.nodes(forXPath: xpath))?.first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}
