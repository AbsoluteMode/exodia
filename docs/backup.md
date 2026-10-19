# Backup and recovery

Your working data stays on your Mac. **Settings → Backup** adds an optional,
independently encrypted copy in your own GitHub repository or a folder you choose.
There is no Whytap account or backup server.

## Set up once

1. Choose **Back up**. Save the recovery code in a password manager that
   you can access after losing this Mac. Use **Copy to password manager**, then
   paste the saved code back to verify it. Keep it outside Whytap and its backup
   repository. Whytap does not know a way to recover a lost code.
2. Connect an existing GitHub CLI login, or supply a GitHub access token.
   Whytap uses a private repository named **Exodia-Backup** in your account.
   An existing repository needs Contents read and write permission; creating
   the repository also needs Administration read and write permission. The
   GitHub token and the recovery code serve different purposes.
3. Alternatively, choose a folder in iCloud Drive, another sync service or an
   external drive. Whytap checks the file saved there. **Saved to folder** does
   not prove that your sync service has uploaded it to another device.

Routine backups use a key cached in the local macOS Keychain. You do not enter
it after each change. Changes are saved locally first; automatic full backups
are coalesced and wait while you are recording, dictating or using the agent.
The displayed times distinguish a completed local backup from a checked copy
at the selected destination. Failed uploads keep the local version for retry.

Encryption happens before upload. A repository accidentally becoming public
exposes ciphertext, not your provider keys or Case values. Whytap pauses new
uploads to a public repository. A compromised account can still delete backups,
so an independent copy on another drive or in another account remains useful.
The latest 30 copied full versions are kept locally, along with every unsent
version and pre-restore copy. Local settings history keeps 300 versions.
Cloud transfers reuse unchanged files from earlier checked versions and periodically
write a standalone full version. Recovery follows those dependencies automatically.
Keep the backup repository intact, including older versions that newer ones need.
Remote versions are not automatically deleted; their storage and availability
remain subject to GitHub and your account's limits. Whytap does not use Actions.

## Recover after a lost Mac or set up another Mac

Open **Settings → Backup → Restore backup**, reconnect the source and enter
the recovery code from your password manager. This works without the old Mac's
Keychain. You can also open an `.exodiabackup` file directly.

Whytap checks the whole archive before showing its contents. Review its date,
size, included groups and warnings. Select what you need, then choose
**Restore selected items**. The restore applies when you next quit Whytap
normally and open it again. It does not force an interruption of active work.
Machine permissions are granted separately by macOS. You can cancel a planned
restore before quitting. During recovery, Whytap shows progress before opening
any workspace stores. If it cannot finish safely, it keeps the recovery files
and offers retry, your saved recovery code, and their Finder location.

Before applying a restore, Whytap keeps the data it will replace. Completed
restores retain each previous generation on this Mac; **Show all copies**
opens their common folder in Finder. Older recovery copies stay there until
you remove them. A failed rollback preserves its transaction for retry and
keeps the workspace closed until its state can be proven safe.

Case items are merged with the target Mac's vault and encrypted using that
Mac's own local vault key. Unrelated existing Case items are retained. Imported
notification sources and monitoring connections stay disabled until reviewed.
Unprocessed recordings are recovered without automatically resuming another
Mac's remote provider jobs.

A backup is a version you can recover. It does not continuously merge edits
between two Macs.

## Change a lost or exposed code, or delete backups

The main screen has **Back up** and **Restore backup**. Expand **Manage backups**
for scheduling, connection details, **Change code…** and **Delete backups…**.
There is no registration step or Whytap account badge.

**Change code…** works while this Mac still has its cached key; entering the old
code is unnecessary. Save and paste back the new random code. Whytap pauses
automatic backups, creates a standalone full archive with the new key, checks
it locally and at the connected destination, then removes older full backups
from this Mac and that destination. A failed upload keeps the old copies. A
failed deletion remains visible and paused; **Finish backup management** resumes
the durable request. Reopening Whytap attempts it once when idle; a failed
attempt stays paused with an explicit retry. The new key stays in
Keychain; the operation journal never contains it. Your previous automatic
backup preference is restored only after cleanup succeeds.

**Delete backups…** removes full local archives and the connected destination's
archives, including unfinished GitHub drafts, then leaves automatic backup off.
It retires the exposed code for future setup without asking you to save another
one. Your working data, automatic local settings history and existing restore
transaction checkpoints stay on this Mac. History keys remain only in this
Mac's Keychain so a code change does not destroy the ability to undo settings.
The GitHub repository, tags, source history and unrelated releases/files are kept.
Explicit deletion also works if the backup repository became public.

If a destination is permanently lost or a catalog cannot be read, **Stop…**
ends the unfinished request after confirmation. It does not claim deletion:
a persistent warning identifies copies that may remain. Remaining local files,
keys and the original request/catalog are kept; **Show kept local copies…**
opens their folder. Automatic backup stays off and a fresh code must be saved
before starting again. Kept old-key copies are excluded from future automatic
uploads and delta bases. The warning stays until you dismiss it, including if
you start using a different destination.
Parked request/catalog metadata and its staged key remain for manual recovery,
even after later archive deletion. The request records the key identifier;
the secret itself stays in Keychain. These records contain no archive content
and remain until you remove them separately.

Both management actions include full **Before restore** archives. The separate
restore transaction checkpoints described above are retained. Credential and
connection removal has a durable finalization phase, so interruption after
disconnect does not require access to the previous destination to finish.

Stop automatic backups on other Macs before either action. Copies in previous
destinations, sync-provider trash/version history and exported or downloaded
archives need separate removal. A downloaded archive cannot be revoked: the old
code can still decrypt it. If an attacker may have obtained that archive and its
code, replace the provider keys and other secrets it contained at their sources.
Deleting a file does not promise physical erasure from SSDs or provider retention.
Losing both the code and every Mac with a cached key makes existing encrypted
archives unrecoverable; neither GitHub nor Whytap can reset their encryption.

## What is included

- API & Models routes for every feature, registered server addresses, languages,
  meeting preferences, hotkeys, vocabulary, Toolbox layout,
  display and feature settings, and agent preferences.
- Whytap's saved speech and text provider keys (including Anthropic and each
  registered custom server), and independently recoverable
  Case items and secrets.
- Meeting catalogs, notes and transcripts, plus retained unfinished recordings.
- Agent, Drop and clipboard history, including app-managed image bytes.
- App-owned Monitor dashboards, notification configuration and working files,
  and the neutral agent workspace's persistent instructions.

Clipboard file entries refer to external originals. Those original documents
are not owned by Whytap and are not copied by this feature. The same applies
to external scripts, SSH keys, model-provider accounts and credentials managed
by other applications. Review archive warnings for those references. Downloaded
models, binaries, caches, logs, obsolete project indexes and OS permissions are
not part of the portable workspace. Archives are bounded to 64 GiB in total,
8 GiB per file and 200,000 entries; a snapshot exceeding a bound is refused.
Imported directly executed notification workers may need their executable
permission and machine-specific paths reviewed before re-enabling a source.

## Undo a settings mistake

Local encrypted settings history works without cloud setup. Expand **Undo a
settings change → Local Settings History**, choose a block and a saved version,
then confirm **Restore block**.
Provider keys have a separate history selection; restoring another settings
block leaves them untouched. **Restore defaults** uses the application's
source defaults for the selected settings block. Both apply at the next normal
launch, with the previous values kept for recovery.

The **API & Models · languages** block restores the exact saved routes and
server registrations. Its source reset leaves AI routes **Not set**, so the old
Models-tab choices cannot silently reappear on relaunch. Provider keys stay in
their separate block. Archives made before API & Models preserve any routes
already configured on the target Mac; on a fresh Mac the normal one-time
migration can carry over their old provider choices.

If a routing document is damaged or partly unreadable, its original value and
any older unreadable copy are preserved inside the encrypted backup. Readable
servers and all other artifact groups can still be saved. The preview warns
when keys for unreadable server entries could not be included. Restored routes
never rerun migration from old choices. Reset keeps the preserved values in the
local recovery checkpoint before clearing the block. Settings-history snapshots
are bounded to 1 MB of plaintext in total; unusually large configurations are
refused with an error instead of being truncated.

If an archive is damaged, incomplete, or needs a newer version of Whytap, it
is refused. Choose another saved version or update Whytap. Losing every copy
of the data or every recovery method cannot be repaired by encryption.
