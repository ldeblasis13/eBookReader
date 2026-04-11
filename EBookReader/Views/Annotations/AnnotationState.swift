import Foundation
import SwiftUI

/// Per-book annotation state, injected into the reader environment.
@Observable
@MainActor
final class AnnotationState {
    var annotations: [Annotation] = []
    var activeTool: AnnotationTool? = nil
    var activeColor: AnnotationColor = .yellow
    var showAnnotationList: Bool = false

    /// Currently selected annotation (for editing/context menu)
    var selectedAnnotationID: UUID? = nil

    /// Whether the annotation toolbar is in drawing mode (shapes)
    var isDrawing: Bool { activeTool?.isShapeTool == true }

    var selectedAnnotation: Annotation? {
        guard let id = selectedAnnotationID else { return nil }
        return annotations.first { $0.id == id }
    }

    func deactivateTool() {
        activeTool = nil
    }

    func toggleTool(_ tool: AnnotationTool) {
        if activeTool == tool {
            activeTool = nil
        } else {
            activeTool = tool
        }
    }

    /// Sort annotations by their position within the book
    var sortedAnnotations: [Annotation] {
        annotations.sorted { a, b in
            let posA = a.decodedPosition?.sortKey ?? 0
            let posB = b.decodedPosition?.sortKey ?? 0
            return posA < posB
        }
    }
}
