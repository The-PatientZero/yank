# Security Policy

## Supported Versions

Yank has not shipped a stable 1.0 release yet. Until then, security fixes land on `main`
and in the latest public prerelease, if one exists.

| Version | Supported |
| ------- | --------- |
| `main` / latest prerelease | Security fixes before 1.0 |
| Stable releases | Not available yet |

## Reporting a Vulnerability

If you discover a security vulnerability in Yank, please **do not** open a public GitHub issue.

Instead, report it privately using GitHub's private vulnerability reporting:

1. Go to the **Security** tab of this repository
2. Click **"Report a vulnerability"**
3. Fill in the details

If private vulnerability reporting is unavailable, contact the maintainer through GitHub first
without posting exploit details publicly.

### What to include

- A clear description of the vulnerability
- Steps to reproduce it
- Potential impact
- Any suggested fix (optional)

### Response timeline

- **Acknowledgement**: Within 48 hours
- **Status update**: Within 7 days
- **Fix / patch**: As soon as reasonably possible, depending on severity

## Scope

Yank is a macOS and iOS clipboard manager. Clipboard history is local by default; cross-device sync is opt-in and uses the user's private CloudKit database. macOS clipboard data is stored in `~/Library/Application Support/Yank/`.

### macOS Sandbox Posture

The macOS Developer ID build is intentionally unsandboxed because continuous clipboard monitoring, the global hotkey, and simulated paste rely on pasteboard, Accessibility, and CGEvent behavior that is not compatible with the App Sandbox. The compensating controls are Developer ID signing, notarization, hardened runtime, no broad resource entitlements, access-controlled local storage (see below), and update verification before replacing the installed app. There is no Mac App Store build — the notarized DMG is the only macOS channel, so sandbox adoption is not planned.

### Update Trust Model

The `releases.json` manifest is fetched from the pinned public HTTPS release host and is not separately signed. The manifest is not the trust anchor: each staged app must match the expected SHA-256, bundle ID/version, Developer ID team requirement, and Gatekeeper assessment before install. A tampered manifest can only select a different asset, which then fails staging. The updater also keeps a monotonic version floor — it will not "update" below the highest version ever installed on the machine — so a tampered manifest cannot re-offer a signed-but-older build. A detached manifest signature remains optional future defense-in-depth.

### Local Storage

macOS clipboard history (`~/Library/Application Support/Yank/`) is **access-controlled, not encrypted by Yank**: files are written with owner-only POSIX permissions and excluded from backups. Confidentiality at rest relies on the operating system (FileVault) and the user account boundary. Because the Developer ID build is unsandboxed, another process running as the same user could read these files — FileVault and the OS account boundary are the protections, not app-level encryption. On iOS, the shared App-Group container uses the `completeUntilFirstUserAuthentication` data-protection class.

### Clipboard Privacy

Copies that the source app marks concealed (`org.nspasteboard.ConcealedType`, used by password managers and secure text fields) are **never captured** — this is the primary safeguard against recording secrets and covers a manager regardless of how it is bundled (including browser-based managers). A curated app-exclusion list, plus any apps the user adds from disk, is a secondary control for managers that don't mark the pasteboard concealed.

### On-Device Intelligence

The optional Apple Intelligence features (tag suggestions, Smart Paste rewrites, natural-language search) run entirely on-device through Apple's Foundation Models. No clip content leaves the device, is sent to any server, or is logged. Background tag suggestion is opt-in and off by default; Smart Paste and natural-language search are user-invoked and only available when Apple Intelligence is present. AI-derived tags are treated as ordinary clip metadata and, when sync is enabled, ride the user's own private CloudKit database — never our servers. Records created by older releases may retain legacy AI-title metadata for decoding and sync compatibility, but Yank no longer generates, displays, or searches it.

Security concerns most relevant to this project:

- Local privilege escalation
- Unauthorized access to clipboard data stored on disk
- Vulnerabilities in the accessibility/hotkey permission flow
- Update integrity or release asset substitution

## Disclosure Policy

We follow responsible disclosure. Once a fix is released, we will publicly acknowledge the report (with your permission).
