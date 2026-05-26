# Security Policy

EgressMonitor is a local status bar utility. It does not require API keys and does not send telemetry to this project.

## Reporting

Please report security issues privately through the repository owner's preferred contact channel. Do not disclose exploitable issues publicly before maintainers have had a chance to review them.

## Data Handling

The app performs network requests to the configured public IP providers and ChatGPT trace endpoint. Results are written locally under:

```text
~/Library/Logs/openai-egress-monitor
```

Config is stored under:

```text
~/Library/Application Support/openai-egress-monitor
```

Review configured probe URLs before use if you change defaults.
