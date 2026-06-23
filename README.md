# find-mtor

OCular passive monitoring and evidence collection scripts for macOS.

This repository contains a read-only monitoring script that collects process,
file-system, network, unified-log, and TCC permission evidence related to OCular
components. The collected logs are intended for later forensic analysis; the
script does not modify OCular state.

## Quick Start

```sh
# Cache sudo credentials first so background fs_usage can start reliably.
sudo -v

# Start passive monitoring.
~/find-mtor/ocular-passive-monitor.sh
```

When the monitor starts, it prints the device's current local time, the log
directory, and the stop instruction. Stop monitoring with `Ctrl-C`.

You can also provide a custom output directory:

```sh
~/find-mtor/ocular-passive-monitor.sh /path/to/output-dir
```

## Output

By default, logs are written to:

```txt
~/find-mtor/logs/ocular-monitor-<timestamp>/
```

The monitor writes:

- `tcc-snapshot.log`: user and system TCC permission snapshots.
- `processes.log`: OCular-related process snapshots.
- `ps.log`: CPU, memory, state, and elapsed-time snapshots.
- `open-files.log`: suspicious open files and loaded OCular dylibs.
- `network.log`: OCular-related socket snapshots.
- `unified-log.log`: relevant macOS unified log events.
- `fs-usage.log`: file-system activity from `fs_usage`.

At shutdown, the script cleans up background collectors and prints total runtime
in `h min` format.

## Analysis

Use [USAGE.md](./USAGE.md) for the full collection guide, analysis commands,
known false positives, evidence grading rules, and report structure.

Important constraints:

- Treat `network.log` as a periodic snapshot; short-lived connections can be
  missed.
- Check the actual coverage window of `fs-usage.log` before making conclusions.
- Bind every conclusion to concrete log evidence.
- Keep analysis read-only: do not modify logs, OCular processes, or collected
  artifacts.

## Requirements

- macOS.
- `zsh`.
- `sqlite3`.
- `sudo` access for system TCC reads and `fs_usage`.
- `ripgrep` (`rg`) is recommended; the script falls back to `grep -E` if it is
  unavailable.

