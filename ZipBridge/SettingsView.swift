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
                        Label("Every protection is off, including path confinement. Use only with fully trusted archives.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Archive Safety")
                }

                Section {
                    Toggle(isOn: $fastModeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Fast Mode")
                            Text(fastModeEnabled
                                  ? "Full ~25 MiB batches in parallel"
                                  : "One file at a time")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Upload Speed")
                } footer: {
                    Text("Fast Mode groups files near 25 MiB and uploads or verifies every file in that batch at once.")
                }

                Section {
                    Toggle(isOn: $backgroundAudioEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Silent Audio")
                            Text("Play near-silent audio so uploads can continue in the background")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle(isOn: $backgroundLocationEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Location Ping")
                            Text("Request location every 5 seconds while uploading")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Background Upload")
                } footer: {
                    Text("These keep the app active when you leave it during a long upload. Location requires permission. Use only while you need background transfers.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
