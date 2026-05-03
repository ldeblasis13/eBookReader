import SwiftUI

/// Stylized recipe card for cookbook-mode chat responses. Renders the parsed
/// recipe with title, optional preamble, full ingredient list, full
/// instructions, optional notes, and an Open button that jumps to the
/// originating page in the source book.
struct RecipeCardView: View {
    let recipe: ChatMessage.ParsedRecipe
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let preamble = recipe.preamble, !preamble.isEmpty {
                Text(preamble)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !recipe.ingredients.isEmpty {
                ingredientsSection
            }
            if !recipe.instructions.isEmpty {
                instructionsSection
            }
            if let notes = recipe.notes, !notes.isEmpty {
                notesSection(notes)
            }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "fork.knife.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: "book.closed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(recipe.bookTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let author = recipe.author, !author.isEmpty {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Button(action: onOpen) {
                Label("Open", systemImage: "arrow.up.right.square")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Ingredients")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.orange)
                        Text(item)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Instructions")
            Text(recipe.instructions)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Notes")
            Text(notes)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if let completeness = recipe.completeness, !completeness.isEmpty {
                let isPartial = completeness.lowercased().contains("partial")
                HStack(spacing: 4) {
                    Image(systemName: isPartial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption2)
                    Text(completeness)
                        .font(.caption2)
                }
                .foregroundStyle(isPartial ? .orange : .green)
            }
            Spacer()
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.orange)
            .tracking(0.5)
    }
}
