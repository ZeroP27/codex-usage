# Codex Usage

Native macOS menu bar app for Codex quota monitoring.

By default the app reads the Codex ChatGPT OAuth tokens in `~/.codex/auth.json`
and calls the ChatGPT usage endpoint for:

- 5-hour quota remaining and reset time
- Weekly quota remaining and reset time

CLI RPC remains available from Settings. That mode starts a local
`codex app-server --listen stdio://` process and reads the same rate-limit data
through JSON-RPC.

The monitor does not read browser cookies or legacy local usage databases.

## Run

```bash
./script/build_and_run.sh
```

Use `./script/build_and_run.sh --verify` to build, launch, and confirm the app
process is running.

## Package

Direct distribution outside the Mac App Store requires a Developer ID
Application certificate and notarization.

Create a notarytool profile once:

```bash
xcrun notarytool store-credentials codex-usage-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Build, sign, notarize, staple, and zip a release:

```bash
./script/package_release.sh \
  --version 1.0.0 \
  --build 1 \
  --sign-identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile codex-usage-notary
```

By default the release script builds a universal app for Apple Silicon and
Intel Macs. The signed app and zip are written to `dist/release/`.

For local packaging checks only:

```bash
./script/package_release.sh --version 1.0.0 --build 1 --unsigned
```

To build a single architecture package:

```bash
./script/package_release.sh --version 1.0.0 --build 1 --unsigned --arch arm64
```

## Author

ZeroP27

GitHub: https://github.com/ZeroP27

## License

MIT License. See `LICENSE`.
