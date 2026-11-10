# Plan

Milestones and issues for everything in [spec.md](spec.md) that is open, unproven or not built.
The issues are the source of truth for scope, acceptance criteria and verification steps;
this page is the order to do them in.

Priorities: **P0** blocks the main goal, **P1** important, **P2** can wait.
Issues labelled `verification` change no behaviour by themselves: they turn an assumption in
the spec into a fact, and close with the evidence in a comment.

## [M1 · Prove it live](https://github.com/space-cowboy2/second-wind/milestone/1)

Everything that can be checked or built today without waiting for a real usage limit. Exit: hooks seen firing on both profiles, a simulated limit switches the real profiles and the session continues there, the terms question is answered, app internals re-checked on the current version.

| Issue | What | Priority | Kind | Needs |
| --- | --- | --- | --- | --- |
| [#1](https://github.com/space-cowboy2/second-wind/issues/1) | Confirm the two hooks fire in real desktop sessions on both profiles | P0 | verification | – |
| [#2](https://github.com/space-cowboy2/second-wind/issues/2) | Limit drill on the real profiles with a simulated event | P0 | verification | – |
| [#3](https://github.com/space-cowboy2/second-wind/issues/3) | Continue a session on the other account, for each kind of session | P0 | verification | [#2](https://github.com/space-cowboy2/second-wind/issues/2) |
| [#4](https://github.com/space-cowboy2/second-wind/issues/4) | Decide whether second-account use is within Anthropic's terms | P0 | decision | – |
| [#5](https://github.com/space-cowboy2/second-wind/issues/5) | Re-check the app internals the tool relies on, on the current app version | P1 | verification | – |
| [#6](https://github.com/space-cowboy2/second-wind/issues/6) | `secondwind doctor`: check the whole installation in one command | P1 | ops | [#1](https://github.com/space-cowboy2/second-wind/issues/1) |

## [M2 · Limit handling hardened](https://github.com/space-cowboy2/second-wind/milestone/2)

Behaviour at real limits. Parts of it wait for a real limit to occur. Exit: a real limit payload is a test fixture, the tool avoids switching to an exhausted account, and the app's own auto-resume is understood.

| Issue | What | Priority | Kind | Needs |
| --- | --- | --- | --- | --- |
| [#7](https://github.com/space-cowboy2/second-wind/issues/7) | Capture a real `StopFailure` usage-limit payload and make it a test fixture | P1 | limits | [#1](https://github.com/space-cowboy2/second-wind/issues/1) |
| [#8](https://github.com/space-cowboy2/second-wind/issues/8) | Do not switch to an account its own usage history shows as exhausted | P1 | limits | – |
| [#9](https://github.com/space-cowboy2/second-wind/issues/9) | Settle how the app's own limit auto-resume interacts with a switch | P1 | limits | [#7](https://github.com/space-cowboy2/second-wind/issues/7) |
| [#10](https://github.com/space-cowboy2/second-wind/issues/10) | Handle weekly and model-specific limits differently from the five-hour limit | P2 | limits | [#7](https://github.com/space-cowboy2/second-wind/issues/7) |
| [#11](https://github.com/space-cowboy2/second-wind/issues/11) | Option to hold the automatic switch while a session is driven remotely | P2 | limits | [#1](https://github.com/space-cowboy2/second-wind/issues/1) |

## [M3 · Sync completeness and safety](https://github.com/space-cowboy2/second-wind/milestone/3)

Close the gaps in the shared list. Exit: no way to strand or lose a session by ordinary use, and a one-command way back from the backups.

| Issue | What | Priority | Kind | Needs |
| --- | --- | --- | --- | --- |
| [#12](https://github.com/space-cowboy2/second-wind/issues/12) | Make sure deleting a session on one account cannot strand it on the other | P1 | sync | – |
| [#13](https://github.com/space-cowboy2/second-wind/issues/13) | `secondwind restore`: bring sessions back from the backups | P1 | sync | – |
| [#14](https://github.com/space-cowboy2/second-wind/issues/14) | Make two profiles running at once impossible to miss | P1 | sync | – |
| [#15](https://github.com/space-cowboy2/second-wind/issues/15) | Investigate sharing sidebar sections, pins and stars across accounts | P2 | sync | – |
| [#16](https://github.com/space-cowboy2/second-wind/issues/16) | Seed only the account folders that are in use | P2 | sync | [#1](https://github.com/space-cowboy2/second-wind/issues/1), [#12](https://github.com/space-cowboy2/second-wind/issues/12) |

## [M4 · Upkeep and distribution](https://github.com/space-cowboy2/second-wind/milestone/4)

Keep it working across app updates and make it installable without edits. Exit: CI on every push, an update check, a documented exit if the app ships its own switcher.

| Issue | What | Priority | Kind | Needs |
| --- | --- | --- | --- | --- |
| [#17](https://github.com/space-cowboy2/second-wind/issues/17) | CI: run the tests on every push | P1 | ops | – |
| [#18](https://github.com/space-cowboy2/second-wind/issues/18) | Notice a Claude update and re-run the internals check | P2 | ops | [#5](https://github.com/space-cowboy2/second-wind/issues/5), [#6](https://github.com/space-cowboy2/second-wind/issues/6) |
| [#19](https://github.com/space-cowboy2/second-wind/issues/19) | Detect the app's built-in account switcher and plan the exit | P2 | ops | – |
| [#20](https://github.com/space-cowboy2/second-wind/issues/20) | Remove the hardcoded identifier and give the tool a version | P2 | ops | – |

## Where to start

1. [#1](https://github.com/space-cowboy2/second-wind/issues/1), [#2](https://github.com/space-cowboy2/second-wind/issues/2) and [#4](https://github.com/space-cowboy2/second-wind/issues/4) need nothing else and can be done today. The first two take one sitting at the Mac.
2. [#3](https://github.com/space-cowboy2/second-wind/issues/3) follows straight on from the drill.
3. [#5](https://github.com/space-cowboy2/second-wind/issues/5) and [#6](https://github.com/space-cowboy2/second-wind/issues/6) are the first code changes.
4. [#7](https://github.com/space-cowboy2/second-wind/issues/7) has a part that can be built now and a part that waits for a real usage limit. Nothing in the first milestone waits on that.

## Not planned

Listed so they are not rediscovered as gaps. Reasons are in the spec's exclusions.

- Sending "continue" automatically after a switch.
- More than two accounts in the menu.
- Sharing connectors, scheduled tasks, Cowork sessions or Remote Control links between accounts.
- Patching the Claude app.
- Notarised distribution to other people.
