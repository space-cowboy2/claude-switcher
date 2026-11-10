# Contributing

This is a one-person tool. These are the rules its owner and any assistant working on it follow.

## Before changing anything

Read [docs/spec.md](docs/spec.md). It marks what is verified, what was only read from the app's
code, and what is assumed. If a change rests on an assumption, the change includes the check that
turns it into a fact, or says plainly that it does not.

## Ground rules

1. **No credentials.** Never open cookie stores, token caches or the keychain; never log or commit
   an account id, organisation id, email address or token. Use placeholders in docs and tests.
2. **Never experiment on the real profiles.** Use throwaway profiles:
   `secondwind --home <tmp> …` with a config whose two `dataDir`s are temp folders. The main
   app keeps running untouched. The real profiles are for the owner's live checks only.
3. **Sync and switch logic lives in `SwitchCore`** and is tested without the real app, through the
   `System` protocol. The CLI and the menu bar app stay thin.
4. **Anything that reads the app's internals is listed** in section 8 of the spec with its
   evidence mark. Add to the list when you add a reliance.
5. **Nothing destructive without a net.** Deleting or overwriting inside a profile needs a backup
   path and a test for the accident case.

## Workflow

- One branch per issue; name it `<type>/<short-name>` (`fix/…`, `feat/…`, `docs/…`, `verify/…`).
- One commit per meaningful change. The body says what changed, why, and what triggered it (issue
  number or finding).
- `swift test` passes before every commit that touches `Sources/` or `Tests/`.
- Changes to quit, launch or hook handling also get an integration run on throwaway profiles;
  paste the output in the pull request.
- Add a line to [CHANGELOG.md](CHANGELOG.md) under "Unreleased" for anything a user would notice.
- A design decision gets a record in [docs/adr/](docs/adr/).
- Verification issues close with evidence in a comment: the command, its output, the app version.

## Layout

| Path | What |
| --- | --- |
| `Sources/SwitchCore/` | Model and store, session sync, switch engine, limit rules, hook installer |
| `Sources/secondwind/` | Command-line tool and hook entry points |
| `Sources/SecondWindBar/` | Menu bar app |
| `Tests/SwitchCoreTests/` | Unit tests; `Support.swift` has the fake system and temp-folder world |
| `scripts/` | Install and uninstall |
| `docs/` | Spec, plan, decision records |
