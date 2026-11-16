import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = UploadViewModel()
    @State private var showingImporter = false
    @State private var showingSettings = false
    @AppStorage("archiveProtectionEnabled") private var archiveProtectionEnabled = true
    @AppStorage("fastModeEnabled") private var fastModeEnabled = false
    @AppStorage("backgroundAudioEnabled") private var backgroundAudioEnabled = false
    @AppStorage("backgroundLocationEnabled") private var backgroundLocationEnabled = false

    private var success: Bool {
        model.verificationFinished &&
        model.verificationIssues.isEmpty &&
        model.verifiedCount == model.totalFiles &&
        model.totalFiles > 0
    }

    var body: some View {
        NavigationStack {
            formContent
                .navigationTitle("ZipBridge")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
        }
        .tint(.blue)
        .background { documentPickerBackground }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
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

    private var formContent: some View {
        Form {
            headerSection
            githubAccessSection
            destinationSection
            archiveSection

            if model.archive != nil {
                uploadSection
                fileListSection
            }

            if model.verificationFinished || !model.verificationIssues.isEmpty {
                verificationSection
            }

            if !model.logs.isEmpty {
                activitySection
            }
        }
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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
            .padding(.vertical, 2)

            Text("Upload archive contents as individual commits, then compare every remote file against the original.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var githubAccessSection: some View {
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
            Text("Stored in the Keychain. Requires Contents: Read and write.")
        }
    }

    private var destinationSection: some View {
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
    }

    private var archiveSection: some View {
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
                }
            }

            if model.archiveSizeWarning {
                Label("Archive exceeds the 25 MiB advisory threshold.", systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            Text("Archive")
        } footer: {
            Text("Protection, Fast Mode, and background options are in Settings.")
        }
    }

    private var uploadSection: some View {
        Section {
            HStack {
                Text("Progress")
                Spacer()
                Text("\(model.uploadedPaths.count)/\(model.totalFiles)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: model.progress)

            Text(model.currentAction)
                .font(.caption)
                .foregroundColor(.secondary)

            if model.isBusy {
                Button(role: .destructive) {
                    model.cancelUpload()
                } label: {
                    Label("Cancel Upload", systemImage: "xmark.circle.fill")
                }
            } else {
                Button {
                    model.startUploadAndVerify(
                        fastMode: fastModeEnabled,
                        backgroundAudio: backgroundAudioEnabled,
                        backgroundLocation: backgroundLocationEnabled
                    )
                } label: {
                    Label(
                        model.uploadedPaths.isEmpty ? "Upload Files & Verify" : "Continue / Retry & Verify",
                        systemImage: "arrow.up.to.line"
                    )
                }
                .disabled(model.selectedRepository == nil || model.selectedBranch == nil || model.token.isEmpty)
            }
        } header: {
            Text("Upload")
        } footer: {
            Text(fastModeEnabled
                  ? "Fast Mode is on. Background keep-alive follows Settings."
                  : "One file at a time. Open Settings for Fast Mode and background options.")
        }
    }

    private var fileListSection: some View {
        Section {
            ForEach(model.archive?.files ?? []) { file in
                HStack(spacing: 12) {
                    Image(systemName: statusIcon(for: file.relativePath))
                        .foregroundColor(statusColor(for: file.relativePath))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.relativePath)
                            .font(.body)
                            .lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if model.uploadedPaths.contains(file.relativePath) {
                        Text("Sent")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if model.failedPaths[file.relativePath] != nil {
                        Text("Issue")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        } header: {
            Text("ZIP Contents")
        }
    }

    private var verificationSection: some View {
        Section {
            HStack {
                Text(success ? "All files match" : "Issues found")
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
                        .font(.subheadline.weight(.medium))
                    Text(issue.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Integrity Check")
        }
    }

    private var activitySection: some View {
        Section {
            ForEach(Array(model.logs.suffix(12)), id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Activity")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 16) {
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

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private var documentPickerBackground: some View {
        ZipDocumentPicker(isPresented: $showingImporter) { url in
            Task { await model.prepareArchive(at: url, protectionEnabled: archiveProtectionEnabled) }
        } onError: { error in
            model.errorMessage = error.localizedDescription
        }
        .frame(width: 0, height: 0)
    }

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
