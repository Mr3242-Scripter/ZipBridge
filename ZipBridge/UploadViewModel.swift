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

    let advisoryArchiveThreshold: Int64 = 25 * 1024 * 1024
    let maximumGitHubFileSize: Int64 = 100 * 1024 * 1024

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

    func prepareArchive(at url: URL) {
        isBusy = true
        currentAction = "Inspecting ZIP archive…"
        defer { isBusy = false }
        do {
            if let old = archive { try? FileManager.default.removeItem(at: old.extractionDirectory) }
            let extracted = try ArchiveService.inspectAndExtract(url)
            archive = extracted
            uploadedPaths = []
            failedPaths = [:]
            verificationIssues = []
            verifiedCount = 0
            verificationFinished = false
            archiveSizeWarning = extracted.archiveBytes > advisoryArchiveThreshold
            progress = 0
            if archiveSizeWarning {
                append("Archive exceeds the 25 MiB advisory threshold. Continuing with individual file checks.")
            }
            append("Inspected \(extracted.files.count) files (\(ByteCountFormatter.string(fromByteCount: extracted.archiveBytes, countStyle: .file)) compressed).")
            currentAction = "Ready to upload"
        } catch {
            errorMessage = error.localizedDescription
            currentAction = "Archive inspection failed"
        }
    }

    func uploadAndVerify() async {
        guard let archive, let client, let selectedRepository, let selectedBranch else {
            errorMessage = "Choose a ZIP, repository, branch, and valid token."
            return
        }
        isBusy = true
        verificationFinished = false
        defer { isBusy = false }
        let parts = selectedRepository.full_name.split(separator: "/")
        guard parts.count == 2 else { errorMessage = "Invalid repository name."; return }
        let owner = String(parts[0]), repo = String(parts[1])
        let eligible = archive.files.filter { !uploadedPaths.contains($0.relativePath) }
        var finishedThisRun = 0

        for file in eligible {
            currentAction = "Uploading \(file.relativePath)"
            if file.byteCount > maximumGitHubFileSize {
                failedPaths[file.relativePath] = "Exceeds GitHub's 100 MiB Contents API file limit."
                append("Skipped \(file.relativePath): file exceeds 100 MiB.")
                finishedThisRun += 1
                progress = Double(finishedThisRun) / Double(max(eligible.count, 1))
                continue
            }
            do {
                let data = try Data(contentsOf: file.localURL, options: .mappedIfSafe)
                guard Int64(data.count) == file.byteCount else {
                    throw NSError(domain: "ZipBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local extracted file size changed unexpectedly."])
                }
                try await client.upload(
                    data: data,
                    owner: owner,
                    repo: repo,
                    path: file.relativePath,
                    branch: selectedBranch.name,
                    message: "Upload \(file.relativePath) via ZipBridge"
                )
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
        await verifyArchive(archive, client: client, owner: owner, repo: repo, branch: selectedBranch.name)
    }

    func retryFailedUploads() async {
        failedPaths = failedPaths.filter { $0.value.contains("100 MiB") }
        await uploadAndVerify()
    }

    private func verifyArchive(_ archive: ExtractedArchive, client: GitHubClient, owner: String, repo: String, branch: String) async {
        currentAction = "Checking remote repository…"
        verificationIssues = []
        verifiedCount = 0
        do {
            let tree = try await client.remoteTree(owner: owner, repo: repo, branch: branch)
            guard !tree.truncated else {
                throw NSError(domain: "ZipBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "GitHub truncated the repository tree. Full verification cannot be guaranteed."])
            }
            let remote = Dictionary(uniqueKeysWithValues: tree.tree.filter { $0.type == "blob" }.map { ($0.path, $0.size ?? -1) })
            for file in archive.files {
                currentAction = "Verifying \(file.relativePath)"
                guard let remoteSize = remote[file.relativePath] else {
                    verificationIssues.append(VerificationIssue(path: file.relativePath, detail: "Missing from destination repository."))
                    continue
                }
                guard Int64(remoteSize) == file.byteCount else {
                    verificationIssues.append(VerificationIssue(path: file.relativePath, detail: "Size mismatch: expected \(file.byteCount), found \(remoteSize)."))
                    continue
                }
                do {
                    let localData = try Data(contentsOf: file.localURL, options: .mappedIfSafe)
                    let remoteData = try await client.downloadRaw(owner: owner, repo: repo, branch: branch, path: file.relativePath)
                    let localHash = SHA256.hash(data: localData).map { String(format: "%02x", $0) }.joined()
                    let remoteHash = SHA256.hash(data: remoteData).map { String(format: "%02x", $0) }.joined()
                    if localHash == remoteHash && localData.count == remoteData.count {
                        verifiedCount += 1
                    } else {
                        verificationIssues.append(VerificationIssue(path: file.relativePath, detail: "SHA-256 or byte-count mismatch."))
                    }
                } catch {
                    verificationIssues.append(VerificationIssue(path: file.relativePath, detail: "Could not read back file: \(error.localizedDescription)"))
                }
            }
            verificationFinished = true
            if verificationIssues.isEmpty && verifiedCount == archive.files.count {
                currentAction = "All files verified"
                append("Integrity verification passed: \(verifiedCount)/\(archive.files.count) files match.")
            } else {
                currentAction = "Verification needs attention"
                append("Verification completed with \(verificationIssues.count) issue(s); \(verifiedCount)/\(archive.files.count) files match.")
            }
        } catch {
            verificationFinished = false
            currentAction = "Verification failed"
            errorMessage = error.localizedDescription
            append("Verification could not be completed: \(error.localizedDescription)")
        }
    }

    func append(_ message: String) {
        logs.append(message)
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
}