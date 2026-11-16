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

## Nightly unsigned IPA releases

The GitHub Actions workflow at `.github/workflows/nightly-ipa-release.yml` runs every day at **03:00 UTC** and can also be started manually from **Actions → Nightly IPA Release → Run workflow**.

It builds the app for physical iOS devices **without an Apple signing certificate or provisioning profile**, packages the app as an unsigned IPA, calculates its SHA-256 checksum, and uploads both files to a GitHub prerelease.

### Release detection and uploads

- The workflow uses one release tag per UTC day: `nightly-YYYYMMDD`.
- Before publishing, it checks whether that day's release already exists.
- If it does not exist, the workflow creates a new prerelease.
- If it already exists (for example, when the workflow is rerun), the workflow reuses it and replaces the previous IPA/checksum assets.
- The release contains `ZipBridge-unsigned-<build number>.ipa` and `SHA256SUMS.txt`.

No Apple Developer account, certificate, provisioning profile, or signing secrets are required. The workflow uses the repository's built-in GitHub Actions token to create and upload release assets.

**Installation note:** the IPA is intentionally unsigned. It is suitable for sharing as a build artifact, but it cannot be installed directly on a standard iPhone as-is. It must be signed with a suitable certificate and provisioning profile before installation. An unsigned build is not an App Store-distributable IPA.
