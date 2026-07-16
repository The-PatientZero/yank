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
| Signed archive inspection | entitlements, embedded extensions, privacy report | | |

## Physical devices

| Device | OS | Install source | iCloud state | Open Access requested | Result | Evidence |
|---|---|---|---|---|---|---|
| Oldest supported iPhone | | | | No | | |
| Current iPhone | | | | No | | |
| iPad | | | | No | | |
| Account-transition device | | | | No | | |

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
| Reduce Motion / Reduce Transparency | | |
| Privacy Policy link | | |

## Extensions

| Area | Result | Evidence or notes |
|---|---|---|
| Keyboard read-only clip loading and insertion | | |
| Keyboard network/open-access restriction | | |
| Globe/next-keyboard control | | |
| Share text and URL | | |
| Share PNG and HEIC | | |
| Malformed, empty, cancelled, and oversized share input | | |
| Protected-data and storage failure states | | |

## iCloud and lifecycle

| Scenario | Result | Evidence or notes |
|---|---|---|
| First sync and normal two-device reconciliation | | |
| Offline recovery | | |
| Partial record failure and token handling | | |
| Quota, sign-out, and account change | | |
| Push disabled and foreground catch-up | | |
| Locked before and after first unlock | | |
| Background delivery and termination durability | | |

## Capacity and performance

| Device / history size | Cold launch | Peak memory | Terminations or stalls | Evidence |
|---|---:|---:|---|---|
| Oldest iPhone / ~100 clips | | | | |
| Oldest iPhone / ~500 clips | | | | |
| Oldest iPhone / ~1,000 clips | | | | |
| iPad / ~1,000 clips | | | | |

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
