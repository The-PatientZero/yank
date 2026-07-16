# Yank Privacy Policy

Effective: July 16, 2026

Yank is a private-by-design clipboard manager for macOS, iPhone, and iPad. It does not
require an account, contain advertising, or include analytics or tracking SDKs. The Yank
maintainer does not operate a server that receives clipboard content.

## Data Yank processes

Depending on what you copy or share, Yank may process text, links, images, file references,
rich pasteboard representations, source-app names, timestamps, tags, bookmarks, pins, OCR
text, and settings. This data may contain personal or sensitive information because it comes
from your clipboard.

Yank stores clipboard history on the device by default:

- On macOS, history is stored in `~/Library/Application Support/Yank/`.
- On iPhone and iPad, the app and its extensions use Yank's private App Group container.
- Rich pasteboard archives are local to the Mac that captured them and are not synced.

Retention limits and automatic deletion are controlled in Settings. Pinned, bookmarked, or
tagged clips are retained until you remove their protection or delete them.

## Optional iCloud sync

iCloud sync is off by default. If you enable it, supported clip content and metadata are
stored in your private CloudKit database so your Yank devices can reconcile history. Yank's
maintainer cannot access that private database. Apple processes the synchronized data under
your iCloud account and Apple's terms.

## Keyboard and share extensions

The iOS keyboard extension does not request Full Access. It has read-only access to a bounded
view of recent text clips in Yank's private App Group and can insert the clip you select into
the app you are using. It does not have network access.

The share extension receives only the text, link, or image you choose through the system
share sheet and hands it to the Yank app through private local App Group storage.

## On-device intelligence and OCR

Optional Apple Intelligence features use Apple's Foundation Models on the device for tag
suggestions, Smart Paste, and natural-language search. Image text recognition uses Apple
Vision on the device. Yank does not send clip content to an external AI or OCR service.

AI-generated tags are ordinary clip metadata. If iCloud sync is enabled, those tags sync
with the related clip through your private CloudKit database.

## Spotlight and system permissions

Spotlight indexing is opt-in. When enabled, selected clip metadata is added to the device's
system search index. Turning the setting off removes Yank's Spotlight index.

On macOS, Accessibility permission enables automatic paste and focused-field placement.
Yank uses it to perform those requested actions, not to record keystrokes. Notification and
iCloud capabilities support CloudKit change delivery on Apple platforms.

## Network access

The macOS app contacts Yank's public GitHub release resources to check for and download
updates. Standard request information, such as an IP address, may be processed by GitHub
under its own privacy terms. Yank does not attach clipboard content to update requests.

Apart from optional iCloud sync and update delivery, Yank has no application service that
receives user content.

## Your controls

You can:

- pause clipboard capture or exclude selected Mac apps;
- keep iCloud sync, Spotlight indexing, and background tag suggestions off;
- delete individual clips or clear history from Settings;
- disable the keyboard or share extension in system settings; and
- clear history before uninstalling when you want local clip records removed.

When iCloud sync is enabled, clip deletions are synchronized to your other Yank devices.
Removing the app alone may leave application support files managed by the operating system
and does not guarantee deletion of records already stored in iCloud. You can manage iCloud
application data through your Apple account settings.

## Security and contact

Yank skips pasteboard entries that source apps mark as concealed or transient and supports
capture exclusions. These safeguards reduce accidental capture but cannot classify every
piece of sensitive content, so review clipboard history before sharing a device or backup.

For security vulnerabilities, use the private reporting instructions in
[`SECURITY.md`](SECURITY.md). For general privacy questions, open an issue in the
[Yank repository](https://github.com/The-PatientZero/yank/issues/new) without including
private clipboard content.

Material changes to this policy will be published in this repository with a revised
effective date.
