# ZipBridge

ZipBridge is a native SwiftUI iOS app (minimum iOS 16) for importing ZIP archives and uploading their extracted files to a selected GitHub repository.

## Features
- Import ZIP archives through the iOS Files picker.
- Enter a classic or fine-grained GitHub Personal Access Token; store it in iOS Keychain.
- Load repositories accessible to the token, then choose a repository and branch.
- Inspect and extract ZIP files while rejecting absolute paths, traversal paths, symlinks, duplicate paths, and unsupported entries.
- 25 MiB archive-size threshold is advisory. If exceeded, extraction continues and each file is checked independently.
- Upload regular files sequentially, one GitHub Contents API commit per file, preserving paths.
- Update existing destination files by retrieving and supplying their current blob SHA.
- Skip and report individual files above GitHub's 100 MiB Contents API limit.
- Fetch the remote recursive Git tree after upload; compare every expected path and byte count, then read back contents and compare SHA-256 digests.
- Report missing, mismatched, unreadable, or skipped files. The UI reports success only when every ZIP file is present and byte-for-byte verified.

## Build
Open `ZipBridge.xcodeproj` in Xcode 15 or later, select a development team under Signing & Capabilities, and build for iOS 16+. ZIPFoundation is resolved through Swift Package Manager.

## GitHub token permissions
Use a token with repository access and **Contents: Read and write** permission. Fine-grained tokens also need Metadata read access. The token is stored locally in Keychain; it is not embedded in the app or written to logs.

## Upload details
The archive-size threshold does not reject a ZIP. Files are uploaded one at a time; the next upload starts only after GitHub confirms the previous request. Every successful file upload creates its own commit. GitHub's Contents API has a 100 MiB per-file limit, and repository branch protection or token permissions may prevent writes.