# Eragon desktop

Eragon for macOS and Linux starts Claude Code, Codex, Pi and OpenCode on your computer and points them at the models your team's Eragon Gateway provides.

## Download

Get the newest version from the [latest release](https://github.com/eragon-corp/eragon-desktop-releases/releases/latest):

| System | Download |
| --- | --- |
| macOS, Apple silicon | [Eragon-mac-arm64.dmg](https://github.com/eragon-corp/eragon-desktop-releases/releases/latest/download/Eragon-mac-arm64.dmg) |
| macOS, Intel | [Eragon-mac-x64.dmg](https://github.com/eragon-corp/eragon-desktop-releases/releases/latest/download/Eragon-mac-x64.dmg) |
| Linux, x64 (updates itself) | [Eragon-linux-x86_64.AppImage](https://github.com/eragon-corp/eragon-desktop-releases/releases/latest/download/Eragon-linux-x86_64.AppImage) |
| Debian and Ubuntu, x64 | [Eragon-linux-amd64.deb](https://github.com/eragon-corp/eragon-desktop-releases/releases/latest/download/Eragon-linux-amd64.deb) |

The app checks this repository for updates and offers **Restart to update** when a new version is ready. On Linux, only the AppImage updates itself; install a new `.deb` by hand.

## Before you start

- Your team's Eragon address. The app finds its Gateway from it.
- `jq` and `curl` on your PATH.
- A coding client, or let the app install one: Claude Code, Codex, Pi Agent or OpenCode.

On first run, Eragon asks for your Eragon address, then connects this computer: sign in with your browser, and Eragon can create a key for this computer, or paste a Gateway key you already have.

## Support

Ask the person who set up Eragon for your team. This repository holds only release packages and notes; the app's source is not public.

The Eragon name, logo and symbol are trademarks of Eragon.
