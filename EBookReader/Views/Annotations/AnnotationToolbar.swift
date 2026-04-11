import SwiftUI

/// Annotation tool selection bar shown below the reader toolbar when annotations are active.
struct AnnotationToolbar: View {
    @Environment(AppState.self) private var appState
    @Bindable var annotationState: AnnotationState
    let isPDF: Bool

    private var availableTools: [AnnotationTool] {
        isPDF ? AnnotationTool.pdfTools : AnnotationTool.reflowableTools
    }

    var body: some View {
        HStack(spacing: 8) {
            // Tool buttons
            ForEach(availableTools, id: \.self) { tool in
                toolButton(tool)
            }

            Divider().frame(height: 20)

            // Color picker
            HStack(spacing: 4) {
                ForEach(AnnotationColor.allCases, id: \.self) { color in
                    colorButton(color)
                }
            }

            Spacer()

            // Annotation list toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    annotationState.showAnnotationList.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet.rectangle")
                    if !annotationState.annotations.isEmpty {
                        Text("\(annotationState.annotations.count)")
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(annotationState.showAnnotationList ? Color.accentColor : .secondary)
            .help("Annotation List")

            // Deactivate / ESC hint
            if annotationState.activeTool != nil {
                Divider().frame(height: 20)

                Button {
                    annotationState.deactivateTool()
                } label: {
                    Text("ESC")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Deactivate annotation tool (Escape)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .onKeyPress(.escape) {
            if annotationState.activeTool != nil {
                annotationState.deactivateTool()
                return .handled
            }
            return .ignored
        }
    }

    @ViewBuilder
    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isActive = annotationState.activeTool == tool
        Button {
            annotationState.toggleTool(tool)
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help(tool.displayName)
    }

    @ViewBuilder
    private func colorButton(_ color: AnnotationColor) -> some View {
        let isSelected = annotationState.activeColor == color
        Button {
            annotationState.activeColor = color
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().stroke(
                        isSelected ? Color.primary : Color.gray.opacity(0.3),
                        lineWidth: isSelected ? 2 : 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        .help(color.rawValue.capitalized)
    }
}
