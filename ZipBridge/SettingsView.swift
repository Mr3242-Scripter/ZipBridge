import SwiftUI

struct SettingsView: View {
    @AppStorage("archiveProtectionEnabled") private var archiveProtectionEnabled = true
    @AppStorage("fastModeEnabled") private var fastModeEnabled = false
    @AppStorage("backgroundAudioEnabled") private var backgroundAudioEnabled = false
    @AppStorage("backgroundLocationEnabled") private var backgroundLocationEnabled = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $archiveProtectionEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Protection")
                            Text(archiveProtectionEnabled
                                  ? "2 GiB limit + strict path safety"
                                  : "All protections disabled")
                                .font(.caption)
                                .foregroundColor(archiveProtectionEnabled ? .secondary : .red)
                        }
                    }

                    if !archiveProtectionEnabled {
                        Label(
                            "Every protection is off, including path confinement. Use only with fully trusted archives.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundColor(.red)
                    }
                } header: {
                    Text("Archive Safety")
                } footer: {
                    Text("When protection is on, ZipBridge rejects path traversal, symlinks, and oversized expansions.")
                }

                Section {
                    Toggle(isOn: $fastModeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Fast Mode")
                            Text(fastModeEnabled
                                  ? "Batches under 25 MB, all files in parallel"
                                  : "One file at a time")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Upload Speed")
                } footer: {
                    Text("Fast Mode packs files into batches that never exceed 25 MB, then uploads and verifies every file in the batch together.")
                }

                Section {
                    Toggle(isOn: $backgroundAudioEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silent Audio")
                            Text("Near-silent playback keeps the app alive in the background")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle(isOn: $backgroundLocationEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Location Ping")
                            Text("Refresh location every 5 seconds while uploading")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Background Upload")
                } footer: {
                    Text("Only active during an upload. Location needs permission. Prefer Silent Audio when possible.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(.blue)
    }
}
