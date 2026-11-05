# Changelog

All notable changes to Yank are documented here.

This file is the source for GitHub release notes. The release workflow extracts the
section matching the pushed tag, for example `v1.0.0` from `## [1.0.0] - YYYY-MM-DD`,
and passes that section to `gh release create --notes-file`.

## [Unreleased]

### Fixed

- Yank no longer crashes during iCloud sync when it saves a change to a clip that is already in iCloud. Before, the app crashed on every sync until the change was saved, which made it close right after opening.

## [1.4.0] - 2026-11-04

### Added

- A Menu bar icon style setting on the Mac, under Settings > General. Plain draws the icon in one color that matches the other menu bar icons. Color, the default, keeps the logo's colors. The update, sync and pause marks keep their colors in both styles.
- iPhone and iPad save copied images, not only text. With Check When Yank Opens, a copied photo or screenshot is saved when you return to Yank. The Save Clipboard shortcut saves a copied image, or an image passed to its new Image input. Copied text that carries an image is still saved as text, as on the Mac.

## [1.3.0] - 2026-11-04

### Added

- Include History in Device Backups on iPhone and iPad, off by default. Yank asks iOS to keep history, the deletion log, attachments, keyboard copy and share inbox out of device backups, as it does on the Mac, so existing installs stop including history in new backups unless you turn it on. A device restored without history refills from iCloud sync, up to your history limit. iOS treats the request as guidance, not a guarantee.
- iCloud sync status on Mac and iPhone: the Mac menu-bar menu shows whether sync works and has a Sync now row, and the icon shows a dot when sync has a problem. Failures are explained in plain words with a button for the next step.
- Clips that cannot be uploaded are listed in Settings, where you can keep them on the device or delete them.
- The Mac menu-bar icon shows a dot while an update is available, downloading or waiting for a relaunch, and a pause mark while capture is paused. Tooltips and VoiceOver name each state.
- An Updates row in Settings > About shows the update status and the next step, so you can update with the menu-bar icon hidden. Yank re-checks about once a day while it runs.
- The Quick Picker footer shows "Capture paused" with a Resume button. With the menu-bar icon hidden, the shortcut opens the Quick Picker instead of the full history while capture is paused.
- A Cancel button on the Paste Sequence panel and a Cancel Paste Sequence row in the menu-bar menu on the Mac. Cancelling leaves your clipboard and history as they are.
- A Copy button on clip rows and tiles on iPhone.
- Tapping a clip in Spotlight search opens it in Yank.
- The first sync on a new device shows how many clips have arrived, and files the device already has are not downloaded again.
- iPhone and iPad cover the app with a plain screen when you leave Yank, so the app switcher does not show your clips.
- A right-click menu for clips in the Mac history window, and keyboard shortcuts for layouts, Settings, pasting the first nine clips, peeking and undoing a delete. The README lists them.
- The iPhone and iPad first-run screen is one screen for clipboard access, the ways to save and paste, and the iCloud choice. The Mac welcome window has an iCloud Sync switch.

### Changed

- Save Clipboard from Shortcuts on iPhone puts the text in history and the keyboard straight away, even if Yank is closed, and sends it to your other devices when sync is on. The result says whether it was saved, saved with syncing still to finish, or only queued until Yank next opens.
- Save Clipboard takes an optional Text input that is saved instead of the clipboard, and a missing text says "No text was received" instead of claiming the clipboard is empty.
- Text shared from the Share Sheet shows in the keyboard right away; history and iCloud follow the next time Yank opens.
- The iPhone Share Sheet saves up to ten shared items, and Yank accepts up to ten photos at once. Rich text is saved as readable text, a web page saves its address once, and files are refused with a clear message.
- A share that fails or only partly works stays on screen until you tap Done and says which items were not saved. Text of only spaces is reported as empty instead of as a storage problem.
- The iPhone keyboard narrows your clips with filter chips (All, Pinned, Bookmarked and the kinds of clip you have) instead of a search box, because a custom keyboard cannot type into its own text field. VoiceOver reads each row's pin, bookmark and tags, and the switch-keyboard key stays in a fixed footer.
- On the Mac, pausing capture survives quitting, restarts and update relaunches until you resume. The setting stays on this Mac and is not synced. An older version captures again, and updating again brings the pause back.
- Clip text, tags, recognized text and the source app are stored in an end-to-end encrypted iCloud field that Apple cannot read. While your devices update, Yank keeps a readable copy too. After at least 14 days, and once no older version has been active for 60 days, it stops writing readable copies and erases the ones in iCloud. Settings shows the progress. An older Yank on the same iCloud account shows clips without their text, so update every device. See PRIVACY.md.
- Shortening auto-delete asks you to confirm on Mac and iPhone, because it deletes older clips on every synced device.
- The history window and the Quick Picker open with the newest clip selected and the search cleared.
- Paste on the Mac copies the clip and tells you to press Command-V when Accessibility access is off, instead of prompting for it.
- The updater refuses an update archive larger than 128 MB and accepts update files only from the expected GitHub release location.
- Command-B is no longer offered as a global shortcut preset, because it bookmarks a clip in the history window. A shortcut you already set stays.

### Fixed

- Edits to the same clip on two devices before they sync are merged. A pin on one device and a tag on another both survive, and reopening a clip no longer undoes a pin or tag set elsewhere. Per-field merging needs both devices on this version; with an older version, one of two simultaneous edits can still be lost.
- An edit other than a pin, bookmark or tag no longer brings back a clip that another device deleted. A pin, bookmark or tag added after the delete, or copying the clip again, still does.
- The same text copied on a Mac and an iPhone before they sync ends up as one clip that keeps the pins, bookmarks and tags of both. Duplicates already in your history are left as they are.
- iCloud sync resumes by itself on Mac and iPhone after the network returns, after you switch or sign out of iCloud and back in, and after a background update.
- A Mac that started offline sets up push delivery once it is online, two syncs no longer run at once, an iPhone refresh requested during another sync is no longer dropped, and an iPhone started before its first unlock recovers once unlocked.
- Copies carrying the older concealed and transient markers used by 1Password and some text expanders are no longer recorded on Mac and iPhone. Clips an earlier version stored stay in history.
- On the Mac, a copy made in an excluded app is not recorded when you switch to another app within half a second, and a copy whose source hint names an excluded app is skipped. iPhone cannot exclude by app.
- Auto-delete on a Mac or iPhone that was off, asleep or offline no longer deletes a clip that you copied again, pinned, bookmarked or tagged on another device in the meantime.
- Auto-delete runs once iCloud has delivered your synced settings, so a window changed on another device is used, and clips deleted long after their last use are also removed from iCloud.
- Re-saving a shared clip that is older than its last use no longer moves it down in history.
- Moving the history window or the Quick Picker no longer switches "Open at" to Last position by itself. An install that already has Last position shows a note under the setting with Restore default and Keep.

## [1.2.0] - 2026-08-21

### Added

- Synced the auto-delete retention window across devices through the shared settings record, so one device's shorter window no longer deletes clips account-wide by surprise — the policy is now a single, deliberate choice.

### Fixed

- Stopped devices from re-uploading every record (and its full image or text attachment) they had just downloaded, removing a sync echo that wasted bandwidth and invited CloudKit rate limiting.
- Re-published the newer local copy of a clip when a pull revealed the server held a stale version, instead of leaving the two silently diverged.
- Made a failed CloudKit bring-up recoverable everywhere: iOS re-runs the full zone and subscription setup on the next foreground or push instead of wedging until a force-quit, macOS retries with backoff, and local edits made while sync was down are pushed once it recovers.
- Added wake-from-sleep and hourly catch-up pulls on macOS, so a Mac that missed silent pushes while asleep converges without a relaunch.
- Committed a pending delete when the macOS app quits inside the 10-second undo window, so the deletion survives the restart and propagates to other devices.
- Preserved a clip's local rich-text formatting when an edit from another device wins the sync merge; the merge no longer discards the on-disk rich archive.
- Erased a deleted clip's text, metadata, and attachment from iCloud when its deletion syncs, instead of leaving the content readable in the private database indefinitely.
- Held the sync checkpoint when the skipped-record quarantine cannot track another failure, and granted quarantined records fresh resolution attempts after an app update.
- Reset per-account sync checkpoints after an iCloud account switch, so the new account receives the full library instead of being silently skipped.
- Swept orphaned clip attachments at launch so a crash mid-sync can no longer leak disk space permanently.

## [1.1.0] - 2026-08-09

### Added

- Synced the history-limit setting across devices through CloudKit with last-writer-wins resolution, so every device keeps the same amount of history.

### Changed

- Asked for confirmation before a history-limit reduction on iPhone and iPad, and warned on either platform only when the smaller limit would actually delete clips.

### Fixed

- Suppressed duplicate history entries and phantom copy sounds caused by apps that re-assert the clipboard with identical content when they gain focus.
- Made CloudKit pushes retry with bounded backoff, persist progress after every accepted batch, and skip unmappable items instead of blocking all syncing.
- Quarantined permanently unresolvable CloudKit records so a single broken record no longer freezes sync for every later item, with automatic recovery attempts on later pulls.
- Kept iOS registered for sync push notifications through transient iCloud account states and replayed silent pushes that arrived before startup finished wiring the handler.

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
