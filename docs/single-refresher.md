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

## Installing this build (do these in order)

The old build is still a second refresher while it runs, and it keeps
rewriting `~/.claude/.credentials.json` (last seen 2026-10-10 23:53).

1. **Quit the old tracker** (menu bar → Quit) BEFORE launching the new one.
   The new build quits itself if another instance with the same bundle id is
   running, so an old copy left running wins and nothing changes.
2. **Delete `~/.claude/.credentials.json`.** It is a plaintext copy of a
   login the old build wrote at switch time; it is stale (the keychain has
   rotated since) and nothing reads it any more. The tracker never writes it
   again and only touches its mtime as a reload signal when the file exists.
3. **Re-import each account's main login with `claude-usage-login`**
   (`CLAUDE_CONFIG_DIR=~/.claude-import claude`, `/login` as that account,
   `/exit`). Logins the old build stored for PINNED profiles may be copies of
   the lineage their `cca` sessions use; this build refuses to write such a
   login into the shared entry (`MainLoginSwapPolicy.distrust`) until it has
   been re-imported — the notification says "run claude-usage-login as this
   account once". Wait for the login session to exit: the import is picked up
   only once no `claude` runs in `~/.claude-import`.
4. Install the keychain watcher (`tools/keychain-mdat-watch` in claude-rotate)
   and check after a day that every `Claude Code-credentials*` item has one
   writer.

### What to expect on this laptop

While the happy daemon's remote sessions run, a Claude Code without
`CLAUDE_CONFIG_DIR` is always running (measured 2026-10-11: nine live holders,
all launched by `claude_local_launcher.cjs` as
`~/.local/share/claude/versions/<semver>`), so the shared login is always held
and **the main-login swap will almost never apply on this machine**. That is
the intended outcome, not a bug: the alternative was a swap under those
sessions, which is what logged them out. Rotation reaches new work through
`cca auto` and the cloud launcher, both of which pick the account the tracker
selected; the menu-bar click still records the selection and will apply the
shared login on the rare occasion nothing holds it.

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

   Guards around the write: the resolved keychain entry must be the shared
   login's (`Claude Code-credentials` or `Claude Code-credentials-<sha256(~/.claude)[:8]>`;
   a pinned, per-config-dir entry is refused even if `resolveServiceName`
   landed on it); switches are serialised by an async mutex, so two cycles
   never refresh one stored login twice; processes are re-scanned right after
   the write and any holder that appeared in the window is logged and raises a
   time-sensitive notification ("Check Claude Code's login") naming both
   accounts; a pending switch is dropped after 24 h.

## Why not keep the live swap

A swap under running sessions can only be made safe by every session reloading
the keychain at once and none of them ever writing back — neither is something
the tracker can verify. Refusing while sessions run is the only rule that
leaves one holder per login.

**The cost, stated plainly:** while any bare `claude` (or happy-launched
Claude Code without `CLAUDE_CONFIG_DIR`) is running, auto-switch does NOT
change the account those sessions use. They stay on their account — at the
limit, if that is why the switch fired — until they exit. Rotation reaches
new work only: `cca` / `cca auto` and the cloud launcher. If the operator
wants a running session on the new account, the move is `/exit` and `cca`.

## Holder-scan blind spots

`sharedLoginHolders` sees what `ps -axwwE` on THIS machine shows for this
user. It cannot see:

- Claude Code on another host (littlewing's sessions use littlewing's keychain;
  the laptop tracker never writes it, so they are safe but also never
  rotated by the laptop — rotation there is the selection file plus its own
  per-dir logins).
- Processes of another macOS user, or processes whose environment `ps -E`
  cannot read (hardened processes hide `envp`; such a `claude` is counted
  as a holder anyway, because an unreadable env has no `CLAUDE_CONFIG_DIR`
  and so passes the holder test — the failure mode is a refused switch, not
  a wrong write).
- A Claude Code binary under a name this policy does not recognise AND not
  launched by `happy`/Claude.app. Recognised: argv0 basename `claude`,
  `…/claude/versions/<semver>`, `@anthropic-ai/claude-code/cli.js`, and any
  child of a known launcher. Anything else is invisible; the re-scan after
  the write catches only the recognised shapes too.
- A `claude` that starts between the scan and the write (~100 ms). The
  re-scan reports it and the notification tells the user which session to
  check; the keychain-mdat log shows whether two writers followed.
- Short-lived probes (`claude auth status`, `claude -p`) that start and exit
  between cycles.

## Tests

- `MainLoginSwapPolicyTests` — process-list parsing, who counts as a holder,
  the compare-and-swap decision.
- `SingleRefresherTests` — with `security` and the token endpoint replaced by
  recorders: pinned read-only (A1), no active refresh (A2), refusal while a
  bare session runs / over an unknown login, in-place `-U` write with no
  delete, refresh only after the guard passes, no plaintext mirror (A4).
- `AutoSwitchSelectionTests` — the selection file format carries no token.
