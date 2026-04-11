import SwiftUI

/// Right-side panel listing all in-book search matches with page/context.
struct SearchResultsSidebar: View {
    @Bindable var searchState: InBookSearchState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Results")
                    .font(.headline)
                Spacer()
                if searchState.totalMatches > 0 {
                    Text("\(searchState.totalMatches) matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Results list
            List(searchState.results) { match in
                SearchResultRow(
                    match: match,
                    isActive: match.index == searchState.currentMatchIndex
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    searchState.goToMatch(at: match.index)
                }
            }
            .listStyle(.plain)
        }
        .background(.bar)
    }
}

private struct SearchResultRow: View {
    let match: InBookSearchState.SearchMatch
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(match.pageLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(isActive ? .primary : .secondary)

            Text(match.context)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .listRowBackground(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
