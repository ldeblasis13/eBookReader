import SwiftUI

/// Sidebar listing all annotations for the current book, sorted by position.
struct AnnotationListView: View {
    @Environment(AppState.self) private var appState
    @Bindable var annotationState: AnnotationState
    let bookId: UUID
    let onNavigate: (Annotation) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                Spacer()
                Text("\(annotationState.annotations.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if annotationState.annotations.isEmpty {
                ContentUnavailableView(
                    "No Annotations",
                    systemImage: "pencil.slash",
                    description: Text("Select a tool and highlight text to annotate.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(annotationState.sortedAnnotations) { annotation in
                    AnnotationRow(annotation: annotation, onTap: {
                        onNavigate(annotation)
                    }, onDelete: {
                        Task {
                            try? await appState.annotationRepository.deleteAnnotation(id: annotation.id)
                            await reloadAnnotations()
                        }
                    })
                    .contextMenu {
                        annotationContextMenu(annotation)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func annotationContextMenu(_ annotation: Annotation) -> some View {
        Menu("Color") {
            ForEach(AnnotationColor.allCases, id: \.self) { color in
                Button {
                    Task {
                        try? await appState.annotationRepository.updateColor(id: annotation.id, color: color)
                        await reloadAnnotations()
                    }
                } label: {
                    Label(color.rawValue.capitalized, systemImage: annotation.color == color ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }

        if annotation.tool == .comment || annotation.tool == .freeText {
            Button("Edit Note...") {
                annotationState.selectedAnnotationID = annotation.id
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            Task {
                try? await appState.annotationRepository.deleteAnnotation(id: annotation.id)
                await reloadAnnotations()
            }
        }
    }

    private func reloadAnnotations() async {
        let loaded = (try? await appState.annotationRepository.fetchAnnotations(forBook: bookId)) ?? []
        annotationState.annotations = loaded
        // Notify readers to refresh visual annotations
        NotificationCenter.default.post(name: .ebookReaderRefreshAnnotations, object: nil)
    }
}

// MARK: - Annotation Row

private struct AnnotationRow: View {
    let annotation: Annotation
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Color + tool indicator
                VStack(spacing: 2) {
                    Circle()
                        .fill(annotation.color.color)
                        .frame(width: 10, height: 10)
                    Image(systemName: annotation.tool.systemImage)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    // Selected text or note preview
                    if let text = annotation.selectedText, !text.isEmpty {
                        Text(text)
                            .font(.caption)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                    if let note = annotation.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Position info
                    Text(positionLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Delete button (visible on hover)
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            isHovered ? Color.gray.opacity(0.2) : Color.clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var positionLabel: String {
        guard let pos = annotation.decodedPosition else { return "" }
        switch pos {
        case .pdf(let pageIndex, _):
            return "Page \(pageIndex + 1)"
        case .reflowable(let chapterIndex, _, _, _, _, _):
            return "Chapter \(chapterIndex + 1)"
        }
    }
}
