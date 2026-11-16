import Foundation
import Combine
import CryptoKit
import Security

struct VerificationIssue: Identifiable {
    let path: String
    let detail: String
    var id: String { path }
}

enum KeychainStore {
    private static let service = "com.mr3242.ZipBridge"
    private static let account = "github-token"

    static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class UploadViewModel: ObservableObject {
    @Published var token = KeychainStore.readToken() ?? ""
    @Published var repositories: [GitHubRepository] = []
    @Published var branches: [GitHubBranch] = []
    @Published var selectedRepository: GitHubRepository?
    @Published var selectedBranch: GitHubBranch?
    @Published var archive: ExtractedArchive?
    @Published var isBusy = false
    @Published var progress = 0.0
    @Published var currentAction = "Ready"
    @Published var logs: [String] = []
    @Published var uploadedPaths = Set<String>()
    @Published var failedPaths: [String: String] = [:]
    @Published var verificationIssues: [VerificationIssue] = []
    @Published var verifiedCount = 0
    @Published var verificationFinished = false
    @Published var archiveSizeWarning = false
    @Published var errorMessage: String?

    private var workTask: Task<Void, Never>?

    let advisoryArchiveThreshold: Int64 = 25 * 1024 * 1024
    let maximumGitHubFileSize: Int64 = 100 * 1024 * 1024
    /// Hard ceiling: batch total must stay strictly under 25,000,000 bytes (25 MB).
    let fastModeBatchLimit: Int64 = 25_000_000

    var client: GitHubClient? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : GitHubClient(token: trimmed)
    }

    var totalFiles: Int { archive?.files.count ?? 0 }
    var completedFiles: Int { uploadedPaths.count }

    func saveToken() {
        do {
            try KeychainStore.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
            append("GitHub token saved securely in Keychain.")
        } catch {
            errorMessage = "Could not save token: \(error.localizedDescription)"
        }
    }

    func forgetToken() {
        KeychainStore.deleteToken()
        token = ""
        repositories = []
        branches = []
        selectedRepository = nil
        selectedBranch = nil
        append("Stored token removed from this device.")
    }

    func loadRepositories() async {
        guard let client else { errorMessage = "Enter a GitHub token first."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            repositories = try await client.repositories()
            append("Loaded \(repositories.count) accessible repositories.")
            if let selectedRepository, !repositories.contains(selectedRepository) {
                self.selectedRepository = nil
                selectedBranch = nil
                branches = []
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseRepository(_ repository: GitHubRepository) async {
        guard let client else { return }
        selectedRepository = repository
        selectedBranch = nil
        branches = []
        isBusy = true
        defer { isBusy = false }
        do {
            branches = try await client.branches(owner: ownerName, repo: repoName)
            selectedBranch = branches.first(where: { $0.name == repository.default_branch }) ?? branches.first
            append("Loaded branches for \(repository.full_name).")
        } catch { errorMessage = error.localizedDescription }
    }

    private var ownerName: String { selectedRepository?.full_name.split(separator: "/").first.map(String.init) ?? "" }
    private var repoName: String { selectedRepository?.full_name.split(separator: "/").last.map(String.init) ?? "" }

    func prepareArchive(at url: URL, protectionEnabled: Bool = true) async {
        isBusy = true
        currentAction = "Inspecting ZIP archive…"
        defer { isBusy = false }
        do {
            let extracted = try await Task.detached(priority: .userInitiated) {
                try ArchiveService.inspectAndExtract(url, protectionEnabled: protectionEnabled)
            }.value
            if let old = archive { try? FileManager.default.removeItem(at: old.extractionDirectory) }
            archive = extracted
            uploadedPaths = []
            failedPaths = [:]
            verificationIssues = []
            verifiedCount = 0
            verificationFinished = false
            archiveSizeWarning = extracted.archiveBytes > advisoryArchiveThreshold
            progress = 0
            if archiveSizeWarning {
                append("Archive exceeds the 25 MiB advisory threshold.")
            }
            append("Inspected \(extracted.files.count) files (\(ByteCountFormatter.string(fromByteCount: extracted.archiveBytes, countStyle: .file)) compressed).")
            currentAction = "Ready to upload"
        } catch {
            errorMessage = error.localizedDescription
            currentAction = "Archive inspection failed"
        }
    }

    private func makeBatches(from files: [ArchiveFile], limitBytes: Int64) -> [[ArchiveFile]] {
        var batches: [[ArchiveFile]] = []
        var current: [ArchiveFile] = []
        var currentSize: Int64 = 0

        for file in files {
            if file.byteCount >= limitBytes {
                if !current.isEmpty {
                    batches.append(current)
                    current = []
                    currentSize = 0
                }
                batches.append([file])
                continue
            }

            if !current.isEmpty && currentSize + file.byteCount >= limitBytes {
                batches.append(current)
                current = [file]
                currentSize = file.byteCount
            } else {
                current.append(file)
                currentSize += file.byteCount
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    func cancelUpload() {
        workTask?.cancel()
        workTask = nil
        BackgroundKeepAlive.shared.stopAll()
        isBusy = false
        currentAction = "Cancelled"
        append("Upload cancelled by user.")
    }

    func startUploadAndVerify(
        fastMode: Bool = false,
        backgroundAudio: Bool = false,
        backgroundLocation: Bool = false
    ) {
        workTask?.cancel()
        workTask = Task { [weak self] in
            await self?.uploadAndVerify(
                fastMode: fastMode,
                backgroundAudio: backgroundAudio,
                backgroundLocation: backgroundLocation
            )
        }
    }

    func uploadAndVerify(
        fastMode: Bool = false,
        backgroundAudio: Bool = false,
        backgroundLocation: Bool = false
    ) async {
        guard let archive, let client, let selectedRepository, let selectedBranch else {
            errorMessage = "Choose a ZIP, repository, branch, and valid token."
            return
        }
        isBusy = true
        verificationFinished = false
        BackgroundKeepAlive.shared.apply(
            audioEnabled: backgroundAudio,
            locationEnabled: backgroundLocation,
            uploading: true
        )
        defer {
            BackgroundKeepAlive.shared.stopAll()
            isBusy = false
            workTask = nil
        }

        let parts = selectedRepository.full_name.split(separator: "/")
        guard parts.count == 2 else { errorMessage = "Invalid repository name."; return }
        let owner = String(parts[0]), repo = String(parts[1])
        let eligible = archive.files.filter { !uploadedPaths.contains($0.relativePath) }

        if Task.isCancelled {
            currentAction = "Cancelled"
            return
        }

        if fastMode {
            append("Fast Mode on — each under-25 MB batch becomes one Git commit (parallel blobs).")
            await uploadFast(eligible, client: client, owner: owner, repo: repo, branch: selectedBranch.name)
        } else {
            await uploadSequential(eligible, client: client, owner: owner, repo: repo, branch: selectedBranch.name)
        }

        if Task.isCancelled {
            currentAction = "Cancelled"
            append("Upload cancelled by user.")
            return
        }

        await verifyArchive(
            archive,
            client: client,
            owner: owner,
            repo: repo,
            branch: selectedBranch.name,
            fastMode: fastMode
        )
    }

    private func uploadSequential(
        _ eligible: [ArchiveFile],
        client: GitHubClient,
        owner: String,
        repo: String,
        branch: String
    ) async {
        var finishedThisRun = 0
        for file in eligible {
            if Task.isCancelled { return }
            currentAction = "Uploading \(file.relativePath)"
            if file.byteCount > maximumGitHubFileSize {
                failedPaths[file.relativePath] = "Exceeds GitHub's 100 MiB Contents API file limit."
                append("Skipped \(file.relativePath): file exceeds 100 MiB.")
                finishedThisRun += 1
                progress = Double(finishedThisRun) / Double(max(eligible.count, 1))
                continue
            }
            do {
                try await uploadOne(file, client: client, owner: owner, repo: repo, branch: branch)
                uploadedPaths.insert(file.relativePath)
                failedPaths.removeValue(forKey: file.relativePath)
                append("Uploaded \(file.relativePath) — committed.")
            } catch {
                failedPaths[file.relativePath] = error.localizedDescription
                append("Upload failed for \(file.relativePath): \(error.localizedDescription)")
                currentAction = "Paused after upload failure"
                break
            }
            finishedThisRun += 1
            progress = Double(finishedThisRun) / Double(max(eligible.count, 1))
        }
    }

    private func uploadFast(
        _ eligible: [ArchiveFile],
        client: GitHubClient,
        owner: String,
        repo: String,
        branch: String
    ) async {
        let batches = makeBatches(from: eligible, limitBytes: fastModeBatchLimit)
        var finishedThisRun = 0
        let total = max(eligible.count, 1)

        for (batchIndex, batch) in batches.enumerated() {
            if Task.isCancelled { return }
            let batchBytes = batch.reduce(Int64(0)) { $0 + $1.byteCount }
            currentAction = "Fast upload batch \(batchIndex + 1)/\(batches.count) (\(batch.count) files, \(ByteCountFormatter.string(fromByteCount: batchBytes, countStyle: .file)))"

            var workable: [ArchiveFile] = []
            for file in batch {
                if file.byteCount > maximumGitHubFileSize {
                    failedPaths[file.relativePath] = "Exceeds GitHub's 100 MiB file limit."
                    append("Skipped \(file.relativePath): file exceeds 100 MiB.")
                    finishedThisRun += 1
                    progress = Double(finishedThisRun) / Double(total)
                } else {
                    workable.append(file)
                }
            }
            guard !workable.isEmpty else { continue }

            do {
                var payload: [(path: String, data: Data)] = []
                for file in workable {
                    let data = try Data(contentsOf: file.localURL, options: .mappedIfSafe)
                    guard Int64(data.count) == file.byteCount else {
                        throw NSError(
                            domain: "ZipBridge",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Local extracted file size changed for \(file.relativePath)."]
                        )
                    }
                    payload.append((file.relativePath, data))
                }

                try await client.uploadBatch(
                    files: payload,
                    owner: owner,
                    repo: repo,
                    branch: branch,
                    message: "ZipBridge fast batch \(batchIndex + 1)/\(batches.count) (\(workable.count) files)"
                )

                for file in workable {
                    uploadedPaths.insert(file.relativePath)
                    failedPaths.removeValue(forKey: file.relativePath)
                    append("Uploaded \(file.relativePath) — batch commit.")
                    finishedThisRun += 1
                    progress = Double(finishedThisRun) / Double(total)
                }
            } catch {
                for file in workable {
                    failedPaths[file.relativePath] = error.localizedDescription
                    append("Upload failed for \(file.relativePath): \(error.localizedDescription)")
                    finishedThisRun += 1
                    progress = Double(finishedThisRun) / Double(total)
                }
                currentAction = "Paused after upload failure"
                break
            }
        }
    }

    private func uploadOne(
        _ file: ArchiveFile,
        client: GitHubClient,
        owner: String,
        repo: String,
        branch: String
    ) async throws {
        let data = try Data(contentsOf: file.localURL, options: .mappedIfSafe)
        guard Int64(data.count) == file.byteCount else {
            throw NSError(
                domain: "ZipBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Local extracted file size changed unexpectedly."]
            )
        }
        try await client.upload(
            data: data,
            owner: owner,
            repo: repo,
            path: file.relativePath,
            branch: branch,
            message: "Upload \(file.relativePath) via ZipBridge"
        )
    }

    func retryFailedUploads(
        fastMode: Bool = false,
        backgroundAudio: Bool = false,
        backgroundLocation: Bool = false
    ) {
        failedPaths = failedPaths.filter { $0.value.contains("100 MiB") }
        startUploadAndVerify(
            fastMode: fastMode,
            backgroundAudio: backgroundAudio,
            backgroundLocation: backgroundLocation
        )
    }

    private func verifyArchive(
        _ archive: ExtractedArchive,
        client: GitHubClient,
        owner: String,
        repo: String,
        branch: String,
        fastMode: Bool
    ) async {
        currentAction = "Checking remote repository…"
        verificationIssues = []
        verifiedCount = 0
        do {
            let tree = try await client.remoteTree(owner: owner, repo: repo, branch: branch)
            guard !tree.truncated else {
                throw NSError(
                    domain: "ZipBridge",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub truncated the repository tree. Full verification cannot be guaranteed."]
                )
            }
            let remote = Dictionary(
                uniqueKeysWithValues: tree.tree.filter { $0.type == "blob" }.map { ($0.path, $0.size ?? -1) }
            )

            if fastMode {
                await verifyFast(archive.files, remote: remote, client: client, owner: owner, repo: repo, branch: branch)
            } else {
                await verifySequential(archive.files, remote: remote, client: client, owner: owner, repo: repo, branch: branch)
            }

            if Task.isCancelled { return }

            verificationFinished = true
            if verificationIssues.isEmpty && verifiedCount == archive.files.count {
                currentAction = "All files verified"
                append("Integrity verification passed: \(verifiedCount)/\(archive.files.count) files match.")
            } else {
                currentAction = "Verification needs attention"
                append("Verification completed with \(verificationIssues.count) issue(s); \(verifiedCount)/\(archive.files.count) files match.")
            }
        } catch {
            if Task.isCancelled { return }
            verificationFinished = false
            currentAction = "Verification failed"
            errorMessage = error.localizedDescription
            append("Verification could not be completed: \(error.localizedDescription)")
        }
    }

    private func verifySequential(
        _ files: [ArchiveFile],
        remote: [String: Int],
        client: GitHubClient,
        owner: String,
        repo: String,
        branch: String
    ) async {
        for file in files {
            if Task.isCancelled { return }
            currentAction = "Verifying \(file.relativePath)"
            if let issue = await verifyOne(file, remote: remote, client: client, owner: owner, repo: repo, branch: branch) {
                verificationIssues.append(issue)
            } else {
                verifiedCount += 1
            }
        }
    }

    private func verifyFast(
        _ files: [ArchiveFile],
        remote: [String: Int],
        client: GitHubClient,
        owner: String,
        repo: String,
        branch: String
    ) async {
        let batches = makeBatches(from: files, limitBytes: fastModeBatchLimit)

        for (batchIndex, batch) in batches.enumerated() {
            if Task.isCancelled { return }
            let batchBytes = batch.reduce(Int64(0)) { $0 + $1.byteCount }
            currentAction = "Fast verify batch \(batchIndex + 1)/\(batches.count) (\(batch.count) files, \(ByteCountFormatter.string(fromByteCount: batchBytes, countStyle: .file)))"

            await withTaskGroup(of: (String, VerificationIssue?).self) { group in
                for file in batch {
                    group.addTask {
                        let issue = await self.verifyOne(
                            file,
                            remote: remote,
                            client: client,
                            owner: owner,
                            repo: repo,
                            branch: branch
                        )
                        return (file.relativePath, issue)
                    }
                }

                for await (_, issue) in group {
                    if let issue {
                        verificationIssues.append(issue)
                    } else {
                        verifiedCount += 1
                    }
                }
            }
        }
    }

    private func verifyOne(
        _ file: ArchiveFile,
        remote: [String: Int],
        client: GitHubClient,
        owner: String,
        repo: String,
        branch: String
    ) async -> VerificationIssue? {
        guard let remoteSize = remote[file.relativePath] else {
            return VerificationIssue(path: file.relativePath, detail: "Missing from destination repository.")
        }
        guard Int64(remoteSize) == file.byteCount else {
            return VerificationIssue(
                path: file.relativePath,
                detail: "Size mismatch: expected \(file.byteCount), found \(remoteSize)."
            )
        }
        do {
            let localData = try Data(contentsOf: file.localURL, options: .mappedIfSafe)
            let remoteData = try await client.downloadRaw(owner: owner, repo: repo, branch: branch, path: file.relativePath)
            let localHash = SHA256.hash(data: localData).map { String(format: "%02x", $0) }.joined()
            let remoteHash = SHA256.hash(data: remoteData).map { String(format: "%02x", $0) }.joined()
            if localHash == remoteHash && localData.count == remoteData.count {
                return nil
            }
            return VerificationIssue(path: file.relativePath, detail: "SHA-256 or byte-count mismatch.")
        } catch {
            return VerificationIssue(
                path: file.relativePath,
                detail: "Could not read back file: \(error.localizedDescription)"
            )
        }
    }

    func append(_ message: String) {
        logs.append(message)
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
}
