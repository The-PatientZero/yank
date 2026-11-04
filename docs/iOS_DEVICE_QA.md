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
- [ ] “Only When I Ask” persists after a cold relaunch, performs no foreground clipboard read, and still saves Share and Save Clipboard captures: Save Clipboard lands in history right away, and Share captures are imported the next time Yank opens.
- [ ] Changing the foreground-capture mode in Settings takes effect immediately without losing history.
- [ ] Copy new plain text in another app, return to Yank, and confirm the exact value appears once.
- [ ] Copy a photo in Photos and an image in Safari, return to Yank after each, and confirm each appears once as an image clip.
- [ ] Copy text that carries an image (for example from Notes) and confirm it is saved as text.
- [ ] Returning with an unchanged clipboard does not refresh or duplicate the clip.
- [ ] Copy a clip from Yank, terminate and relaunch Yank, and confirm Yank's own pasteboard write is not recaptured.
- [ ] Copy byte-identical content from another app after that self-origin check and confirm the external copy remains eligible exactly once.
- [ ] Deny Paste from Other Apps and confirm the denied generation remains unacknowledged and retryable; allow access and confirm that same generation is captured exactly once.
- [ ] Multiple copies made while Yank is suspended retain only the latest system clipboard value.
- [ ] With Yank force-quit, a Save Clipboard Shortcut run (Get Clipboard, then Save Clipboard with its Text input set) appears in history and in the keyboard without opening Yank, and opening Yank shows exactly one clip.
- [ ] Save Clipboard saves a copied photo as an image clip, both with no input and with Get Clipboard passed to its Image input.
- [ ] With iCloud sync on, that Shortcut clip reaches a second device within a minute without Yank being opened on the phone. With sync off the result reads "Saved to Yank" and does not mention sync.
- [ ] Run the Shortcut with an empty Text input and write down whether the background clipboard read saved the text or showed "No text was received". Run it with no text anywhere: the message names the Text input and does not call the clipboard empty.
- [ ] After a restart and before the first unlock, the Shortcut shows the storage error and does not claim anything was saved.
- [ ] A Shortcut capture confirms the Shortcut method in the capture setup screen without Yank being opened, and running it twice with the same text leaves one clip.
- [ ] Note the time the Shortcut takes on a cold run with a large history, and check that the result wording matches what happened (saved, saved with sync pending, or only queued).
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
- [ ] A short text shared to Yank appears first in the keyboard right away, before Yank is opened, and inserts correctly.
- [ ] After opening Yank to import a shared clip, the keyboard shows it exactly once, and sharing the same text twice before opening Yank shows it once.
- [ ] Filter chips narrow the list; Pinned and Bookmarked show only clips among the keyboard's recent clips.
- [ ] Selecting a text or link clip inserts it exactly once.
- [ ] The globe/next-keyboard control works whenever the system requires it, and follows docking, undocking, floating and resizing on iPad: tap switches, long-press shows the keyboard list.
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
- [ ] A shared item with several attachments saves all of them, up to ten; a web page from Safari saves one URL clip, and three photos save three image clips.
- [ ] Formatted text from Notes, Mail and Messages saves as readable text without markup, and a `.txt` file from Files is refused with a card saying files cannot be saved.
- [ ] A failed share stays on screen until Done is tapped, VoiceOver reads it and moves focus to Done, and swiping the share sheet down ends the extension cleanly. A successful share still closes by itself.
- [ ] A partly failed share reports "Saved N of M" and names the items that were not saved, and a selection of more than ten photos says which were not tried.
- [ ] Text of only spaces says there is no text to save, and a read-only or full shared folder says storage is unavailable and logs one error line without the shared text.
- [ ] Mixed selections (photos with a video, text with an image) either are not offered, complete, or fail with a readable card.
- [ ] Running the previous release over this build leaves the keyboard and history working, and the leftover keyboard preview is not shown twice and is cleared when the app opens.

## iCloud and lifecycle

- [ ] First opt-in uploads local history without losing existing records.
- [ ] On two devices using the same recorded iCloud account alias, text, image, tags, pin/bookmark state, and deletions converge in both directions.
- [ ] After foreground catch-up and relaunch on both devices, the converged history has no missing or duplicate clips.
- [ ] Record the source device and OS for a Universal Clipboard copy; returning to Yank under the recorded mode and permission state captures the eligible value exactly once.
- [ ] Offline edits recover after connectivity returns. With the app open, sync resumes without a tap or pull to refresh.
- [ ] A partial record failure does not advance the change token past failed work.
- [ ] Quota exhaustion and signed-out states preserve local history and explain recovery.
- [ ] iCloud account changes and expired tokens trigger a safe reconciliation. Signing out and back in resumes sync without a relaunch.
- [ ] Push-disabled operation catches up on foreground refresh.
- [ ] Background change delivery does not duplicate clips.
- [ ] Launch before first unlock reports protected storage without replacing history with empty data.
- [ ] Launch after first unlock hydrates the original history. The storage banner clears without a relaunch and the Sync and history limit settings keep their earlier values.
- [ ] After a foreground capture, immediately background or terminate Yank; relaunch shows the acknowledged clip exactly once, while interrupted unacknowledged work remains retryable.

Two-device edits (Mac and iPhone on the same iCloud account, both on Debug builds, both offline while editing, then online; after a delete wait 10 seconds before going online). For the older-version cases, build Yank 1.2.0 from the `v1.2.0` tag.

- [ ] Pin on one device and add the tag "work" to the same clip on the other: both devices show the clip pinned and tagged.
- [ ] Bookmark on one device and remove the tag "work" on the other: both show it bookmarked and without the tag.
- [ ] Pin on the iPhone while the Mac copies the same clip again from history: both show it pinned, first in the Pinned section.
- [ ] Delete on the Mac, then a minute later pin the clip on the iPhone: the clip is gone from both and stays gone after relaunching both.
- [ ] Delete on the Mac, then a minute later copy the clip again from history on the iPhone: the clip is on both devices, as the newest clip.
- [ ] Copy the exact same text on both devices while offline and pin it on the iPhone: after sync there is one clip, pinned and newest, and search finds one result.
- [ ] Universal Clipboard: copy on the Mac and open Yank on the iPhone right away; after sync both show one clip. Record the iOS version and whether two clips ever appeared.
- [ ] With Yank 1.2.0 on both devices, create two identical clips, then install this build: both clips stay, history count unchanged, also after lowering and raising the history limit.
- [ ] One device on Yank 1.2.0, one on this build: pin on one and tag on the other, in each order, then reuse versus pin, then delete versus pin in each direction. Both devices end the same, and sync goes quiet (idle "Sync pull started" count in Console, clip Modified time in CloudKit Console stops changing).

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

- [ ] A signed physical Debug build used for CloudKit diagnosis has host entitlements `com.apple.developer.icloud-container-environment=Development` and `aps-environment=development`.
- [ ] The signed Release archive has host entitlements `com.apple.developer.icloud-container-environment=Production`, `aps-environment=production`, CloudKit service and container `iCloud.com.thepatientzero.yank`, and App Group `group.com.thepatientzero.yank`.
- [ ] The signed archive contains both embedded extensions; each extension retains the App Group entitlement without host-only CloudKit or push entitlements.
- [ ] The signed archive packages `PrivacyInfo.xcprivacy` in the host app, keyboard extension, and share extension bundles.
- [ ] The archive privacy report matches actual required-reason API use.
- [ ] App Store Connect contains the same reachable Privacy Policy URL as the app.
- [ ] App privacy answers match local storage, optional private CloudKit sync, and extension behavior.
- [ ] App Review notes explain the keyboard's read-only App Group boundary and no-network behavior.
- [ ] A TestFlight install discovers both extensions and passes the critical host/extension flows.

Any unchecked release requirement must have a written owner decision in the evidence record.
