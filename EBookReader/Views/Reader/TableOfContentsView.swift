import PDFKit
import SwiftUI

/// Displays a PDF's outline (table of contents) as a navigable tree.
struct TableOfContentsView: View {
    let outline: PDFOutline?
    var onSelect: ((PDFDestination) -> Void)?

    var body: some View {
        if let outline, outline.numberOfChildren > 0 {
            List {
                OutlineChildren(outline: outline, onSelect: onSelect)
            }
            .listStyle(.sidebar)
        } else {
            ContentUnavailableView(
                "No Table of Contents",
                systemImage: "list.bullet",
                description: Text("This document does not have a table of contents.")
            )
        }
    }
}

/// Recursively renders outline children as disclosure groups.
private struct OutlineChildren: View {
    let outline: PDFOutline
    var onSelect: ((PDFDestination) -> Void)?

    var body: some View {
        ForEach(0..<outline.numberOfChildren, id: \.self) { index in
            if let child = outline.child(at: index) {
                OutlineNode(node: child, onSelect: onSelect)
            }
        }
    }
}

private struct OutlineNode: View {
    let node: PDFOutline
    var onSelect: ((PDFDestination) -> Void)?

    var body: some View {
        if node.numberOfChildren > 0 {
            DisclosureGroup {
                OutlineChildren(outline: node, onSelect: onSelect)
            } label: {
                nodeLabel
            }
        } else {
            nodeLabel
        }
    }

    private var nodeLabel: some View {
        Button {
            if let destination = node.destination {
                onSelect?(destination)
            }
        } label: {
            Text(node.label ?? "Untitled")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
