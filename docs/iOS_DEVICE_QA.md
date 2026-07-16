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

Record the model, OS version, available storage, iCloud state, and whether the device was
restored or installed cleanly.

## Host app

- [ ] Launch, onboarding, settings, empty history, populated history, and clip details work.
- [ ] Text, link, image, large-text, pinned, bookmarked, and tagged clips render correctly.
- [ ] Copy, delete, clear, search, tag filtering, pinning, and bookmarking persist after relaunch.
- [ ] Portrait, portrait upside down, landscape left, and landscape right remain usable on iPhone.
- [ ] Both iPad orientations and supported multitasking widths remain usable.
- [ ] Light and dark appearances keep text, badges, focus, and selection legible.
- [ ] Dynamic Type through accessibility sizes does not hide required actions.
- [ ] VoiceOver announces controls, state, and clip actions in a useful order.
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
- [ ] Text, image, tags, pin/bookmark state, and deletions reconcile between devices.
- [ ] Offline edits recover after connectivity returns.
- [ ] A partial record failure does not advance the change token past failed work.
- [ ] Quota exhaustion and signed-out states preserve local history and explain recovery.
- [ ] iCloud account changes and expired tokens trigger a safe reconciliation.
- [ ] Push-disabled operation catches up on foreground refresh.
- [ ] Background change delivery does not duplicate clips.
- [ ] Launch before first unlock reports protected storage without replacing history with empty data.
- [ ] Launch after first unlock hydrates the original history.

## Capacity and resource checks

On the lowest-memory test devices, repeat launch, search, scroll, extension open, and sync with
histories of approximately 100, 500, and 1,000 clips, including protected clips beyond the
normal cap.

- [ ] Record cold-launch duration and peak memory for the app and both extensions.
- [ ] No `EXC_RESOURCE`, watchdog termination, or visible multi-second input stall occurs.
- [ ] Backgrounding, memory pressure, and termination do not lose acknowledged changes.
- [ ] Large text and image previews stay responsive without loading full payloads unnecessarily.

## Distribution checks

- [ ] The signed archive contains the expected app and extension entitlements.
- [ ] The archive privacy report matches actual required-reason API use.
- [ ] App Store Connect contains the same reachable Privacy Policy URL as the app.
- [ ] App privacy answers match local storage, optional private CloudKit sync, and extension behavior.
- [ ] App Review notes explain the keyboard's read-only App Group boundary and no-network behavior.
- [ ] A TestFlight install discovers both extensions and passes the critical host/extension flows.

Any unchecked release requirement must have a written owner decision in the evidence record.
