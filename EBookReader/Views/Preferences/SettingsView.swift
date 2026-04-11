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
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 250)
        .onChange(of: appState.pageHapticFeedback) {
            appState.persistSettings()
        }
        .onChange(of: appState.pageScrollResistance) {
            appState.persistSettings()
        }
    }
}
