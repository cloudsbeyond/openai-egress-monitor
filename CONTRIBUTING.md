# Contributing

Thanks for considering a contribution.

## Development

Requirements:

- macOS 14 or newer
- Swift toolchain / Xcode Command Line Tools

Run checks:

```sh
swift run OpenAIEgressCoreCheck
swift build -c release --product OpenAIEgressStatus
```

Install a local build:

```sh
./install.sh
```

Uninstall:

```sh
./uninstall.sh
```

## Pull Requests

- Keep the app local-first. Do not add telemetry.
- Do not commit local logs, `.build/`, `.DS_Store`, or generated `.app` bundles.
- Keep provider adapters small and deterministic.
- Add or update `OpenAIEgressCoreCheck` coverage for parser and policy changes.

## Trademark Note

OpenAI and ChatGPT are trademarks of their respective owners. This project is not affiliated with, endorsed by, or sponsored by OpenAI.
