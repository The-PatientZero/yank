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

The macOS Developer ID build is intentionally unsandboxed because continuous clipboard monitoring, the global hotkey, and simulated paste rely on pasteboard, Accessibility, and CGEvent behavior that is not compatible with the App Sandbox. The compensating controls are Developer ID signing, notarization, hardened runtime, no broad resource entitlements, private local storage, and update verification before replacing the installed app. There is no Mac App Store build — the notarized DMG is the only macOS channel, so sandbox adoption is not planned.

### Update Trust Model

The `releases.json` manifest is fetched from the pinned public HTTPS release host and is not separately signed. The manifest is not the trust anchor: each staged app must match the expected SHA-256, bundle ID/version, Developer ID team requirement, and Gatekeeper assessment before install. A tampered manifest can only select a different asset, which then fails staging. A detached manifest signature remains optional future defense-in-depth.

Security concerns most relevant to this project:

- Local privilege escalation
- Unauthorized access to clipboard data stored on disk
- Vulnerabilities in the accessibility/hotkey permission flow
- Update integrity or release asset substitution

## Disclosure Policy

We follow responsible disclosure. Once a fix is released, we will publicly acknowledge the report (with your permission).
