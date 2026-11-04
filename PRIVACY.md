# Yank Privacy Policy

Effective: November 4, 2026

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

On iPhone and iPad, you choose between automatic foreground capture and explicit-only
capture. Automatic mode checks the latest eligible clipboard generation (plain text, or an image
when there is no plain text) when the app launches or returns to the foreground, subject to the system's Paste from Other Apps
permission. Undecided and explicit-only modes do not inspect the clipboard. Yank does not
continuously read the clipboard while suspended. The share extension and Save Clipboard
action capture only the item you explicitly provide. The keyboard does not capture clipboard
content.

Retention limits and automatic deletion are controlled in Settings. Pinned, bookmarked, or
tagged clips are retained until you remove their protection or delete them.

## Optional iCloud sync

iCloud sync is off by default. If you enable it, the following are stored in your private
CloudKit database so your Yank devices can reconcile history:

- clip text and images, including large clips that are stored as separate files;
- the name of the app a clip was copied from;
- tags, including AI-suggested tags, and text recognized in images (OCR);
- pin and bookmark flags;
- timestamps and deletion marks, so deletions reach your other devices;
- your history-limit and retention settings; and
- a random identifier, generated once for each Yank installation, that is attached to every
  synced clip to show which of your devices created it. It is a random value, not derived
  from your name, Apple ID, or hardware.

Rich pasteboard archives are not synced.

Clip text, the name of the source app, tags (including AI-suggested tags), text recognized in
images, and the search index Yank builds from them are stored in an end-to-end encrypted
CloudKit field. Apple cannot read that field; it can only be decrypted with a key held in your
iCloud Keychain. This applies once every device signed in to your iCloud runs a Yank version
that reads that field:

- While you update your devices, Yank also keeps a readable copy of the same fields in
  iCloud, so older versions of Yank keep working. Apple can read those copies.
- Yank stops writing readable copies, and then erases the ones already in iCloud, after at
  least 14 days since your first updated device reported in and when it has seen no activity
  from an older version of Yank in the last 60 days. Settings shows how far this has come.
  Yank cannot see an older device that only reads your clips, so it cannot be certain that
  every device is updated.
- A device that still runs an older version of Yank and stays signed in cannot read the
  encrypted field. It shows clips without their text, and when it saves a clip it can put a
  readable copy back into iCloud. Yank erases that copy once; if the older device writes it
  again, Yank leaves it and Settings tells you to update that device.

Some information stays readable by Apple so sync can work: the type of each clip, its
timestamps, deletion marks, pin and bookmark flags, sizes, file names, the time AI tags were
added, your history-limit and retention settings, and the random installation identifier
described above, which is also the name of that installation's small device record in
iCloud.

Images and large text are stored as CloudKit assets. Yank does not add its own encryption to
them. CloudKit encrypts assets by default: Apple's documentation states that CloudKit
"encrypts each chunk before storing it in the third-party services" and that it "ultimately
encrypts the asset data to a key in the user's iCloud Keychain." Only the first 500
characters of a large text clip, a preview, are kept in the end-to-end encrypted field.

If you lose access to your iCloud Keychain, for example after resetting your encrypted data,
the encrypted copy in iCloud can no longer be read. Yank then uploads your clips again from
the history on your devices.

Yank's maintainer cannot access your private database. Apple processes the synchronized data
under your iCloud account and Apple's terms.

Source: Apple, "Encrypting user data" (CloudKit documentation).

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

Spotlight indexing is opt-in and works the same way on macOS, iPhone, and iPad. When
enabled, a short excerpt of each text clip, its first non-empty line up to 100 characters, is
added to the device's system search index. The rest of the clip is not indexed. Turning the
setting off removes Yank's Spotlight index.

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
- choose automatic foreground capture or explicit-only capture on iPhone and iPad;
- keep iCloud sync, Spotlight indexing, and background tag suggestions off;
- delete individual clips or clear history from Settings;
- choose whether iPhone and iPad device backups include your clip history (off by default);
- disable the keyboard or share extension in system settings; and
- clear history before uninstalling when you want local clip records removed.

When iCloud sync is enabled, clip deletions are synchronized to your other Yank devices.
Removing the app alone may leave application support files managed by the operating system
and does not guarantee deletion of records already stored in iCloud. You can manage iCloud
application data through your Apple account settings.

On iPhone and iPad, Yank asks the system to leave your clip history, deletion log,
attachments, keyboard copy and share inbox out of device backups unless you turn on Include
History in Device Backups in Settings. iOS treats this as a request, not a guarantee. Yank's
preferences and sync bookkeeping are always part of a device backup. The setting stays on the
device and is not synced. After a restore from a backup that left history out, a device with
iCloud sync on gets recent clips back through sync, up to your history limit; with sync off, it
starts without history.

## Security and contact

On a device running this version, Yank skips pasteboard entries that source apps mark as
concealed, transient or auto-generated, including the older markers used by 1Password and
some text expanders, and supports capture exclusions. On the Mac, an excluded app also
covers the last half second, so a very fast switch away from or into it skips the copy. iOS
cannot see which app wrote the clipboard, so it honours the markers but cannot exclude by
app. These safeguards reduce accidental capture but cannot classify every piece of
sensitive content, and a device still running an earlier version may capture such copies
and sync them, so review clipboard history before sharing a device or backup.

For security vulnerabilities, use the private reporting instructions in
[`SECURITY.md`](SECURITY.md). For general privacy questions or product support, follow the
contact instructions in [`SUPPORT.md`](SUPPORT.md) without including private clipboard
content in a public issue.

Material changes to this policy will be published in this repository with a revised
effective date.
