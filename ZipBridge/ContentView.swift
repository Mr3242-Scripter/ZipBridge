import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = UploadViewModel()
    @State private var showingImporter = false
    @AppStorage("archiveProtectionEnabled") private var archiveProtectionEnabled = true

    private var success: Bool {
        model.verificationFinished &&
        model.verificationIssues.isEmpty &&
        model.verifiedCount == model.totalFiles &&
        model.totalFiles > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                // Header
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("ZIP to GitHub")
                                .font(.headline)
                            Text("Extract · Upload · Verify")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "checkmark.shield.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 2)

                    Text("Upload archive contents as individual commits, then compare every remote file against the original.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // GitHub Access
                Section {
                    SecureField("Personal Access Token", text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)

                    Button {
                        model.saveToken()
                        Task { await model.loadRepositories() }
                    } label: {
                        Label("Save & Connect", systemImage: "lock.fill")
                    }
                    .disabled(model.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)

                    Button("Forget Token", role: .destructive) {
                        model.forgetToken()
                    }
                    .disabled(model.token.isEmpty)
                } header: {
                    Text("GitHub Access")
                } footer: {
                    Text("The token is stored in the device Keychain and never leaves this device. It requires Contents: Read and write permission.")
                }

                // Destination
                Section {
                    Picker("Repository", selection: Binding(
                        get: { model.selectedRepository },
                        set: { newValue in
                            if let newValue {
                                Task { await model.chooseRepository(newValue) }
                            }
                        }
                    )) {
                        Text("Choose Repository").tag(Optional<GitHubRepository>.none)
                        ForEach(model.repositories) { repo in
                            Text(repo.full_name).tag(Optional(repo))
                        }
                    }
                    .disabled(model.repositories.isEmpty || model.isBusy)

                    Picker("Branch", selection: $model.selectedBranch) {
                        Text("Choose Branch").tag(Optional<GitHubBranch>.none)
                        ForEach(model.branches) { branch in
                            Text(branch.name).tag(Optional(branch))
                        }
                    }
                    .disabled(model.branches.isEmpty || model.isBusy)
                } header: {
                    Text("Destination")
                }

                // Archive
                Section {
                    Button {
                        showingImporter = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.archive?.sourceName ?? "Choose ZIP File")
                                    .foregroundStyle(.primary)
                                Text(model.archive == nil
                                      ? "Browse the Files app"
                                      : "\(model.totalFiles) files · \(ByteCountFormatter.string(fromByteCount: model.archive?.archiveBytes ?? 0, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }

                    Toggle(isOn: $archiveProtectionEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Protection")
                            Text(archiveProtectionEnabled
                                  ? "2 GiB limit + strict path safety"
                                  : "All protections disabled")
                                .font(.caption)
                                .foregroundStyle(archiveProtectionEnabled ? .secondary : .red)
                        }
                    }

                    if !archiveProtectionEnabled {
                        Label("Every protection is off, including path confinement. Use only with fully trusted archives.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if model.archiveSizeWarning {
                        Label("Archive exceeds the 25 MiB advisory threshold.", systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Archive")
                }

                // Upload
                if model.archive != nil {
                    Section {
                        HStack {
                            Text("Progress")
                            Spacer()
                            Text("\(model.uploadedPaths.count)/\(model.totalFiles)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        ProgressView(value: model.progress)

                        Text(model.currentAction)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            Task { await model.uploadAndVerify() }
                        } label: {
                            if model.isBusy {
                                HStack {
                                    ProgressView()
                                    Text("Working…")
                                }
                            } else {
                                Label(
                                    model.uploadedPaths.isEmpty ? "Upload Files & Verify" : "Continue / Retry & Verify",
                                    systemImage: "arrow.up.to.line"
                                )
                            }
                        }
                        .disabled(model.isBusy || model.selectedRepository == nil || model.selectedBranch == nil || model.token.isEmpty)
                    } header: {
                        Text("Upload")
                    } footer: {
                        Text("Each file is committed separately. Files larger than 100 MiB are skipped by GitHub’s Contents API.")
                    }

                    // File list
                    Section {
                        ForEach(model.archive?.files ?? []) { file in
                            HStack(spacing: 12) {
                                Image(systemName: statusIcon(for: file.relativePath))
                                    .foregroundStyle(statusColor(for: file.relativePath))
                                    .frame(width: 22, alignment: .center)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.relativePath)
                                        .font(.body)
                                        .lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 8)

                                if model.uploadedPaths.contains(file.relativePath) {
                                    Text("Sent")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else if model.failedPaths[file.relativePath] != nil {
                                    Text("Issue")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    } header: {
                        Text("ZIP Contents")
                    }
                }

                // Verification
                if model.verificationFinished || !model.verificationIssues.isEmpty {
                    Section {
                        HStack {
                            Text(success ? "All files match" : "Issues found")
                            Spacer()
                            Image(systemName: success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(success ? .green : .orange)
                        }

                        Text("\(model.verifiedCount) of \(model.totalFiles) files verified with SHA-256.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(model.verificationIssues) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.path)
                                    .font(.subheadline.weight(.medium))
                                Text(issue.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Integrity Check")
                    }
                }

                // Activity log
                if !model.logs.isEmpty {
                    Section {
                        ForEach(Array(model.logs.suffix(12)), id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Activity")
                    }
                }
            }
            .navigationTitle("ZipBridge")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Button {
                            Task { await model.loadRepositories() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(model.token.isEmpty)
                        .accessibilityLabel("Refresh repositories")
                    }
                }
            }
        }
        .tint(.blue)
        .background {
            ZipDocumentPicker(isPresented: $showingImporter) { url in
                Task { await model.prepareArchive(at: url, protectionEnabled: archiveProtectionEnabled) }
            } onError: { error in
                model.errorMessage = error.localizedDescription
            }
            .frame(width: 0, height: 0)
        }
        // Native iOS 16 alert
        .alert(
            "Unable to Continue",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "An unexpected error occurred.")
        }
        .task {
            if !model.token.isEmpty && model.repositories.isEmpty {
                await model.loadRepositories()
            }
        }
    }

    // MARK: - Helpers

    private func statusIcon(for path: String) -> String {
        if model.uploadedPaths.contains(path) { return "checkmark.circle.fill" }
        if model.failedPaths[path] != nil { return "exclamationmark.circle.fill" }
        return "doc"
    }

    private func statusColor(for path: String) -> Color {
        if model.uploadedPaths.contains(path) { return .green }
        if model.failedPaths[path] != nil { return .orange }
        return .secondary
    }
}

// MARK: - Document Picker (iOS 16)

private struct ZipDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (URL) -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPick: onPick, onError: onError)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard isPresented, !context.coordinator.isPickerPresented else { return }

        DispatchQueue.main.async {
            guard self.isPresented, !context.coordinator.isPickerPresented else { return }

            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: true)
            picker.allowsMultipleSelection = false
            picker.delegate = context.coordinator
            context.coordinator.isPickerPresented = true
            controller.present(picker, animated: true)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        @Binding private var isPresented: Bool
        private let onPick: (URL) -> Void
        private let onError: (Error) -> Void
        var isPickerPresented = false

        init(isPresented: Binding<Bool>, onPick: @escaping (URL) -> Void, onError: @escaping (Error) -> Void) {
            _isPresented = isPresented
            self.onPick = onPick
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            isPickerPresented = false
            isPresented = false
            guard let url = urls.first else { return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            isPickerPresented = false
            isPresented = false
        }
    }
}
