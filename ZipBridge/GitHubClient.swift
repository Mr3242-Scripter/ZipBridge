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

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid response."
        case .http(let code, let message): return "GitHub API error (\(code)): \(message)"
        case .invalidRepository: return "Choose a valid owner/repository destination."
        }
    }
}

final class GitHubClient {
    private let token: String
    private let base = URL(string: "https://api.github.com")!
    private let decoder = JSONDecoder()

    init(token: String) { self.token = token }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else { throw GitHubClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ZipBridge-iOS", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubClientError.invalidResponse }
        if !(200...299).contains(http.statusCode) {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw GitHubClientError.http(http.statusCode, payload?["message"] as? String ?? "Request failed.")
        }
        return data
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

    func upload(data: Data, owner: String, repo: String, path: String, branch: String, message: String) async throws {
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
    }

    func remoteTree(owner: String, repo: String, branch: String) async throws -> GitTreeResponse {
        let data = try await request(path: "/repos/\(pathComponent(owner))/\(pathComponent(repo))/git/trees/\(pathComponent(branch))?recursive=1")
        return try decoder.decode(GitTreeResponse.self, from: data)
    }

    func downloadRaw(owner: String, repo: String, branch: String, path: String) async throws -> Data {
        let route = "/repos/\(pathComponent(owner))/\(pathComponent(repo))/contents/\(encodedPath(path))?ref=\(pathComponent(branch))"
        let json = try await request(path: route)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        if let encoded = object?["content"] as? String,
           let decoded = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) {
            return decoded
        }
        guard let download = object?["download_url"] as? String, let url = URL(string: download) else {
            throw GitHubClientError.invalidResponse
        }
        var rawRequest = URLRequest(url: url)
        rawRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        rawRequest.setValue("ZipBridge-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: rawRequest)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GitHubClientError.invalidResponse
        }
        return data
    }
}