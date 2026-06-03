# Codex Usage

Codex Usage is a native macOS menu bar app for monitoring Codex quota usage.
It shows remaining quota and reset times without opening a browser.

The menu bar view shows:

- 5-hour quota remaining and reset time
- Weekly quota remaining and reset time
- Managed ChatGPT accounts with current account and plan
- Current-account refresh, all-account refresh, manual account switching, and configurable auto-refresh

## Requirements

- macOS 14 or later
- Swift 6 toolchain or Xcode Command Line Tools
- Codex CLI available for adding accounts through `codex app-server`
- Google Chrome for managed account login, opened in an incognito window

## Build And Run

```bash
./script/build_and_run.sh
```

Use `./script/build_and_run.sh --verify` to build, launch, and confirm the app
process is running.

To create a local unsigned app bundle and zip:

```bash
./script/package_release.sh --version 1.0.0 --build 1 --unsigned --arch host
```

Build output is written to `dist/`.

## Release Automation

GitHub Actions publishes releases when a version tag such as `v0.3.0` is
pushed, or when the Release workflow is run manually with a version. The
workflow builds separate macOS packages for Apple Silicon and Intel:

- `Codex-Usage-<version>-aarch64.zip`
- `Codex-Usage-<version>-x86_64.zip`

Release notes list commit-derived changes, download names, and SHA-256 checksums.

## Data Sources

Codex Usage uses the Managed Accounts source by default. Accounts are added from
Settings. The app starts `codex app-server --listen stdio://` with a temporary
`CODEX_HOME`, opens the ChatGPT login URL in a Google Chrome incognito window,
and stores the resulting auth snapshot under:

```text
~/Library/Application Support/Codex Usage/accounts/
```

The account registry is `registry.json`; each account auth snapshot is stored as
`<account_key>.auth.json`. Account files are written with owner-only
permissions. The app does not read or write `~/.codex/accounts`.

The app does not auto-switch accounts when a quota threshold is reached. Account
switching is manual: choosing an account first captures the current
`~/.codex/auth.json` back into its managed snapshot when it belongs to a managed
account, then copies the chosen account snapshot into `~/.codex/auth.json` and
updates the active account in the Codex Usage registry.

Configured auto-refresh intervals are jittered around the selected interval
instead of firing at an exact fixed cadence. Automatic and stale menu refreshes
read quota for the current active account without modifying `~/.codex/auth.json`.
The Accounts panel can manually refresh individual accounts or all managed
accounts. All-account refresh skips the current active account.

CLI RPC is available from Settings. That mode starts a local
`codex app-server --listen stdio://` process and reads rate-limit data through
JSON-RPC.

## Privacy

Codex Usage stores managed account credentials as local JSON files under its
Application Support directory. It uses those tokens to call ChatGPT/OpenAI usage
and OAuth refresh endpoints. When tokens are refreshed, the app writes them back
to the specific managed account snapshot being refreshed with owner-only
permissions. It syncs `~/.codex/auth.json` only when switching accounts or
adding a managed account. Quota refreshes do not write `~/.codex/auth.json`.

The app does not use Keychain for managed accounts and does not depend on
codex-auth.

The app stores local preferences in macOS UserDefaults: data source, refresh
interval, and optional Codex executable path. It does not include analytics,
telemetry, crash reporting, browser-cookie access, prompt-history access, or
third-party data collection.

## Author

ZeroP27

GitHub: https://github.com/ZeroP27

Repository: https://github.com/ZeroP27/codex-usage

## License

MIT License. See `LICENSE`.
