import SwiftUI

/// Reader color theme.
enum ReaderTheme: String, CaseIterable, Codable, Sendable {
    case normal
    case sepia
    case night

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .sepia: "Sepia"
        case .night: "Night"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .normal: .white
        case .sepia: Color(red: 0.96, green: 0.94, blue: 0.86)
        case .night: Color(red: 0.10, green: 0.10, blue: 0.10)
        }
    }

    var textColor: Color {
        switch self {
        case .normal: Color(red: 0.10, green: 0.10, blue: 0.10)
        case .sepia: Color(red: 0.36, green: 0.27, blue: 0.21)
        case .night: Color(red: 0.88, green: 0.88, blue: 0.88)
        }
    }

    /// NSColor for PDFView background
    var nsPdfBackground: NSColor {
        switch self {
        case .normal: NSColor(white: 0.88, alpha: 1.0)
        case .sepia: NSColor(red: 0.87, green: 0.83, blue: 0.74, alpha: 1.0)
        case .night: NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0)
        }
    }

    /// Swatch color for the theme picker circles
    var swatchColor: Color {
        switch self {
        case .normal: .white
        case .sepia: Color(red: 0.96, green: 0.94, blue: 0.86)
        case .night: Color(red: 0.15, green: 0.15, blue: 0.15)
        }
    }

    /// CSS injected into WKWebView for theming
    var cssOverride: String {
        let bg: String
        let fg: String
        let linkColor: String
        let imgFilter: String

        switch self {
        case .normal:
            bg = "#FFFFFF"; fg = "#1A1A1A"; linkColor = "#0066CC"; imgFilter = "none"
        case .sepia:
            bg = "#F5EFDC"; fg = "#5B4636"; linkColor = "#7B5B3A"; imgFilter = "none"
        case .night:
            bg = "#1A1A1A"; fg = "#E0E0E0"; linkColor = "#6CA6E0"; imgFilter = "brightness(0.85)"
        }

        return """
        html, body { background-color: \(bg) !important; color: \(fg) !important; }
        p, span, div, h1, h2, h3, h4, h5, h6, li, td, th, dt, dd, blockquote, pre, code, figcaption, caption, label, summary { color: \(fg) !important; }
        a { color: \(linkColor) !important; }
        img, svg { filter: \(imgFilter) !important; }
        """
    }
}
