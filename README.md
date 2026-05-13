# Codex Usage

Codex Usage is a native macOS menu bar app for monitoring Codex quota usage.
It shows remaining quota and reset times without opening a browser.

The menu bar view shows:

- 5-hour quota remaining and reset time
- Weekly quota remaining and reset time
- Multiple codex-auth accounts with current account and plan
- Current-account refresh, all-account refresh, manual account switching, and configurable auto-refresh

## Requirements

- macOS 14 or later
- Swift 6 toolchain or Xcode Command Line Tools
- Codex signed in with a ChatGPT account

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

Codex Usage uses the OAuth API source by default. It reads codex-auth account
metadata from `~/.codex/accounts/registry.json` or
`$CODEX_HOME/accounts/registry.json`, then calls the ChatGPT usage endpoint with
each account snapshot under `accounts/`.

The app does not auto-switch accounts when a quota threshold is reached. Account
switching is manual: choosing an account copies the chosen account snapshot into
`~/.codex/auth.json` and updates the active account fields in the registry.

Configured auto-refresh intervals are jittered around the selected interval
instead of firing at an exact fixed cadence. Automatic and stale menu refreshes
refresh the current active account only; opening the Accounts panel refreshes
all managed accounts.

CLI RPC is available from Settings. That mode starts a local
`codex app-server --listen stdio://` process and reads rate-limit data through
JSON-RPC.

## Privacy

Codex Usage reads Codex credentials from `~/.codex/auth.json` and
`~/.codex/accounts/*.auth.json`, or the same paths under `$CODEX_HOME`. The app
uses those tokens to call ChatGPT/OpenAI usage and OAuth refresh endpoints. When
tokens are refreshed, the app writes them back to the specific account snapshot
being refreshed with owner-only permissions. It syncs `~/.codex/auth.json` only
when the refreshed account is the active account.

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
