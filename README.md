# Codex Usage

Codex Usage is a native macOS menu bar app for monitoring Codex quota usage.
It shows remaining quota and reset times without opening a browser.

The menu bar view shows:

- 5-hour quota remaining and reset time
- Weekly quota remaining and reset time
- Current account and plan when Codex reports them
- Manual refresh and configurable auto-refresh

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

## Data Sources

Codex Usage uses the OAuth API source by default. It reads Codex ChatGPT OAuth
tokens from `~/.codex/auth.json` or `$CODEX_HOME/auth.json`, then calls the
ChatGPT usage endpoint.

CLI RPC is available from Settings. That mode starts a local
`codex app-server --listen stdio://` process and reads rate-limit data through
JSON-RPC.

## Privacy

Codex Usage reads Codex credentials only from `~/.codex/auth.json` or
`$CODEX_HOME/auth.json`. The app uses those tokens to call ChatGPT/OpenAI usage
and OAuth refresh endpoints. When tokens are refreshed, the app writes them
back to the same local auth file with owner-only permissions.

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
