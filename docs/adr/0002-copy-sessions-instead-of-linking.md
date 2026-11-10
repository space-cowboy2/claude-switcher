# 0002. Copy session records between account folders instead of linking them

Status: accepted, 2026-11-09. Replaces the first design, which symlinked the folders.

## Context

Code sessions are stored as `claude-code-sessions/<account>/<org>/local_<id>.json` under each
profile [C]. Two accounts therefore have two folders and two lists. A record holds no account id,
so the same file in another account's folder is that account's session [C]; the conversation
itself is in `~/.claude/projects`, which both profiles already share [V].

The obvious way to get one list is to make both folders the same folder with a symlink. It does
not work: before every save the app opens the folder with `O_NOFOLLOW`, so a symlinked folder
lists sessions but every save fails [C, reproduced outside the app]. A symlink one level up only
helps when both accounts are in the same organisation. Per-file links are replaced by the app's
atomic rename on first save.

## Decision

Copy records. Every `<account>/<org>` folder in every profile is a replica holding the full list.
Sync runs only while no configured profile is running: at each switch, and when the menu bar app
sees Claude quit.

Rules: the newest copy of a session wins. A manifest of what each folder held at the last sync
turns "missing now" into "deleted there"; deletions propagate unless another copy changed since.

Every folder is a replica, including ones the app created in passing, so the tool never has to
guess which folder a profile will use after sign-in.

## Consequences

- A list goes stale if Claude is opened within the few seconds before a sync finishes.
- Running both profiles at once means last writer wins on a record. Not prevented.
- Deletion needs safety nets, because a manifest plus an emptied folder would otherwise delete
  everything: a folder that lost all records is treated as reset; a sync that would delete more
  than half the list (and more than 5) deletes nothing; every propagated deletion keeps a copy;
  the first sync backs up every folder. [V]
- Two accounts currently mean eight replica folders, about 7 MB each. [V]
- Deleting a session on the default profile still deletes the shared transcript, because that
  profile cannot see the second profile's records as claims. [C] Open; see the plan.
