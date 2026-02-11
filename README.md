# Siftly

A macOS menu bar app for managing [dnsproxy](https://github.com/AdguardTeam/dnsproxy) DNS configurations.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Menu bar app** — lives in your menu bar, no Dock icon
- **DNS profile switching** — quickly switch between Home/Work/custom DNS configurations
- **Split tunneling** — route specific domains to different DNS servers
- **Settings UI** — configure upstreams, fallbacks, bootstrap servers, caching, rate limiting, and more
- **Privileged helper** — bind port 53 without a password prompt (optional, one-time `sudo` install)
- **Auto-restart** — automatically restarts dnsproxy when config changes
- **Process watchdog** — detects crashes and heals with exponential backoff
- **Launch at Login** — via macOS `SMAppService`

## Requirements

- macOS 14 (Sonoma) or later
- [dnsproxy](https://github.com/AdguardTeam/dnsproxy) binary — download from [releases](https://github.com/AdguardTeam/dnsproxy/releases) or build from source

## Quick Start

```bash
# 1. Clone
git clone https://github.com/victor-siu/siftly-mac.git
cd siftly-mac

# 2. Place dnsproxy binary in the repo root
#    Download from: https://github.com/AdguardTeam/dnsproxy/releases
cp /path/to/dnsproxy .

# 3. Build & package
./scripts/package_app.sh

# 4. Install
mv Siftly.app /Applications/
open /Applications/Siftly.app
```

## Port 53 (Optional)

By default, Siftly listens on port 5353 (no root needed). If you want to use port 53:

```bash
# One-time install of the privileged helper daemon
sudo ./scripts/install_helper.sh
```

This installs a LaunchDaemon that runs as root and manages dnsproxy on behalf of the app — no more password prompts.

To remove it:

```bash
sudo ./scripts/uninstall_helper.sh
```

## Project Structure

```
Sources/
├── Siftly/              # Main macOS app
│   ├── Core/            # Config model, DNS providers, profiles
│   ├── Services/        # ProxyManager, HelperClient
│   └── UI/              # SwiftUI views (menu, settings, editors)
├── SiftlyHelper/        # Privileged helper daemon
└── SiftlyShared/        # Shared types (helper protocol)
scripts/
├── package_app.sh       # Build .app bundle
├── install_helper.sh    # Install privileged helper (sudo)
└── uninstall_helper.sh  # Remove privileged helper (sudo)
```

## Configuration

- App config: `~/Library/Application Support/Siftly/config.yaml` (dnsproxy YAML format)
- Profiles: `~/Library/Application Support/Siftly/profiles.json`

## License

MIT
