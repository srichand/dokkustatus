# DokkuStatus

[![Swift Build](https://github.com/srichand/dokkustatus/actions/workflows/swift.yml/badge.svg?branch=main)](https://github.com/srichand/dokkustatus/actions/workflows/swift.yml)

DokkuStatus is a macOS menu bar app that checks Dokku app health over SSH and shows a quick running/total summary with drill-down operational details.

## Features

- Menu bar status indicator (`running/total`) with aggregate health state.
- On-demand refresh of Dokku app status.
- Per-app details from `dokku ps:inspect`, including process/runtime/network/storage fields.
- Let's Encrypt status parsing from `dokku letsencrypt:list` when available.
- Multiple host profiles sourced from saved settings and `~/.ssh/config`.
- Per-profile ignored app list.

## Requirements

- macOS 14 or newer.
- Xcode 26+ (or a toolchain that supports Swift 6.0 / tools version 6.2).
- Dokku server reachable via SSH.
- SSH access that can run Dokku commands non-interactively.

## Build And Test

Run from the repository root:

```bash
swift test
```

```bash
xcodebuild -scheme DokkuStatus -project DokkuStatus.xcodeproj -configuration Release -destination 'platform=macOS' build
```

## Run From Xcode

1. Open `DokkuStatus.xcodeproj`.
2. Select the `DokkuStatus` scheme.
3. Choose `My Mac` as the run destination.
4. Run the app.
5. Open Settings from the menu bar extra to configure host/user/port/alias.

## Dokku / SSH Prerequisites

DokkuStatus executes commands in this shape:

- `ssh -o BatchMode=yes -p <port> <target> "dokku apps:list"`
- `ssh -o BatchMode=yes -p <port> <target> "dokku ps:inspect <app>"`
- `ssh -o BatchMode=yes -p <port> <target> "dokku letsencrypt:list"`

Your SSH user must be able to run those commands without interactive password prompts.

## Known Limitation: Non-Interactive SSH And sudo/TTY

The app always uses non-interactive SSH (`BatchMode=yes`). If the remote account requires interactive `sudo`, status checks will fail with errors such as:

- `sudo: a terminal is required to read the password`
- `sudo: a password is required`

If this happens, use a Dokku-capable SSH user (or alias) that does not require interactive sudo for Dokku commands.

## Release Status

This repository is currently **source-release only** (Pass 1). Signed/notarized distributable artifacts are planned for a later pass.
