# Changelog

All notable changes to Yank are documented here.

This file is the source for GitHub release notes. The release workflow extracts the
section matching the pushed tag, for example `v1.0.0` from `## [1.0.0] - YYYY-MM-DD`,
and passes that section to `gh release create --notes-file`.

## [Unreleased]

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
