import Foundation

struct GitHubRepository: Decodable, Identifiable, Hashable {
    let id: Int
    let full_name: String
    let default_branch: String
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case id, full_name, default_branch
        case isPrivate = "private"
    }
}

struct GitHubBranch: Decodable, Identifiable, Hashable {
    struct Commit: Decodable, Hashable { let sha: String }
    let name: String
    let commit: Commit
    var id: String { name }
}

struct GitHubContent: Decodable { let sha: String? }

struct GitTreeResponse: Decodable {
    struct Item: Decodable {
        let path: String
        let type: String
        let size: Int?
    }
    let tree: [Item]
    let truncated: Bool
}

enum GitHubClientError: LocalizedError {
    case invalidResponse
    case http(Int, String)
    case invalidRepository
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid response."
        case .http(let code, let message): return "GitHub API error (\(code)): \(message)"
        case .invalidRepository: return "Choose a valid owner/repository destination."
        case .timedOut: return "The request timed out. Try again, or use smaller batches."
        }
    }
}

final class GitHubClient {
    private let token: String
    private let base = URL(string: "https://api.github.com")!
    private let decoder = JSONDecoder()
    private let session: URLSession

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.default
        // Large base64 payloads + background can need long windows.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config)
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else { throw GitHubClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = body == nil ? 60 : 180
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ZipBridge-iOS", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GitHubClientError.invalidResponse }
            if !(200...299).contains(http.statusCode) {
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw GitHubClientError.http(http.statusCode, payload?["message"] as? String ?? "Request failed.")
            }
            return data
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw GitHubClientError.timedOut
        }
    }

    private func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func encodedPath(_ path: String) -> String {
        path.split(separator: "/").map { pathComponent(String($0)) }.joined(separator: "/")
    }

    func repositories() async throws -> [GitHubRepository] {
        var result: [GitHubRepository] = []
        var page = 1
        while true {
            let data = try await request(path: "/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member&page=\(page)")
            let batch = try decoder.decode([GitHubRepository].self, from: data)
            result.append(contentsOf: batch)
            if batch.count < 100 { return result }
            page += 1
        }
    }

    func branches(owner: String, repo: String) async throws -> [GitHubBranch] {
        var result: [GitHubBranch] = []
        var page = 1
        while true {
            let data = try await request(path: "/repos/\(pathComponent(owner))/\(pathComponent(repo))/branches?per_page=100&page=\(page)")
            let batch = try decoder.decode([GitHubBranch].self, from: data)
            result.append(contentsOf: batch)
            if batch.count < 100 { return result }
            page += 1
        }
    }

    func existingSHA(owner: String, repo: String, path: String, branch: String) async throws -> String? {
        let ref = pathComponent(branch)
        let route = "/repos/\(pathComponent(owner))/\(pathComponent(repo))/contents/\(encodedPath(path))?ref=\(ref)"
        do {
            let data = try await request(path: route)
            return try decoder.decode(GitHubContent.self, from: data).sha
        } catch GitHubClientError.http(let code, _) where code == 404 {
            return nil
        }
    }

    /// Single-file upload via Contents API, with retries on conflict / timeout.
    func upload(data: Data, owner: String, repo: String, path: String, branch: String, message: String) async throws {
        var lastError: Error?
        for attempt in 1...5 {
            do {
                let sha = try await existingSHA(owner: owner, repo: repo, path: path, branch: branch)
                var payload: [String: Any] = [
                    "message": message,
                    "content": data.base64EncodedString(),
                    "branch": branch
                ]
                if let sha { payload["sha"] = sha }
                let body = try JSONSerialization.data(withJSONObject: payload)
                let route = "/repos/\(pathComponent(owner))/\(pathComponent(repo))/contents/\(encodedPath(path))"
                _ = try await request(path: route, method: "PUT", body: body)
                return
            } catch GitHubClientError.http(let code, let message) where code == 409 || code == 400 || code == 422 {
                lastError = GitHubClientError.http(code, message)
                if attempt < 5 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                    continue
                }
            } catch GitHubClientError.timedOut {
                lastError = GitHubClientError.timedOut
                if attempt < 5 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    continue
                }
            } catch {
                throw error
            }
        }
        if let lastError { throw lastError }
    }

    // MARK: - Git Data API (true multi-file commit for Fast Mode)

    private struct BlobResponse: Decodable { let sha: String }
    private struct TreeResponse: Decodable { let sha: String }
    private struct CommitResponse: Decodable { let sha: String }
    private struct RefResponse: Decodable {
        struct Object: Decodable { let sha: String }
        let object: Object
    }

    /// Creates one commit containing all provided files.
    /// Blobs are uploaded with limited concurrency to avoid timeouts and 400s.
    func uploadBatch(
        files: [(path: String, data: Data)],
        owner: String,
        repo: String,
        branch: String,
        message: String
    ) async throws {
        guard !files.isEmpty else { return }

        let o = pathComponent(owner)
        let r = pathComponent(repo)
        let refName = pathComponent(branch)

        // 1. Current branch tip
        let refData = try await request(path: "/repos/\(o)/\(r)/git/ref/heads/\(refName)")
        let headSHA = try decoder.decode(RefResponse.self, from: refData).object.sha

        // 2. Create blobs (max 4 at a time)
        var blobSHAs: [(path: String, sha: String)] = []
        blobSHAs.reserveCapacity(files.count)
        let maxConcurrent = 4
        var index = 0
        while index < files.count {
            let end = min(index + maxConcurrent, files.count)
            let slice = Array(files[index..<end])
            try await withThrowingTaskGroup(of: (String, String).self) { group in
                for file in slice {
                    group.addTask {
                        try await self.createBlob(owner: o, repo: r, data: file.data, path: file.path)
                    }
                }
                for try await item in group {
                    blobSHAs.append(item)
                }
            }
            index = end
        }

        // 3. Create tree from base + new blobs
        let treeItems: [[String: Any]] = blobSHAs.map { entry in
            [
                "path": entry.path,
                "mode": "100644",
                "type": "blob",
                "sha": entry.sha
            ]
        }
        let treePayload: [String: Any] = [
            "base_tree": headSHA,
            "tree": treeItems
        ]
        let treeBody = try JSONSerialization.data(withJSONObject: treePayload)
        let treeData = try await request(path: "/repos/\(o)/\(r)/git/trees", method: "POST", body: treeBody)
        let treeSHA = try decoder.decode(TreeResponse.self, from: treeData).sha

        // 4. Create commit
        let commitPayload: [String: Any] = [
            "message": message,
            "tree": treeSHA,
            "parents": [headSHA]
        ]
        let commitBody = try JSONSerialization.data(withJSONObject: commitPayload)
        let commitData = try await request(path: "/repos/\(o)/\(r)/git/commits", method: "POST", body: commitBody)
        let commitSHA = try decoder.decode(CommitResponse.self, from: commitData).sha

        // 5. Move branch ref (retry once on conflict)
        try await moveRef(owner: o, repo: r, refName: refName, commitSHA: commitSHA, treeItems: treeItems, message: message)
    }

    private func createBlob(owner: String, repo: String, data: Data, path: String) async throws -> (String, String) {
        var lastError: Error?
        for attempt in 1...4 {
            do {
                let payload: [String: Any] = [
                    "content": data.base64EncodedString(),
                    "encoding": "base64"
                ]
                let body = try JSONSerialization.data(withJSONObject: payload)
                let response = try await request(
                    path: "/repos/\(owner)/\(repo)/git/blobs",
                    method: "POST",
                    body: body
                )
                let sha = try decoder.decode(BlobResponse.self, from: response).sha
                return (path, sha)
            } catch GitHubClientError.timedOut {
                lastError = GitHubClientError.timedOut
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            } catch GitHubClientError.http(let code, let message) where code == 400 || code == 502 || code == 503 {
                lastError = GitHubClientError.http(code, message)
                try await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
            }
        }
        throw lastError ?? GitHubClientError.timedOut
    }

    private func moveRef(
        owner: String,
        repo: String,
        refName: String,
        commitSHA: String,
        treeItems: [[String: Any]],
        message: String
    ) async throws {
        let refPayload: [String: Any] = ["sha": commitSHA, "force": false]
        let refBody = try JSONSerialization.data(withJSONObject: refPayload)
        do {
            _ = try await request(path: "/repos/\(owner)/\(repo)/git/refs/heads/\(refName)", method: "PATCH", body: refBody)
        } catch GitHubClientError.http(let code, _) where code == 422 || code == 409 || code == 400 {
            let refData2 = try await request(path: "/repos/\(owner)/\(repo)/git/ref/heads/\(refName)")
            let head2 = try decoder.decode(RefResponse.self, from: refData2).object.sha
            let treePayload2: [String: Any] = ["base_tree": head2, "tree": treeItems]
            let treeBody2 = try JSONSerialization.data(withJSONObject: treePayload2)
            let treeData2 = try await request(path: "/repos/\(owner)/\(repo)/git/trees", method: "POST", body: treeBody2)
            let treeSHA2 = try decoder.decode(TreeResponse.self, from: treeData2).sha
            let commitPayload2: [String: Any] = [
                "message": message,
                "tree": treeSHA2,
                "parents": [head2]
            ]
            let commitBody2 = try JSONSerialization.data(withJSONObject: commitPayload2)
            let commitData2 = try await request(path: "/repos/\(owner)/\(repo)/git/commits", method: "POST", body: commitBody2)
            let commitSHA2 = try decoder.decode(CommitResponse.self, from: commitData2).sha
            let refPayload2: [String: Any] = ["sha": commitSHA2, "force": false]
            let refBody2 = try JSONSerialization.data(withJSONObject: refPayload2)
            _ = try await request(path: "/repos/\(owner)/\(repo)/git/refs/heads/\(refName)", method: "PATCH", body: refBody2)
        }
    }

    func remoteTree(owner: String, repo: String, branch: String) async throws -> GitTreeResponse {
        let data = try await request(path: "/repos/\(pathComponent(owner))/\(pathComponent(repo))/git/trees/\(pathComponent(branch))?recursive=1")
        return try decoder.decode(GitTreeResponse.self, from: data)
    }

    func downloadRaw(owner: String, repo: String, branch: String, path: String) async throws -> Data {
        let route = "/repos/\(pathComponent(owner))/\(pathComponent(repo))/contents/\(encodedPath(path))?ref=\(pathComponent(branch))"
        let json = try await request(path: route)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        if let encoded = object?["content"] as? String, !encoded.isEmpty,
           let decoded = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) {
            return decoded
        }
        guard let download = object?["download_url"] as? String, let url = URL(string: download) else {
            throw GitHubClientError.invalidResponse
        }
        var rawRequest = URLRequest(url: url)
        rawRequest.timeoutInterval = 180
        rawRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        rawRequest.setValue("ZipBridge-iOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: rawRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw GitHubClientError.invalidResponse
            }
            return data
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw GitHubClientError.timedOut
        }
    }
}
