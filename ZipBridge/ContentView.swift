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
                // MARK: Header
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(uiColor: .systemBlue))
                                .frame(width: 48, height: 48)
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("ZIP to GitHub")
                                .font(.headline)
                            Text("Extract · Upload · Verify")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "checkmark.shield.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 4)

                    Text("Upload archive contents as individual commits, then compare every remote file against the original.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // MARK: GitHub Access
                Section {
                    SecureField("Personal Access Token", text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack(spacing: 12) {
                        Button {
                            model.saveToken()
                            Task { await model.loadRepositories() }
                        } label: {
                            Label("Save & Connect", systemImage: "lock.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)

                        Button("Forget", role: .destructive) {
                            model.forgetToken()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.token.isEmpty)
                    }
                } header: {
                    Text("GitHub Access")
                } footer: {
                    Text("Stored securely in the Keychain. Token needs Contents: Read and write permission.")
                }

                // MARK: Destination
                Section {
                    Menu {
                        if model.repositories.isEmpty {
                            Button("No repositories loaded") {}
                                .disabled(true)
                        }
                        ForEach(model.repositories) { repo in
                            Button {
                                Task { await model.chooseRepository(repo) }
                            } label: {
                                if model.selectedRepository?.id == repo.id {
                                    Label(repo.full_name, systemImage: "checkmark")
                                } else {
                                    Text(repo.full_name)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Label(
                                model.selectedRepository?.full_name ?? "Choose Repository",
                                systemImage: "externaldrive.fill"
                            )
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(model.repositories.isEmpty || model.isBusy)

                    Menu {
                        ForEach(model.branches) { branch in
                            Button(branch.name) {
                                model.selectedBranch = branch
                            }
                        }
                    } label: {
                        HStack {
                            Label(
                                model.selectedBranch?.name ?? "Choose Branch",
                                systemImage: "arrow.triangle.branch"
                            )
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(model.branches.isEmpty || model.isBusy)
                } header: {
                    Text("Destination")
                }

                // MARK: Archive
                Section {
                    Button {
                        showingImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.archive?.sourceName ?? "Choose ZIP File")
                                    .foregroundColor(.primary)
                                Text(model.archive == nil
                                      ? "Browse the Files app"
                                      : "\(model.totalFiles) files · \(ByteCountFormatter.string(fromByteCount: model.archive?.archiveBytes ?? 0, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "folder")
                                .foregroundColor(.secondary)
                        }
                    }

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
                    .tint(.blue)

                    if !archiveProtectionEnabled {
                        Label("Every protection is off, including path confinement. Use only with fully trusted archives.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if model.archiveSizeWarning {
                        Label("Archive exceeds the 25 MiB advisory threshold.", systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                } header: {
                    Text("Archive")
                }

                // MARK: Upload
                if model.archive != nil {
                    Section {
                        HStack {
                            Text("Progress")
                            Spacer()
                            Text("\(model.uploadedPaths.count)/\(model.totalFiles)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        ProgressView(value: model.progress)
                            .tint(.blue)

                        Text(model.currentAction)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            Task { await model.uploadAndVerify() }
                        } label: {
                            HStack {
                                if model.isBusy {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text(model.isBusy
                                      ? "Working…"
                                      : (model.uploadedPaths.isEmpty ? "Upload Files & Verify" : "Continue / Retry & Verify"))
                                    .fontWeight(.semibold)
                                Spacer()
                                Image(systemName: "arrow.up.to.line")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.selectedRepository == nil || model.selectedBranch == nil || model.token.isEmpty)
                    } header: {
                        Text("Upload")
                    } footer: {
                        Text("Each file is committed separately. Files over 100 MiB are skipped by GitHub’s Contents API.")
                    }

                    // MARK: File List
                    Section {
                        ForEach(model.archive?.files ?? []) { file in
                            HStack(spacing: 12) {
                                Image(systemName: statusIcon(for: file.relativePath))
                                    .foregroundColor(statusColor(for: file.relativePath))
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.relativePath)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if model.uploadedPaths.contains(file.relativePath) {
                                    Text("Sent")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                } else if model.failedPaths[file.relativePath] != nil {
                                    Text("Issue")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    } header: {
                        Text("ZIP Contents")
                    }
                }

                // MARK: Verification
                if model.verificationFinished || !model.verificationIssues.isEmpty {
                    Section {
                        HStack {
                            Text(success ? "All files match" : "Issues found")
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(success ? .green : .orange)
                        }

                        Text("\(model.verifiedCount) of \(model.totalFiles) files verified with SHA-256.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(model.verificationIssues) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.path)
                                    .font(.caption.weight(.semibold))
                                Text(issue.detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Integrity Check")
                    }
                }

                // MARK: Activity
                if !model.logs.isEmpty {
                    Section {
                        ForEach(Array(model.logs.suffix(10)), id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Activity")
                    }
                }
            }
            .navigationTitle("ZipBridge")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await model.loadRepositories() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isBusy || model.token.isEmpty)
                }
            }
        }
        .background {
            ZipDocumentPicker(isPresented: $showingImporter) { url in
                Task { await model.prepareArchive(at: url, protectionEnabled: archiveProtectionEnabled) }
            } onError: { error in
                model.errorMessage = error.localizedDescription
            }
            .frame(width: 0, height: 0)
        }
        .alert("ZipBridge", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
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

// MARK: - Document Picker

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
