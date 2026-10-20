# Backup and recovery

Connect GitHub once in **Settings → Integrations → GitHub**. Use an existing
GitHub CLI login or an access token. Whytap checks or creates the private
**Exodia-Backup** repository. The connection status is also shown in Backup.
Connecting does not upload user data.

In **Settings → Backup**:

- **Back up** saves everything listed below, including stored provider keys,
  encrypts it locally and verifies the GitHub upload. Save the code shown after
  completion outside Whytap. The same code unlocks subsequent automatic backups.
  Once created, the backup synchronizes changes while Whytap is idle.
- **Restore backup** takes that code and prepares the newest complete GitHub
  backup, including all its settings, keys and data. Quit Whytap normally and
  open it again to apply it. Current data is kept for recovery.

There are no data-selection switches, code verification steps or confirmation
screens. Created GitHub backups synchronize automatically, including copies made
before automatic sync was introduced. Changes are checked every minute; uploads
are spaced at least two minutes apart and wait while recording or agent work is
active. Failed uploads keep their local copy and retry. Backup shows **Backup
synced** only after verification with no detected changes or copies waiting,
and links directly to the repository's GitHub Releases. Pending, syncing, paused
and error states have their own labels. Existing folder destinations and local
encrypted settings history are retained internally.
A previously interrupted management operation can still be finished or stopped.
Restored recording jobs and executable connections stay paused until enabled.

Encryption happens before upload. The recovery code is independent of GitHub
and cannot be reset by GitHub or Whytap. macOS permissions stay machine-specific.
A backup restores a saved version; it does not merge edits between Macs.
No Whytap account, backup server or GitHub Actions is used.

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

Case items are merged with the target Mac's vault and encrypted using that
Mac's own local vault key. Unrelated existing Case items are retained. When a
project or key name from the backup is already used by a different item on
this Mac, the restored one is renamed (`alpha (2)`, `DB_URL_2`); this Mac's
names stay as they are. Restoring also brings back the backup's Case app
registrations (which AI apps may ask for keys, Approve or Bypass) and adds
them without asking for Touch ID, including Bypass: an app registered with
Bypass in the backup can receive keys without a prompt after the restore.
Registrations this Mac already has keep their own settings. Review them in
Case -> access after restoring a backup you did not make yourself. Imported
notification sources and monitoring connections stay disabled until reviewed.
Unprocessed recordings are recovered without automatically resuming another
Mac's remote provider jobs.

Clipboard file entries refer to external originals. Those original documents
are not owned by Whytap and are not copied by this feature. The same applies
to external scripts, SSH keys, model-provider accounts and credentials managed
by other applications. Downloaded
models, binaries, caches, logs, obsolete project indexes and OS permissions are
not part of the portable workspace. Archives are bounded to 64 GiB in total,
8 GiB per file and 200,000 entries; a snapshot exceeding a bound is refused.
Imported directly executed notification workers may need their executable
permission and machine-specific paths reviewed before re-enabling a source.

A damaged or incomplete archive is refused before restore. Failed uploads
keep the local copy for retry. Existing copies are retained; the simplified
screen does not delete archives or rotate recovery keys.
