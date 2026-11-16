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
                VStack(spacing: 20) {
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

                    if !model.logs.isEmpty {
                        activityCard
                    }

                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(uiColor: .systemBlue), Color(uiColor: .systemBlue).opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)

                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("ZIP to GitHub")
                        .font(.title3.weight(.semibold))
                    Text("Extract · Upload · Verify")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundColor(Color(uiColor: .systemGreen))
            }

            Text("Upload archive contents as individual commits, then compare every remote file against the original.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Token

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("GitHub Access", icon: "key.fill")

            SecureField("Personal Access Token", text: $model.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    model.saveToken()
                    Task { await model.loadRepositories() }
                } label: {
                    Label("Save & Connect", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)

                Button("Forget", role: .destructive) {
                    model.forgetToken()
                }
                .buttonStyle(.bordered)
                .disabled(model.token.isEmpty)
            }

            Text("Stored in this device’s Keychain. Requires a token with Contents: Read and write.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Destination

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Destination", icon: "arrow.up.right.square.fill")

            Menu {
                if model.repositories.isEmpty {
                    Button("No repositories loaded") {}
                        .disabled(true)
                }
                ForEach(model.repositories) { repository in
                    Button {
                        Task { await model.chooseRepository(repository) }
                    } label: {
                        if model.selectedRepository?.id == repository.id {
                            Label(repository.full_name, systemImage: "checkmark")
                        } else {
                            Text(repository.full_name)
                        }
                    }
                }
            } label: {
                selectionRow(
                    title: model.selectedRepository?.full_name ?? "Choose Repository",
                    subtitle: model.repositories.isEmpty ? "Connect to load repositories" : "Select a GitHub repository",
                    icon: "externaldrive.fill"
                )
            }
            .disabled(model.repositories.isEmpty || model.isBusy)

            Menu {
                ForEach(model.branches) { branch in
                    Button(branch.name) {
                        model.selectedBranch = branch
                    }
                }
            } label: {
                selectionRow(
                    title: model.selectedBranch?.name ?? "Choose Branch",
                    subtitle: "Target branch",
                    icon: "arrow.triangle.branch"
                )
            }
            .disabled(model.branches.isEmpty || model.isBusy)
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Archive

    private var archiveCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Archive", icon: "doc.zipper")

            Button {
                showingImporter = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(Color(uiColor: .systemBlue))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.archive?.sourceName ?? "Choose ZIP File")
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(model.archive == nil
                              ? "Browse the Files app"
                              : "\(model.totalFiles) files · \(ByteCountFormatter.string(fromByteCount: model.archive?.archiveBytes ?? 0, countStyle: .file))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                }
                .padding(13)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)

            Toggle(isOn: $archiveProtectionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Protection")
                        .font(.subheadline.weight(.semibold))
                    Text(archiveProtectionEnabled
                          ? "2 GiB size limit + strict path safety"
                          : "ALL protections disabled")
                        .font(.caption)
                        .foregroundColor(archiveProtectionEnabled ? .secondary : .red)
                }
            }
            .tint(Color(uiColor: .systemBlue))

            if !archiveProtectionEnabled {
                Label("Every protection is off, including path confinement. Use only with fully trusted archives.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.archiveSizeWarning {
                Label("Archive exceeds the 25 MiB advisory threshold. Individual file checks will still run.", systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Upload

    private var uploadCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Upload", icon: "arrow.up.circle.fill")
                Spacer()
                Text("\(model.uploadedPaths.count)/\(model.totalFiles)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundColor(.secondary)
            }

            ProgressView(value: model.progress)
                .tint(Color(uiColor: .systemBlue))

            Text(model.currentAction)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy || model.selectedRepository == nil || model.selectedBranch == nil || model.token.isEmpty)

            Text("Each file is committed separately. Files over 100 MiB are skipped by GitHub’s Contents API limit.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - File List

    private var fileListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("ZIP Contents", icon: "list.bullet.rectangle")
                .padding(.bottom, 10)

            ForEach(Array((model.archive?.files ?? []).enumerated()), id: \.element.id) { index, file in
                HStack(spacing: 12) {
                    Image(systemName: statusIcon(for: file.relativePath))
                        .font(.body)
                        .foregroundColor(statusColor(for: file.relativePath))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.relativePath)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 4)

                    if model.uploadedPaths.contains(file.relativePath) {
                        Text("Sent")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(Color(uiColor: .systemGreen))
                    } else if model.failedPaths[file.relativePath] != nil {
                        Text("Issue")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 10)

                if index < (model.archive?.files.count ?? 0) - 1 {
                    Divider()
                        .padding(.leading, 34)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Verification

    private var verificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Integrity Check", icon: "checkmark.shield.fill")
                Spacer()
                Image(systemName: success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundColor(success ? Color(uiColor: .systemGreen) : .orange)
            }

            Text(success
                  ? "All files are present and match the ZIP."
                  : "Verification found files that need attention.")
                .font(.subheadline.weight(.medium))

            Text("\(model.verifiedCount) of \(model.totalFiles) files verified with SHA-256.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(model.verificationIssues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.path)
                        .font(.caption.weight(.semibold))
                    Text(issue.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Activity

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Activity", icon: "text.alignleft")

            ForEach(Array(model.logs.suffix(12)), id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        Text("ZipBridge · Private by design · iOS 16+")
            .font(.caption2)
            .foregroundColor(Color(uiColor: .tertiaryLabel))
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        Color(uiColor: .secondarySystemGroupedBackground)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundColor(.primary)
            .labelStyle(.titleAndIcon)
    }

    private func selectionRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(Color(uiColor: .systemBlue))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private func statusIcon(for path: String) -> String {
        if model.uploadedPaths.contains(path) { return "checkmark.circle.fill" }
        if model.failedPaths[path] != nil { return "exclamationmark.circle.fill" }
        return "doc"
    }

    private func statusColor(for path: String) -> Color {
        if model.uploadedPaths.contains(path) { return Color(uiColor: .systemGreen) }
        if model.failedPaths[path] != nil { return .orange }
        return .secondary
    }
}

// MARK: - Document Picker (iOS 16 compatible)

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
