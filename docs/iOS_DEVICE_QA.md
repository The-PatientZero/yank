# iOS Device QA

Complete this checklist on physical hardware before promoting an iOS build. Simulator tests
remain required, but they do not prove App Group sharing, keyboard insertion, CloudKit
delivery, iCloud account state, memory pressure, or data protection while a device is locked.

Record results in a copy of [`IOS_RELEASE_EVIDENCE_TEMPLATE.md`](IOS_RELEASE_EVIDENCE_TEMPLATE.md).

## Build identity

- [ ] Marketing version and build number match the archive selected for submission.
- [ ] Commit SHA and archive creation date are recorded.
- [ ] App, keyboard, and share extension bundle identifiers match the distribution profile.
- [ ] The tested build was installed from the release archive or TestFlight.

## Device coverage

Use at least:

- [ ] the oldest supported iOS 17-capable iPhone available;
- [ ] a current iPhone size class;
- [ ] an iPad with Split View or Stage Manager; and
- [ ] one device signed into a different iCloud account for account-transition checks.

Record the model, OS version, available storage, install condition, iCloud account alias and
sync state, foreground capture mode, Paste from Other Apps permission, and whether the keyboard
is enabled with Full Access off. Use non-identifying account aliases rather than Apple IDs.

## Host app

- [ ] Launch, onboarding, settings, empty history, populated history, and clip details work.
- [ ] Fresh setup shows Keyboard, Share Sheet, and Save Clipboard as independent methods.
- [ ] Confirming one method updates only that row; confirming all methods advances to the ready-empty state.
- [ ] Continue advances to the ready-empty state without requiring all three methods, and the state survives relaunch.
- [ ] Review Capture Methods returns to the setup state without changing history.
- [ ] Settings does not duplicate the capture-method checklist.
- [ ] With no saved foreground-capture choice, Yank explains the choice before reading the clipboard.
- [ ] “Ask Next Time” performs no foreground clipboard read for the rest of the session and asks again after a cold relaunch.
- [ ] “Check When Yank Opens” persists after a cold relaunch and checks the clipboard only when Yank becomes active.
- [ ] “Only When I Ask” persists after a cold relaunch, performs no foreground clipboard read, and still imports Share and Save Clipboard captures.
- [ ] Changing the foreground-capture mode in Settings takes effect immediately without losing history.
- [ ] Copy new plain text in another app, return to Yank, and confirm the exact value appears once.
- [ ] Returning with an unchanged clipboard does not refresh or duplicate the clip.
- [ ] Copy a clip from Yank, terminate and relaunch Yank, and confirm Yank's own pasteboard write is not recaptured.
- [ ] Copy byte-identical content from another app after that self-origin check and confirm the external copy remains eligible exactly once.
- [ ] Deny Paste from Other Apps and confirm the denied generation remains unacknowledged and retryable; allow access and confirm that same generation is captured exactly once.
- [ ] Multiple copies made while Yank is suspended retain only the latest system clipboard value.
- [ ] A successful Save Clipboard Shortcut appears after Yank next becomes active, without duplicating or overwriting history.
- [ ] Text, link, image, large-text, pinned, bookmarked, and tagged clips render correctly.
- [ ] Byte-identical plain-text and rich-text clipboard representations retain distinct identities through capture and relaunch, including any inline, file-backed, or truncated variants exercised by the build.
- [ ] Copy, delete, clear, search, tag filtering, pinning, and bookmarking persist after relaunch.
- [ ] Portrait, portrait upside down, landscape left, and landscape right remain usable on iPhone.
- [ ] Both iPad orientations and supported multitasking widths remain usable.
- [ ] Light and dark appearances keep text, badges, focus, and selection legible.
- [ ] Dynamic Type through accessibility sizes does not hide required actions.
- [ ] VoiceOver announces controls, state, and clip actions in a useful order.
- [ ] Image detail and peek surfaces use one bounded VoiceOver label: OCR text when available, then the source app, then “Image clip.”
- [ ] Reduce Motion and Reduce Transparency remove non-essential effects without losing state.
- [ ] The Privacy Policy link in Settings opens the public policy over HTTPS.

## Keyboard extension

Yank does not request Full Access. Verify the shipping read-only configuration:

- [ ] Allow Full Access is not requested by the extension.
- [ ] Recent insertable clips load from the bounded App Group projection.
- [ ] After opening Yank to import a shared clip, the keyboard shows it exactly once.
- [ ] Search filters recent insertable clips.
- [ ] Selecting a text or link clip inserts it exactly once.
- [ ] The globe/next-keyboard control works whenever the system requires it.
- [ ] VoiceOver labels and focus order are usable.
- [ ] Portrait, landscape, and iPad multitasking layouts do not clip required controls.
- [ ] Empty, unavailable, protected-data, and storage-failure states explain recovery.

If clip insertion or next-keyboard switching is unavailable, do not submit the build to App Review.

## Share extension

- [ ] Plain text, a URL, a small PNG, and a small HEIC image save successfully.
- [ ] The confirmation accurately describes the saved content.
- [ ] Empty, zero-byte, malformed, animated, and unsupported providers fail safely.
- [ ] Oversized or sparse source files are rejected before a large in-memory copy.
- [ ] Cancelling from the host app does not create a partial clip.
- [ ] Success and failure are announced by VoiceOver.
- [ ] Relaunching Yank shows exactly one saved clip with its image intact.

## iCloud and lifecycle

- [ ] First opt-in uploads local history without losing existing records.
- [ ] On two devices using the same recorded iCloud account alias, text, image, tags, pin/bookmark state, and deletions converge in both directions.
- [ ] After foreground catch-up and relaunch on both devices, the converged history has no missing or duplicate clips.
- [ ] Record the source device and OS for a Universal Clipboard copy; returning to Yank under the recorded mode and permission state captures the eligible value exactly once.
- [ ] Offline edits recover after connectivity returns.
- [ ] A partial record failure does not advance the change token past failed work.
- [ ] Quota exhaustion and signed-out states preserve local history and explain recovery.
- [ ] iCloud account changes and expired tokens trigger a safe reconciliation.
- [ ] Push-disabled operation catches up on foreground refresh.
- [ ] Background change delivery does not duplicate clips.
- [ ] Launch before first unlock reports protected storage without replacing history with empty data.
- [ ] Launch after first unlock hydrates the original history.
- [ ] After a foreground capture, immediately background or terminate Yank; relaunch shows the acknowledged clip exactly once, while interrupted unacknowledged work remains retryable.

## Capacity and resource checks

On the lowest-memory test devices, repeat launch, search, scroll, extension open, and sync with
histories of approximately 100, 500, and 1,000 clips, including protected clips beyond the
normal cap.

- [ ] Record cold-launch duration and peak memory for the app and both extensions.
- [ ] No `EXC_RESOURCE`, watchdog termination, or visible multi-second input stall occurs.
- [ ] Backgrounding, memory pressure, and termination do not lose acknowledged changes.
- [ ] Protected clips beyond the normal history cap remain present while keyboard projection and previews stay bounded.
- [ ] Large text and image previews stay responsive without loading full payloads unnecessarily.

## macOS target-focus checks

Record the macOS version, target app, and target field used for each result.

- [ ] Starting Paste Sequence from another app keeps that app and field as the paste target while Yank's menu opens, refreshes, and dismisses.
- [ ] Cancel and eligible Repeat Previous actions work by keyboard, pointer, and VoiceOver without moving focus from the paste destination.
- [ ] The status HUD remains non-key, and Reduce Motion changes presentation without changing sequence state.

## Distribution checks

- [ ] The signed archive contains the expected app and extension entitlements and both embedded extensions.
- [ ] The signed archive packages `PrivacyInfo.xcprivacy` in the host app, keyboard extension, and share extension bundles.
- [ ] The archive privacy report matches actual required-reason API use.
- [ ] App Store Connect contains the same reachable Privacy Policy URL as the app.
- [ ] App privacy answers match local storage, optional private CloudKit sync, and extension behavior.
- [ ] App Review notes explain the keyboard's read-only App Group boundary and no-network behavior.
- [ ] A TestFlight install discovers both extensions and passes the critical host/extension flows.

Any unchecked release requirement must have a written owner decision in the evidence record.
