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

    /// When `protectionEnabled` is `false` the 2 GiB expanded-size limit is skipped
    /// and some path checks are relaxed. The final confinement to the temporary
    /// extraction directory is always enforced so files cannot escape the app sandbox.
    static func inspectAndExtract(_ archiveURL: URL, protectionEnabled: Bool = true) throws -> ExtractedArchive {
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

                // Basic emptiness / null-byte checks always apply
                guard !raw.isEmpty, !raw.contains("\0") else {
                    if protectionEnabled {
                        throw ArchiveServiceError.unsafeEntry(raw)
                    }
                    continue
                }

                // Path safety (absolute paths, backslashes, parent traversal, drive letters)
                if protectionEnabled {
                    guard !raw.hasPrefix("/"),
                          !raw.contains("\\"),
                          !raw.contains("..") else {
                        throw ArchiveServiceError.unsafeEntry(raw)
                    }
                }

                // Normalize components
                let rawComponents = raw.split(separator: "/", omittingEmptySubsequences: true)
                guard !rawComponents.isEmpty else {
                    if protectionEnabled {
                        throw ArchiveServiceError.unsafeEntry(raw)
                    }
                    continue
                }

                // When protection is on, reject parent traversal and drive letters
                if protectionEnabled {
                    guard !rawComponents.contains(".."),
                          !rawComponents[0].contains(":") else {
                        throw ArchiveServiceError.unsafeEntry(raw)
                    }
                }

                let components = rawComponents.filter { $0 != "." }
                guard !components.isEmpty else {
                    if protectionEnabled {
                        throw ArchiveServiceError.unsafeEntry(raw)
                    }
                    continue
                }

                // Symlinks and non-file/dir entries
                if protectionEnabled {
                    guard entry.type != .symlink else {
                        throw ArchiveServiceError.unsupportedEntry(raw)
                    }
                    guard entry.type == .file || entry.type == .directory else {
                        throw ArchiveServiceError.unsupportedEntry(raw)
                    }
                } else {
                    // Still skip pure directories and try to extract only regular files
                    if entry.type == .directory { continue }
                    if entry.type == .symlink { continue } // still skip symlinks for safety
                }

                let normalized = components.joined(separator: "/")
                if entry.type == .directory { continue }

                if protectionEnabled {
                    guard seen.insert(normalized).inserted else {
                        throw ArchiveServiceError.unsafeEntry("Duplicate path: \(normalized)")
                    }
                } else {
                    // Allow duplicates when unprotected (last one wins)
                    _ = seen.insert(normalized)
                }

                let size = Int64(entry.uncompressedSize)
                guard size >= 0 else {
                    throw ArchiveServiceError.expansionLimit
                }

                // Size limit only when protection is enabled
                if protectionEnabled {
                    guard size <= maximumExpandedBytes,
                          expanded <= maximumExpandedBytes - size else {
                        throw ArchiveServiceError.expansionLimit
                    }
                }
                expanded += size

                let destination = root.appendingPathComponent(normalized)
                let standardized = destination.standardizedFileURL.path
                let rootPrefix = root.standardizedFileURL.path + "/"

                // HARD confinement – always enforced, even when protection is off
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
