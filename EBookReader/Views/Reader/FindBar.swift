import SwiftUI

/// Inline find bar with search field, prev/next arrows, and match count.
struct FindBar: View {
    @Bindable var searchState: InBookSearchState
    let onDismiss: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in book...", text: $searchState.query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onSubmit {
                    if searchState.totalMatches > 0 {
                        searchState.goToNext()
                    } else {
                        searchState.performSearch()
                    }
                }
                .onChange(of: searchState.query) { _, newValue in
                    if newValue.isEmpty {
                        searchState.totalMatches = 0
                        searchState.currentMatchIndex = 0
                        searchState.results = []
                    }
                }

            if searchState.totalMatches > 0 {
                Text("\(searchState.currentMatchIndex + 1) of \(searchState.totalMatches)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 60)
            } else if searchState.isSearching {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 40)
            } else if !searchState.query.isEmpty && searchState.totalMatches == 0 {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Previous match
            Button {
                searchState.goToPrevious()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(searchState.totalMatches == 0)
            .help("Previous match")

            // Next match
            Button {
                searchState.goToNext()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(searchState.totalMatches == 0)
            .help("Next match")

            // Search button (magnifying glass → triggers initial search)
            Button {
                searchState.performSearch()
            } label: {
                Text("Search")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            // Close
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear {
            isFieldFocused = true
        }
    }
}
