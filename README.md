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

## Nightly signed IPA releases

The repository has a GitHub Actions workflow at `.github/workflows/nightly-ipa-release.yml`. It runs every day at **03:00 UTC** and can also be started manually from **Actions → Nightly IPA Release → Run workflow**.

The workflow archives the app for physical iOS devices, exports a signed **Ad Hoc IPA**, calculates its SHA-256 checksum, and publishes both files as a timestamped GitHub **prerelease** (for example, `nightly-202611170300`). Each nightly build gets a unique tag and release.

### One-time Apple signing setup

An IPA that can be installed on an iPhone must be signed. Before the first nightly run, add these four **Actions secrets** in the repository's Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `IOS_DISTRIBUTION_CERTIFICATE_P12_BASE64` | Base64-encoded Apple Distribution certificate exported as a password-protected `.p12` file |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used when exporting that `.p12` |
| `IOS_AD_HOC_PROFILE_BASE64` | Base64-encoded Ad Hoc provisioning profile for `com.mr3242.ZipBridge` |
| `IOS_TEAM_ID` | 10-character Apple Developer Team ID |

To produce the Base64 values on macOS, run `base64 -i Distribution.p12 | pbcopy` and `base64 -i ZipBridge_AdHoc.mobileprovision | pbcopy` separately, then paste each result into its matching GitHub secret. Do not commit the certificate, profile, passwords, or Base64 values to the repository.

The Ad Hoc profile must be generated for bundle ID `com.mr3242.ZipBridge`, include the matching Apple Distribution certificate, and contain the UDIDs of the iPhones/iPads that should be able to install the IPA. Devices not listed in that profile cannot install the Ad Hoc build. Renew the certificate/profile and update the secrets before they expire.

**Until these secrets are configured, the scheduled workflow will stop at its signing-secrets check and will not publish an IPA or release.** The existing simulator CI workflow remains separate and does not require Apple signing credentials.
