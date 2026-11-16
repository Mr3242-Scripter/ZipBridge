import Foundation
import ZIPFoundation

struct ArchiveFile: Identifiable, Hashable {
    let relativePath: String
    let localURL: URL
    let byteCount: Int64
    var id: String { relativePath }
}

struct ExtractedArchive {
    let sourceName: String
    let archiveBytes: Int64
    let files: [ArchiveFile]
    let extractionDirectory: URL
}

enum ArchiveServiceError: LocalizedError {
    case invalidArchive
    case unsafeEntry(String)
    case unsupportedEntry(String)
    case expansionLimit
    case emptyArchive

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "This file is not a readable ZIP archive."
        case .unsafeEntry(let path): return "Unsafe archive path rejected: \(path)"
        case .unsupportedEntry(let path): return "Unsupported archive entry rejected: \(path)"
        case .expansionLimit: return "The archive expands beyond the 2 GiB safety limit."
        case .emptyArchive: return "The ZIP contains no regular files."
        }
    }
}

enum ArchiveService {
    static let maximumExpandedBytes: Int64 = 2 * 1024 * 1024 * 1024

    static func inspectAndExtract(_ archiveURL: URL) throws -> ExtractedArchive {
        let accessed = archiveURL.startAccessingSecurityScopedResource()
        defer { if accessed { archiveURL.stopAccessingSecurityScopedResource() } }

        let archiveBytes = Int64((try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipBridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            guard let archive = Archive(url: archiveURL, accessMode: .read) else {
                throw ArchiveServiceError.invalidArchive
            }
            var files: [ArchiveFile] = []
            var expanded: Int64 = 0
            var seen = Set<String>()

            for entry in archive {
                let raw = entry.path
                guard !raw.isEmpty,
                      !raw.hasPrefix("/"),
                      !raw.contains("\\"),
                      !raw.contains("\0") else {
                    throw ArchiveServiceError.unsafeEntry(raw)
                }
                let components = raw.split(separator: "/", omittingEmptySubsequences: true)
                guard !components.isEmpty,
                      !components.contains(".."),
                      !components.contains("."),
                      !components[0].contains(":") else {
                    throw ArchiveServiceError.unsafeEntry(raw)
                }
                guard entry.type != .symlink else {
                    throw ArchiveServiceError.unsupportedEntry(raw)
                }
                guard entry.type == .file || entry.type == .directory else {
                    throw ArchiveServiceError.unsupportedEntry(raw)
                }
                let normalized = components.joined(separator: "/")
                if entry.type == .directory { continue }
                guard seen.insert(normalized).inserted else {
                    throw ArchiveServiceError.unsafeEntry("Duplicate path: \(normalized)")
                }
                let size = Int64(entry.uncompressedSize)
                guard size >= 0, expanded <= maximumExpandedBytes - size else {
                    throw ArchiveServiceError.expansionLimit
                }
                expanded += size

                let destination = root.appendingPathComponent(normalized)
                let standardized = destination.standardizedFileURL.path
                let rootPrefix = root.standardizedFileURL.path + "/"
                guard standardized.hasPrefix(rootPrefix) else {
                    throw ArchiveServiceError.unsafeEntry(raw)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try archive.extract(entry, to: destination)
                files.append(ArchiveFile(relativePath: normalized, localURL: destination, byteCount: size))
            }

            guard !files.isEmpty else { throw ArchiveServiceError.emptyArchive }
            return ExtractedArchive(
                sourceName: archiveURL.lastPathComponent,
                archiveBytes: archiveBytes,
                files: files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
                extractionDirectory: root
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}