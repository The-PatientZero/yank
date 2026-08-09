# Changelog

All notable changes to Yank are documented here.

This file is the source for GitHub release notes. The release workflow extracts the
section matching the pushed tag, for example `v1.0.0` from `## [1.0.0] - YYYY-MM-DD`,
and passes that section to `gh release create --notes-file`.

## [Unreleased]

### Added

- Synced the history-limit setting across devices through CloudKit with last-writer-wins resolution, so every device keeps the same amount of history.

## [1.0.4] - 2026-07-31

### Added

- Added a protected, manual TestFlight pipeline that validates, uploads, processes, and assigns an iOS build to verified internal and external testing groups.

### Changed

- Split the macOS clipboard, paste, and Quick Picker implementations into focused source files without changing their public behavior.

### Fixed

- Suppressed delayed capture sounds after expensive clipboard processing while preserving immediate copy confirmation.
- Kept Yank-authored clipboard suppression and synthetic paste dispatch bound to the exact pasteboard generation, so newer external copies and copied file paths are preserved.
- Restored the Quick Picker's intended dimensions by removing titlebar safe-area inflation, constraining image thumbnails, and validating saved window frames.
- Prevented stale deferred copy and paste work from overwriting or pasting newer clipboard content.

## [1.0.3] - 2026-07-26

### Added

- Added explicit automatic or manual-only foreground clipboard choices on iPhone and iPad.
- Added a cancellable Paste Sequence workflow with an accessible command surface.

### Changed

- Kept iOS keyboard history bounded, read-only, and generated away from the main UI path.
- Made clipboard and CloudKit persistence checkpoints transactional and retry-safe.

### Fixed

- Prevented stale async search, paste, sync, and lifecycle completions from mutating newer state.
- Preserved rich/plain capture identity and suppressed Yank-authored clipboard generations across relaunches.
- Bounded macOS pasteboard materialization and moved it off the main actor.
- Made CloudKit recovery commands return reliable process exit status.
- Selected the correct CloudKit environment for Development and Production builds.
- Recovered missing CloudKit assets when an equal-or-newer local deletion safely dominates the remote record.
- Corrected image preview accessibility labels and iOS setup copy.

## [1.0.2] - 2026-07-12

### Fixed

- Restored Quick Picker arrow-key navigation by routing keyboard commands only to the active Yank window.
- Focused the Quick Picker search field on every opening, including when reopening beside the focused text field.

## [1.0.1] - 2026-07-12

### Changed

- Kept background Apple Intelligence enrichment focused on suggested tags; Yank no longer generates, displays, or searches AI titles in clipboard history.

## [1.0.0] - 2026-06-27

Initial public release.

### Added

- Added an iOS release evidence template and required device QA gate before App Store promotion.
- Added a compact quick picker for keyboard-first clipboard selection.
- Added optional on-device Apple Intelligence (macOS 26+): tag & title suggestions, Smart Paste rewrites, and natural-language search — private, on-device via Foundation Models, and opt-in.

### Changed

- Replaced separate updater dialogs and progress HUDs with a single inline status-menu lifecycle.
- Integrated post-update "What's new" release notes into the update row.
- Made the global shortcut open the quick picker by default, with full history still available.
- Made the quick picker open beside the focused text field when Accessibility exposes one.

### Fixed

- Made actionable update rows keyboard-focusable.
- Prevented untrusted release page URLs from being offered as release-note links.
