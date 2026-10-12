# Refreshing stored logins to read inactive profiles' usage: shelved

Status: **shelved 2026-10-11.** This branch (`fix/usage-all-accounts`, tip before this doc: b684392) is not to be installed. The installed tracker stays at 8d67e91. It refreshes no stored login for usage reads.

Why it was shelved: three fable gate rounds in a row found a logout-class defect. The operator's top priority is never being logged out. Mission control also already gets fresh readings without this change: littlewing's read-only `usage-self` lane (tools/mission-control, `bridges/usage_self.py`) has no refresh code at all and passed its gate.

## The problem it tried to solve

After the single-refresher fix (e33cdb7), the app reads only the active profile live. An inactive profile reads usage through its pinned entry: the `Claude Code-credentials-<hash>` item of its claude-rotate config dir. When that entry's access token expires, the profile shows "no live credential; showing last-known cached usage". Its reading then ages for hours, and mission control's launcher refuses the account as stale.

## The design (option B)

Each inactive profile also keeps a stored copy of its own main login. `claude-usage-login` imports it and deletes the import dir's item; a switch captures it from the keychain. The design reads usage with that stored copy (`storedLoginForUsage`):

- A valid access token is used as it is. Reading usage rotates nothing.
- An expired token is refreshed only when the app is provably the only holder:
  - the profile is inactive;
  - the login is its own and its origin is known (`import` or `keychain`);
  - the token is not marked dead;
  - its refresh token is in no `Claude Code-credentials*` keychain item (all of them are listed and read) and not in the plaintext credentials files;
  - the shared login is provably another account's.
- The refresh runs under the switch mutex and persists the rotated login.

The premise came from reading the Claude Code 2.1.296 binary. Claude Code refreshes under `<configdir>/.oauth_refresh.lock` and re-reads its storage first. If the token in storage has changed, it adopts that token instead of posting a refresh (`tengu_oauth_token_refresh_race_resolved`). So Claude Code only ever posts a refresh token that is in its storage at that moment. A refresh token in none of Claude Code's storage therefore has no other holder.

## What the gates found

1. **eb9a916: two criticals.**
   - A refused switch can leave the shared item on an inactive account, rotated past its stored copy by the sessions using it. The stored refresh token is then in no item, yet it is a spent rotation of a live lineage, and refreshing it is reuse. Fix: refuse unless the shared login is provably another account's.
   - An item with no parseable refresh token was counted as "holds nothing". It is a refusal.
   - Warnings: an item that vanishes between listing and reading, reloading the in-memory profiles after a persist, and the claims the docblock made about the plaintext file.
2. **3da38bd: one critical.** When the shared login's account lookup failed (idle expired access token, or offline), identity fell back to `~/.claude.json`'s `oauthAccount`. After a `/login` that file can name the previous account. The gate's probe got `refreshCalls=1`. Fix: only a `.resolved` lookup decides. Also: `readCredentialsFile()` silently skipped an invalid-JSON file, so the holder scan treated it as "holds nothing".
3. **b684392: one critical.** The capture paths also attribute the shared login through the same `.claude.json` fallback: `systemCredentials(_:belongTo:)`, `syncToProfile` and `resyncBeforeSwitching`. So goose's live login can be persisted under main's profile, and `storedLoginForUsage` would later refresh a spent rotation of goose's lineage. The defect is upstream of option B: the stored copy's attribution was not proven.

## Lessons for a fresh design

- **Attribution.** "The stored copy is this app's alone" only holds if every path that stores a login proves which account it belongs to. That means an equal refresh token, or a resolved account lookup. It never means a cache such as `.claude.json`. The installed app is being hardened on its own branch for this: `fix/capture-proven-identity`, off 8d67e91.
- **Unknown must refuse,** at every step:
  - the item list cannot be made;
  - an item is unreadable, unparseable or vanishes;
  - an account lookup is unresolved;
  - a plaintext file is invalid.
- **Freshness of the stored copy.** It is only safe to refresh if it is the head of its lineage. A switch's compare-and-swap guarantees that at the moment of the switch. Nothing guarantees it afterwards if a capture or a refused switch leaves a newer rotation somewhere.
- **A safer shape to consider first:** never refresh outside Claude Code at all. Read only with valid access tokens, as littlewing's `usage-self` does, and let Claude Code's own launches refresh. If the laptop app must cover idle accounts, it could trigger a real Claude Code refresh, which takes Claude Code's own lock, rather than posting the grant itself.

## Where the code is

- `Claude Usage/Shared/Services/ClaudeCodeSyncService.swift` on this branch:
  - `storedLoginForUsage`
  - `claudeCodeHolder(ofRefreshToken:)`
  - `sharedLoginMayBeThisAccount`
  - `resolvedLoginAccountUuid`
  - the seams `claudeCodeServiceLister`, `storedProfileLoader`, `storedLoginPersister` and `configOAuthAccountReader`
- `AnthropicUsageProvider.swift`: priority 2b.
- `Claude UsageTests/StoredLoginUsageTests.swift`: 18 tests, including the probes from each gate.
