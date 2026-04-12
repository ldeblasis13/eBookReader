import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Page Navigation") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Page flip resistance")
                    Slider(value: $state.pageScrollResistance, in: 0...1) {
                        Text("Resistance")
                    } minimumValueLabel: {
                        Text("Light").font(.caption2)
                    } maximumValueLabel: {
                        Text("Heavy").font(.caption2)
                    }
                    Text("Controls how much scrolling is needed to flip to the next page in single-page or two-page mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Haptic feedback on page turn", isOn: $state.pageHapticFeedback)
                Text("Provides a subtle haptic tap when flipping pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("AI Models") {
                modelRow(
                    name: "Sentence Embeddings",
                    detail: "all-MiniLM-L6-v2 (~80 MB)",
                    ready: appState.embeddingModelReady,
                    downloading: appState.isDownloadingModels
                        && appState.modelDownloadProgress?.modelId == Constants.Models.embeddingModelId,
                    progress: appState.modelDownloadProgress
                )

                modelRow(
                    name: "Language Model",
                    detail: "Gemma 4 E2B (~1.5 GB)",
                    ready: appState.llmModelReady,
                    downloading: appState.isDownloadingModels
                        && appState.modelDownloadProgress?.modelId == Constants.Models.llmModelId,
                    progress: appState.modelDownloadProgress
                )

                if appState.isEmbeddingIndexing {
                    let p = appState.embeddingIndexingProgress
                    HStack {
                        ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0)
                        Text("\(p.done)/\(p.total) books")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
        .onChange(of: appState.pageHapticFeedback) {
            appState.persistSettings()
        }
        .onChange(of: appState.pageScrollResistance) {
            appState.persistSettings()
        }
    }

    @ViewBuilder
    private func modelRow(
        name: String,
        detail: String,
        ready: Bool,
        downloading: Bool,
        progress: ModelDownloadManager.DownloadProgress?
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ready {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready").font(.caption).foregroundStyle(.secondary)
            } else if downloading, let p = progress {
                ProgressView(value: p.fraction)
                    .frame(width: 80)
                Text("\(Int(p.fraction * 100))%")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("Pending").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
