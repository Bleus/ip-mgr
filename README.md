# ip-mgr.sh

`ip-mgr.sh` is a single-file Bash network configuration manager for
Linux servers.

It provides a staged, reviewable, rollback-capable workflow for managing
Linux network policy using plain JSON and native systemd networking
components.

Instead of editing scattered files by hand or handing control to a
daemon, `ip-mgr.sh` lets you:

``` text
stage changes → validate → diff → compile → apply → confirm or rollback
```

## Why this exists

Linux networking is powerful, but the management surface is fragmented:

-   `ip`
-   `resolvectl`
-   `networkctl`
-   `systemd-networkd`
-   `systemd-resolved`
-   routing tables
-   DNS state
-   interface files
-   rollback files
-   service restarts

`ip-mgr.sh` tries to make that manageable from one command structure
without hiding the system underneath it.

The goal is not to replace Linux networking.

The goal is to make Linux networking safer to operate.

## Design principles

-   Plain Bash
-   Plain JSON state files
-   No database
-   No persistent daemon
-   No hidden control plane
-   Native systemd-networkd output
-   Review before apply
-   Rollback as a normal operation
-   Live-state inspection remains available
-   Config files remain human-readable

## Project status

`ip-mgr.sh` is under active development.

Current focus:

-   JSON schema stabilization
-   staged configuration workflow
-   compile/apply behavior
-   rollback handling
-   manpage and documentation
-   command consistency

Do not assume this is production-safe without reviewing and testing it
in your own environment.

## Basic workflow

``` bash
ip-mgr status
ip-mgr edit
ip-mgr diff
ip-mgr validate
ip-mgr compile
ip-mgr apply --confirm
ip-mgr confirm
```

If the change breaks connectivity:

``` bash
ip-mgr rollback
```

If staged changes should be abandoned:

``` bash
ip-mgr discard
```

## Configuration model

`ip-mgr.sh` separates intended network state from live system state.

The main state concepts are:

  State         Meaning
  ------------- -----------------------------------------
  `active`      Current detected/live network condition
  `expected`    Intended saved configuration
  `candidate`   Temporary staged change log
  `rollback`    Prior known-good expected states

A candidate is not a full copy of expected state. It is a temporary
command log. On compile, the log is replayed against the current
expected state, reducing stale-candidate pollution.

## Example

Stage an interface address:

``` bash
ip-mgr set interface eth0 address 192.0.2.10/24
```

Review the pending change:

``` bash
ip-mgr diff
```

Compile and apply:

``` bash
ip-mgr compile
ip-mgr apply --confirm
```

Confirm the change:

``` bash
ip-mgr confirm
```

Or roll back:

``` bash
ip-mgr rollback
```

## Installation

Clone the repository:

``` bash
git clone https://github.com/Bleus/ip-mgr.git
cd ip-mgr
```

Install the script somewhere in root's path:

``` bash
sudo install -m 0755 ip-mgr.sh /usr/local/sbin/ip-mgr
```

Install the manpage:

``` bash
sudo install -m 0644 ip-mgr.8 /usr/local/share/man/man8/ip-mgr.8
sudo mandb
```

Read the manual:

``` bash
man ip-mgr
```

## Requirements

-   Linux
-   Bash
-   `jq`
-   systemd-networkd
-   systemd-resolved
-   root privileges for apply/commit operations

## Safety notes

This tool manages network configuration.

A bad configuration can disconnect the host.

Use console access, VM snapshots, out-of-band management, or
`apply --confirm` when testing remote systems.

## Repository layout

``` text
ip-mgr.sh              Main script
ip-mgr.schema.json     Current JSON schema
ip-mgr.8               Manual page
README.md              Project overview
Principles.md          Design philosophy
Roadmap.md             Development roadmap
json-schema.md         Schema notes
```

## Documentation

Start here:

``` bash
man ip-mgr
```

Additional project documents:

-   `Principles.md`
-   `Roadmap.md`
-   `json-schema.md`
-   `ip-mgr.schema.json`

## License

GPL-3.0

## Author

Brett Leuszler / Net-Xpert Consulting
