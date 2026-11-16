import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = UploadViewModel()
    @State private var showingImporter = false
    @AppStorage("archiveProtectionEnabled") private var archiveProtectionEnabled = true

    private var success: Bool {
        model.verificationFinished && model.verificationIssues.isEmpty &&
        model.verifiedCount == model.totalFiles && model.totalFiles > 0
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    headerCard
                    tokenCard
                    destinationCard
                    archiveCard
                    if model.archive != nil {
                        uploadCard
                        fileListCard
                    }
                    if model.verificationFinished || !model.verificationIssues.isEmpty {
                        verificationCard
                    }
                    if !model.logs.isEmpty { activityCard }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("ZipBridge")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await model.loadRepositories() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isBusy || model.token.isEmpty)
                    .accessibilityLabel("Refresh repositories")
                }
            }
        }
        .navigationViewStyle(.stack)
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue.gradient)
                        .frame(width: 52, height: 52)
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("ZIP to GitHub").font(.title3.weight(.bold))
                    Text("Extract • Upload • Verify").font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.shield.fill").font(.title2).foregroundColor(.green)
            }
            Text("Upload archive contents as individual commits, then compare every remote file against the original.")
                .font(.subheadline).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("GitHub access", icon: "key.fill")
            SecureField("Personal access token", text: $model.token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Button {
                    model.saveToken()
                    Task { await model.loadRepositories() }
                } label: {
                    Label("Save & Connect", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                Button("Forget", role: .destructive) { model.forgetToken() }
                    .buttonStyle(.bordered).disabled(model.token.isEmpty)
            }
            Text("Stored in this device's Keychain. Use a token with Contents: Read and write access.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Destination", icon: "arrow.up.right.square")
            Menu {
                if model.repositories.isEmpty {
                    Button("No repositories loaded") {}.disabled(true)
                }
                ForEach(model.repositories) { repository in
                    Button {
                        Task { await model.chooseRepository(repository) }
                    } label: {
                        if model.selectedRepository?.id == repository.id {
                            Label(repository.full_name, systemImage: "checkmark")
                        } else { Text(repository.full_name) }
                    }
                }
            } label: {
                selectionRow(
                    title: model.selectedRepository?.full_name ?? "Choose repository",
                    subtitle: model.repositories.isEmpty ? "Connect to load accessible repositories" : "Select a GitHub repository",
                    icon: "externaldrive"
                )
            }
            .disabled(model.repositories.isEmpty || model.isBusy)

            Menu {
                ForEach(model.branches) { branch in
                    Button(branch.name) { model.selectedBranch = branch }
                }
            } label: {
                selectionRow(title: model.selectedBranch?.name ?? "Choose branch", subtitle: "Target branch", icon: "arrow.triangle.branch")
            }
            .disabled(model.branches.isEmpty || model.isBusy)
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var archiveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Archive", icon: "doc.zipper")
            Button { showingImporter = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.archive?.sourceName ?? "Choose ZIP file").font(.body.weight(.semibold)).lineLimit(1)
                        Text(model.archive == nil ? "Browse the Files app" : "\(model.totalFiles) files • \(ByteCountFormatter.string(fromByteCount: model.archive?.archiveBytes ?? 0, countStyle: .file))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "folder").foregroundColor(.secondary)
                }
                .padding(13).background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Toggle(isOn: $archiveProtectionEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable protection").font(.subheadline.weight(.semibold))
                    Text(archiveProtectionEnabled
                        ? "2 GiB size limit + strict path safety (recommended)"
                        : "ALL protections disabled (including path confinement)")
                        .font(.caption)
                        .foregroundColor(archiveProtectionEnabled ? .secondary : .red)
                }
            }
            .tint(.blue)

            if !archiveProtectionEnabled {
                Label("WARNING: Every protection is off. Path traversal, symlinks, size limits and sandbox confinement are all disabled. Only use with archives you completely trust.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.archiveSizeWarning {
                Label("Archive exceeds the 25 MiB advisory threshold. ZipBridge will continue and check files individually.", systemImage: "info.circle.fill")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var uploadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Upload", icon: "arrow.up.circle.fill")
                Spacer()
                Text("\(model.uploadedPaths.count)/\(model.totalFiles)")
                    .font(.subheadline.monospacedDigit().weight(.semibold)).foregroundColor(.secondary)
            }
            ProgressView(value: model.progress).tint(.blue)
            Text(model.currentAction).font(.caption).foregroundColor(.secondary).lineLimit(2)
            Button {
                Task { await model.uploadAndVerify() }
            } label: {
                HStack {
                    if model.isBusy { ProgressView().tint(.white) }
                    Text(model.isBusy ? "Working…" : (model.uploadedPaths.isEmpty ? "Upload files & verify" : "Continue / retry & verify"))
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.up.to.line")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || model.selectedRepository == nil || model.selectedBranch == nil || model.token.isEmpty)
            Text("Each file is committed separately and uploads run one at a time. Files over 100 MiB are skipped by GitHub's Contents API limit.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var fileListCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ZIP contents", icon: "list.bullet.rectangle")
            ForEach(model.archive?.files ?? []) { file in
                HStack(spacing: 10) {
                    Image(systemName: model.uploadedPaths.contains(file.relativePath) ? "checkmark.circle.fill" : (model.failedPaths[file.relativePath] == nil ? "doc" : "exclamationmark.circle.fill"))
                        .foregroundColor(model.uploadedPaths.contains(file.relativePath) ? .green : (model.failedPaths[file.relativePath] == nil ? .secondary : .orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.relativePath).font(.subheadline).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 4)
                    if model.uploadedPaths.contains(file.relativePath) {
                        Text("Sent").font(.caption2).foregroundColor(.green)
                    } else if model.failedPaths[file.relativePath] != nil {
                        Text("Issue").font(.caption2).foregroundColor(.orange)
                    }
                }
                if file.id != model.archive?.files.last?.id { Divider() }
            }
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var verificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Integrity check", icon: "checkmark.shield")
                Spacer()
                Image(systemName: success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(success ? .green : .orange)
            }
            Text(success ? "All files are present and match the ZIP." : "Verification found files that need attention.")
                .font(.subheadline.weight(.semibold))
            Text("\(model.verifiedCount) of \(model.totalFiles) files verified with SHA-256.")
                .font(.caption).foregroundColor(.secondary)
            ForEach(model.verificationIssues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.path).font(.caption.weight(.semibold))
                    Text(issue.detail).font(.caption).foregroundColor(.secondary)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Activity", icon: "text.alignleft")
            ForEach(Array(model.logs.suffix(12)), id: \.self) { line in
                Text(line).font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footer: some View {
        Text("ZipBridge • Private by design • iOS 16+")
            .font(.caption2).foregroundColor(Color(uiColor: .tertiaryLabel)).padding(.top, 2)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline)
    }

    private func selectionRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundColor(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundColor(.secondary)
        }
        .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 11)).contentShape(Rectangle())
    }
}

// Mirrors SideStore's native ZIP import: UIDocumentPickerViewController,
// filtered to ZIP files and configured to copy the selected archive into the app.
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
