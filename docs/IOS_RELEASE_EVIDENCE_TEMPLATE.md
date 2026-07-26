# iOS Release Evidence — VERSION (BUILD)

## Candidate

| Field | Value |
|---|---|
| Marketing version | |
| Build number | |
| Commit SHA | |
| Archive path or organizer identifier | |
| Archive created | |
| TestFlight build | |
| Tester | |
| Evidence date | |
| Overall result | Pending / Pass / Fail |

## Automated verification

| Check | Command or run URL | Result | Evidence |
|---|---|---|---|
| YankCore tests | `swift test` | | |
| macOS host tests | `xcodebuild ... -scheme Yank ... test` | | |
| iOS simulator tests | `xcodebuild ... -scheme YankiOS ... test` | | |
| Release configuration | XcodeGen generation and archive validation | | |
| Signed archive structure | host app, keyboard extension, and share extension bundles | | |
| Signed archive entitlements | host app and both extensions | | |
| Packaged privacy manifests | `PrivacyInfo.xcprivacy` in the host app and both extension bundles | | |
| Archive privacy report | required-reason API declarations match packaged behavior | | |

Automated and simulator results do not prove signed-archive contents, system paste permission,
extension behavior, Universal Clipboard, CloudKit convergence, or physical-device resource use.

## Physical devices

| Device / model | OS | Install source and condition | Storage | Account alias / sync state | Capture mode | Paste permission | Keyboard enabled / Full Access | Result | Evidence |
|---|---|---|---|---|---|---|---|---|---|
| Oldest supported iPhone | | | | | | | | | |
| Current iPhone | | | | | | | | | |
| iPad | | | | | | | | | |
| Account-transition device | | | | | | | | | |

Use non-identifying account aliases. Record capture mode as “Ask Next Time,” “Check When Yank
Opens,” or “Only When I Ask,” and record both keyboard enabled state and Full Access state.

## Clipboard privacy, identity, and durability

| Scenario | Device / source | Account and permission state | Result | Evidence or notes |
|---|---|---|---|---|
| Fresh or missing choice: disclosure appears before any clipboard read | | | | |
| “Ask Next Time”: no read for the session; disclosure returns after cold relaunch | | | | |
| “Check When Yank Opens”: choice persists and eligible foreground content is captured once | | | | |
| “Only When I Ask”: choice persists, no foreground read occurs, and explicit capture still works | | | | |
| Settings mode change takes effect immediately without history loss | | | | |
| Paste denial: same generation remains unacknowledged, then retries exactly once after access is allowed | | | | |
| Byte-identical plain and rich representations remain distinct through capture and relaunch | | | | |
| Self-origin write is suppressed after cold relaunch; identical external content remains eligible once | | | | |
| Foreground capture survives immediate background or termination exactly once; unacknowledged work remains retryable | | | | |
| Universal Clipboard captures once under the recorded mode and permission state | | | | |

## Host app and accessibility

| Area | Result | Evidence or notes |
|---|---|---|
| Capture, browse, search, copy, and delete | | |
| Pin, bookmark, tags, and retention | | |
| All supported iPhone/iPad orientations | | |
| iPad multitasking widths | | |
| Light/dark and increased contrast | | |
| Dynamic Type accessibility sizes | | |
| VoiceOver actions and order | | |
| Bounded image detail/peek VoiceOver label: OCR, source app, then “Image clip” fallback | | |
| Reduce Motion / Reduce Transparency | | |
| Privacy Policy link | | |

## Extensions

| Area | Result | Evidence or notes |
|---|---|---|
| Keyboard read-only clip loading and insertion | | |
| Keyboard network/open-access restriction | | |
| Globe/next-keyboard control | | |
| Keyboard VoiceOver labels, focus order, insertion, and next-keyboard action | | |
| Share text and URL | | |
| Share PNG and HEIC | | |
| Malformed, empty, cancelled, and oversized share input | | |
| Protected-data and storage failure states | | |

## iCloud and lifecycle

| Scenario | Result | Evidence or notes |
|---|---|---|
| First sync preserves local and existing remote history | | |
| Same-account device A to device B convergence: text, image, metadata, and deletion | | |
| Same-account device B to device A convergence: text, image, metadata, and deletion | | |
| Foreground catch-up and relaunch leave no missing or duplicate clips on either device | | |
| Offline recovery | | |
| Partial record failure and token handling | | |
| Quota, sign-out, and account change | | |
| Push disabled and foreground catch-up | | |
| Locked before and after first unlock | | |
| Background delivery and termination durability | | |

Record the two device labels and one non-identifying account alias in each convergence result.

## Capacity and performance

| Device / history size | Cold launch | Peak memory | Terminations or stalls | Evidence |
|---|---:|---:|---|---|
| Oldest iPhone / ~100 clips | | | | |
| Oldest iPhone / ~500 clips | | | | |
| Oldest iPhone / ~1,000 clips | | | | |
| Oldest iPhone / protected clips beyond normal cap | | | | |
| iPad / ~1,000 clips | | | | |

## macOS target-focus preservation

| Scenario | macOS / target app and field | Result | Evidence or notes |
|---|---|---|---|
| Paste Sequence retains the original paste target while the menu opens, refreshes, and dismisses | | | |
| Cancel works by keyboard, pointer, and VoiceOver without moving target focus | | | |
| Eligible Repeat Previous works by keyboard, pointer, and VoiceOver without moving target focus | | | |
| Status HUD remains non-key; Reduce Motion does not change sequence state | | | |

## App Store metadata

| Check | Result | Evidence or notes |
|---|---|---|
| Privacy Policy URL | | |
| App privacy answers | | |
| Keyboard read-only boundary review note | | |
| Screenshots and supported-device metadata | | |
| TestFlight critical-flow result | | |

## Exceptions and residual risk

List every failed or unverified item. Include impact, owner, user-visible mitigation, and the
decision to fix or defer. Do not mark the candidate as passed while a release requirement is
unowned.

| Item | Impact | Owner | Decision | Follow-up evidence |
|---|---|---|---|---|
| | | | | |

## Sign-off

- Product/release owner:
- Engineering owner:
- QA owner:
- Decision: Approve / Reject
- Date:
- Notes:
