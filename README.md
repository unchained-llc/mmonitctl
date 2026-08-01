[English](README.md) | [日本語](README_ja.md)

# mmonit-cli-ng

A POSIX `sh` + `jq` CLI for controlling M/Monit host monitoring state.

Executable command: `mmonitctl`

## Features

- Stop all hosts: `stop-all` (`status=2` = Ignored)
- Start all hosts: `start-all` (`status=0` = Active)
- Interactive host selection: `stop` / `start`
- Group target by name or ID: `stop-group <group>` / `start-group <group>`
- Interactive group selection (from menu)
- Alert check command: `check`
  - Uses `GET /api/2/reports/events/list?active=1&state=1`
  - Exits `1` when at least one active alert event exists
- Parallel updates (`MMONIT_CONCURRENCY`, default `8`)

## Requirements

- POSIX-compatible `sh`
- `curl`
- `jq`
- `awk`, `mktemp`, `stty`

## Install

```sh
make install
```

Default install path: `/usr/local/bin/mmonitctl`

## Initial setup

On first run, the CLI prompts for:

- M/Monit Base URL
- Username
- Password

Saved config path:

- macOS: `~/Library/Application Support/mmonitctl/config.json`
- Linux: `~/.config/mmonitctl/config.json`

Reconfigure:

```sh
mmonitctl config
```

## Usage

```sh
# Open menu
mmonitctl

# Stop/start all hosts
mmonitctl stop-all
mmonitctl start-all

# Select hosts to stop/start
mmonitctl stop
mmonitctl start

# Stop/start specific group (name or id)
mmonitctl stop-group web
mmonitctl start-group web
mmonitctl stop-group 94
mmonitctl start-group 94

# Check active alert events
mmonitctl check

# Invert exit code (alert=0, no-alert=1)
mmonitctl check --invert-exit
```

Compatibility flags (accepted):

```sh
mmonitctl stop-all --yes
mmonitctl start-all --non-interactive
```

## Menu

1. Stop all hosts
2. Start all hosts
3. Select hosts to stop
4. Select hosts to start
5. Select groups to stop
6. Select groups to start
7. Check host errors (exit status)
8. Cancel

## Interactive keys

| Key | Action |
|---|---|
| `k` / `↑` / `Ctrl-P` | Move up |
| `j` / `↓` / `Ctrl-N` | Move down |
| `Space` | Toggle selection and move cursor to next item |
| `A` | Select all currently visible items |
| `/` | Enter filter input mode |
| `Enter` | Run action with selected items (or exit filter input mode) |
| `Backspace` | Delete one character in filter input mode |
| `Esc` | Clear active filter (does not close selector) |
| `q` | Cancel selector |

## Environment variables

- `MMONIT_BASE_URL`
- `MMONIT_USERNAME`
- `MMONIT_PASSWORD`
- `MMONIT_CONFIG_DIR`
- `MMONIT_CONCURRENCY` (default: `8`)
- `NO_COLOR=1`

`MMONIT_BASE_URL`, `MMONIT_USERNAME`, and `MMONIT_PASSWORD` override saved config.

## API usage

- `GET /api/2/session/get` (CSRF token)
- `GET /api/2/admin/hosts/list`
- `GET /api/2/admin/hosts/get?id=<id>`
- `POST /api/2/admin/hosts/update`
- `GET /api/2/admin/groups/list`
- `GET /api/2/reports/events/list?active=1&state=1` (`check`)

For `hosts/update`, values from `hosts/get` are preserved and sent together with `status`.

## Development

```sh
make lint
make test
```
