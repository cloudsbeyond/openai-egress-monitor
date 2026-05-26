# EgressMonitor

EgressMonitor is a small macOS status bar app for checking network egress consistency.

It shows two views side by side:

- **Public Network**: the public IP and location returned by configurable IP geolocation providers
- **ChatGPT Edge**: the IP, country, and Cloudflare edge seen by `https://chatgpt.com/cdn-cgi/trace`

The menu bar title shows the ChatGPT trace country as a flag plus country code when available, for example `🇸🇬 SG`. If there is no flag mapping, it falls back to the uppercase country code.

## Features

- macOS status bar app packaged as `EgressMonitor.app`
- compact status menu with Refresh, Open Trace, Open Logs, Launch at Login, and Quit
- login startup through a user-level LaunchAgent
- country-change notifications for the ChatGPT trace path
- unexpected-country notifications when ChatGPT trace is outside configured countries
- configurable public IP provider chain with adapter-based parsing
- local JSONL history and latest-text status output
- no API key requirement

## Requirements

- macOS 14 or newer
- Swift toolchain / Xcode Command Line Tools for building from source

## Install

From the project directory:

```sh
./install.sh
```

Install with a custom refresh interval in seconds:

```sh
./install.sh 60
```

The installer builds the app and installs it to:

```text
~/Applications/EgressMonitor.app
```

It also creates a user-level login item:

```text
~/Library/LaunchAgents/com.local.egress-monitor.plist
```

You can toggle login startup from the status menu with `Launch at Login`.

## Configuration

Config lives at:

```text
~/Library/Application Support/openai-egress-monitor/openai-egress-monitor.conf
```

Default public IP probe chain:

```sh
PUBLIC_IP_PROBES="ipinfo-json|https://ipinfo.io/json;ipapi-json|https://ipapi.co/json/;ipwhois-json|https://ipwho.is/"
```

Supported public IP adapters:

- `ipinfo-json`
- `ipapi-json`
- `ipwhois-json`

The app tries probes in order and uses the first successful result.

Default ChatGPT trace countries considered acceptable:

```sh
EXPECTED_LOCS="JP SG"
```

## Logs

Latest status:

```sh
cat "$HOME/Library/Logs/openai-egress-monitor/latest.txt"
```

History:

```sh
tail -n 20 "$HOME/Library/Logs/openai-egress-monitor/openai-egress.jsonl"
```

## Development

Run core checks:

```sh
swift run OpenAIEgressCoreCheck
```

Build the app:

```sh
swift build -c release --product OpenAIEgressStatus
```

Uninstall a local installation:

```sh
./uninstall.sh
```

## Privacy

EgressMonitor is local-first and does not include telemetry.

The app makes requests only to configured public IP providers, the configured ChatGPT trace URL, and the configured API edge URL. It writes results locally under:

```text
~/Library/Logs/openai-egress-monitor
```

No OpenAI API key is required or read.

## App Icon

The packaged app includes:

```text
Resources/AppIcon.png
Resources/AppIcon.icns
```

## License

MIT. See [LICENSE](LICENSE).

## Disclaimer

OpenAI and ChatGPT are trademarks of their respective owners. This project is not affiliated with, endorsed by, or sponsored by OpenAI.
