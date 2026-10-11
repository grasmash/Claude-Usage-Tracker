# One refresher per login

Claude Code OAuth refresh tokens are single-use. Every running `claude` keeps
its login in memory and refreshes it when it needs to. The moment two parties
hold one login's refresh token, the second one to use it is rejected
(`invalid_grant`), and whoever cached the old token is logged out ("Login
expired · Please run /login"). A session that still has the old login can also
write it back over whatever replaced it in the keychain.

The tracker used to be that second party in three places:

| Path | What it did | Now |
|------|-------------|-----|
| `ensureFreshCredentials` on a pinned profile | refreshed the `Claude Code-credentials-<hash>` entry within 60 s of expiry and wrote it back | read-only; an expired entry is reported as stale |
| `refreshIdleSystemLogin` | refreshed the shared login once it had been expired 15 min | deleted; `mayRefreshActiveLogin` is `false` |
| auto-switch (`applyProfileCredentials`) | delete+add of the shared keychain entry under running sessions, plus `~/.claude/.credentials.json` and `~/.claude.json#oauthAccount` rewrites | the guarded swap below; no plaintext mirror |

Whoever owns a config dir owns its login: `cca`/claude-rotate sessions and the
cloud watchdog own the pinned entries, bare `claude` sessions own the shared
one. The tracker only reads them.

## What auto-switch does now

Rotation means choosing which account's config dir new work uses, never copying
tokens.

1. **Selection file.** Every switch (automatic or by click) writes
   `~/.claude/.autoswitch-selected`:

   ```
   SELECTED_PROFILE=goose@example.com
   SELECTED_EMAIL=goose@example.com
   SELECTED_ACCOUNT_UUID=…
   SELECTED_AT=2026-10-10T23:40:00Z
   SELECTED_BY=auto
   ```

   `cca` (and `cca auto`) resolves the email to an account in
   `~/.claude-rotate/config.json` and starts the session in that account's own
   config dir. Nothing running is touched. The file is plain text with no
   token, so it can be synced to another host (littlewing) that has its own
   logins in the same account dirs.

2. **Shared login, only when idle.** The tracker still switches the shared
   login (what a bare `claude` uses) so the menu-bar click keeps meaning what
   it meant, but `ClaudeCodeSyncService.switchMainLogin(to:)` refuses unless
   all of these hold:
   - no `claude` process without `CLAUDE_CONFIG_DIR` is running
     (`ps -axwwE`, `MainLoginSwapPolicy.sharedLoginHolders`; `claude auth
     status` counts, it refreshes too);
   - the keychain holds a login the tracker has captured, or nothing
     (compare-and-swap on the refresh-token fingerprint — a `/login` the
     tracker has not adopted, or a rotation by an unknown refresher, is never
     overwritten);
   - the stored login is not already the one in the keychain.

   Only then is the stored login refreshed if expired (the tracker is its only
   holder at that moment) and written with one `add-generic-password -U`.
   Never delete+add. A refused switch stays pending: the tracker records the
   selection, notifies once ("N sessions are running… new sessions via cca use
   X"), and `applyPendingMainLoginSwitchIfSafe` retries every refresh cycle.
   When it finally applies, a notification says so.

3. **Adoption follows a `/login`, not the keychain.** The keychain may
   legitimately hold a different account than the tracker's active profile (a
   refused swap). `adoptExternalLoginIfNeeded` now reacts only when the
   keychain's *account changes*, which is what a `/login` does.

4. **Capture is read-only and account-keyed.** Each cycle the shared login is
   stored into whichever profile it belongs to (not just the active one), so
   the copy a later switch writes is the lineage Claude Code last rotated.

## Why not keep the live swap

A swap under running sessions can only be made safe by every session reloading
the keychain at once and none of them ever writing back — neither is something
the tracker can verify. Refusing while sessions run is the only rule that
leaves one holder per login. The cost is that already-running bare `claude`
sessions stay on their account until they exit; new work rotates through
`cca`.

## Tests

- `MainLoginSwapPolicyTests` — process-list parsing, who counts as a holder,
  the compare-and-swap decision.
- `SingleRefresherTests` — with `security` and the token endpoint replaced by
  recorders: pinned read-only (A1), no active refresh (A2), refusal while a
  bare session runs / over an unknown login, in-place `-U` write with no
  delete, refresh only after the guard passes, no plaintext mirror (A4).
- `AutoSwitchSelectionTests` — the selection file format carries no token.
