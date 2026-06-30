
Project: ip-mgr.sh

Goal:
Build a Bash-based network administration utility for Debian Bookworm/Trixie-style Linux servers that normalizes networking onto systemd-networkd/systemd-resolved. The purpose is to avoid the usual Linux networking hodgepodge of NetworkManager, ifupdown, netplan, dhcpcd, hand-edited files, DHCP clients, resolver state, etc.

The design borrows VyOS’ configuration model, not necessarily its syntax:
- deterministic config
- one authoritative expected state
- candidate edits
- compare/diff
- validate
- commit
- rollback
- actual/live interrogation

Core terminology:
- candidate: staged JSON config being edited
- expected: last committed ip-mgr-managed JSON config
- actual: current OS/kernel/network state, generated live by interrogation; never authoritative
- snapshot: historical capture before major operations

Primary state location:
  /etc/ip-mgr/
    candidate.json
    expected.json
    commits/
    snapshots/
    rendered/

Versioning:
- Script should have SCRIPT_VERSION, starting around 0.3.x/0.4.x.
- JSON should have schema_version.
- Add a `version` command that prints tool version + schema version.
- Keep CHANGELOG.md.

Preferred project layout:
  ip-mgr/
    ip-mgr.sh          (single deployable script - see deployment note below)
    CHANGELOG.md
    README.md
    docs/
      architecture.md
      command-syntax.md
      json-schema.md
      cleaner.md
    test/
    samples/

Deployment note:
- ip-mgr is kept as a single self-contained script for portability.
- Distributing a single file to remote hosts is far simpler than syncing
  a lib/ tree, and avoids broken source paths and partial updates.
- Internal organization uses section headers (# ===== name =====) for
  logical separation without filesystem fragmentation.
- If the script grows beyond ~5k lines with genuine complexity that
  justifies it, revisit a build-time concatenation approach (develop in
  lib/*.sh, bundle into a single deployable) rather than runtime sourcing.

Implementation language:
- Bash is preferred.
- jq is acceptable and expected.
- Do not use C++ unless the script becomes truly unmanageable.

CLI grammar:
  ip-mgr.sh [-4|-6] [-y|--yes] COMMAND [TARGET_INTERFACE] [OPTIONS...]

Core commands:
  set
  add
  remove
  show
  compare
  validate
  commit
  confirm
  rollback
  clean
  detect
  audit
  snapshot
  status
  version
  help

Remove aliases:
  delete, del, rem, rm, no => remove

Command abbreviation rules:
- Commands can be abbreviated to a unique prefix.
- Minimum abbreviation length is 2 characters.
- Ambiguous abbreviations must error.
- Examples:
    se => set
    sh => show
    va => validate
    cl => clean
    co => error, ambiguous between commit/compare
    c  => error, too short

Interface validation:
- For normal interface operations, target interface must exist under /sys/class/net.
- Reject typos instead of allowing systemd/networkd to fail later.
- VLAN interfaces (parent.N naming, e.g. eth1.100) and PPPoE interfaces (kind=pppoe) bypass iface_exists
  because they may not exist yet when first defined.
- Interface iteration should use:
    for iface_path in /sys/class/net/*/; do
      iface="$(basename "$iface_path")"
      [[ "$iface" == "lo" ]] && continue
    done
  Avoid `ls /sys/class/net`.

Options:
- Long and short forms should exist because repeatable switches get tiresome.

Address:
  -a:ADDR
  --address:ADDR

Gateway:
  -g:ADDR
  --gateway:ADDR
  --gw:ADDR

DNS (via dns: pseudo-target):
  ip-mgr [-4|-6] set dns: ADDR [ADDR...]
  ip-mgr [-4|-6] remove dns: ADDR [ADDR...]

MTU:
  -m:N
  --mtu:N

Description:
  -D:TEXT
  --description:TEXT

DHCPv4:
  -h
  --dhcp

RA/IPv6 accept_ra:
  -n / --ra / --accept-ra  (boolean toggle on interface)

IPv6 grouped options:
  -6o:LIST
  --options:LIST

Per-interface search domains:
  -s:DOMAIN
  --search:DOMAIN

Global search domains (via domains: pseudo-target):
  ip-mgr set domains: DOMAIN [DOMAIN...]
  ip-mgr remove domains: [DOMAIN...]   # bare clears all
  ip-mgr remove domain: DOMAIN [...]   # singular always requires names

NTP (via ntp: pseudo-target):
  ip-mgr [-4|-6] set ntp: ADDR [ADDR...]
  ip-mgr [-4|-6] remove ntp: ADDR [ADDR...]

PPPoE parent/credentials (on PPPoE interface name):
  -i:PARENT / --if:PARENT       # binds PPPoE interface to physical parent
  --identity:USER               # PPPoE username
  --pass:PASSWORD               # encrypted via systemd-creds; blob stored in IR
  --svcname:NAME                # PPPoE service name (optional)

Up/down:
  -u
  --up
  -x
  --down

Repeatable/list options:
- Repeat switches should be accepted:
    ip-mgr.sh set eth0 -a:10.0.10.1/24 -a:10.0.10.2/24
- CSV should also be accepted:
    ip-mgr.sh set eth0 -a:10.0.10.1/24,10.0.10.2/24
- Duplicate values should be normalized away, with a note if useful.
- Philosophy: normalize obvious intent; reject only unknowable/unsafe intent.

`set`, `add`, `remove` semantics:
- These modify candidate.json only.
- They should not directly mutate the live system.
- `commit` renders/applies.
- `add` and `set` may initially behave similarly for list-valued properties, but long-term:
    set = define/replace complete desired value
    add = append to collection
    remove = remove from collection or clear scalar

Show:
  ip-mgr.sh show candidate
  ip-mgr.sh show expected
  ip-mgr.sh show actual
  ip-mgr.sh show eth0

Compare:
- Treat compare as a declarative binary comparison:
    ip-mgr.sh compare [SOURCE] [TARGET]
- Default:
    compare expected candidate
  This default is optimized for human review: proposed candidate additions appear as + lines.
- Supported:
    compare expected actual
    compare candidate actual
    compare candidate expected
    compare expected candidate
- Actual should be generated fresh each time.
- Internally, convert each state to JSON and use one generic diff engine.
- Future:
    compare snapshot:latest expected

Expected/candidate JSON:
- expected.json and candidate.json exist on disk.
- actual is generated on demand, preferably into a mktemp path or stdout.
- Avoid hardcoded /tmp/ip-mgr-actual.json because concurrent invocations race.
- If a function needs actual JSON as a file, use mktemp and clean up.

Actual JSON:
- Generated from current OS state using ip/networkctl/resolvectl where useful.
- It should distinguish:
    static-looking/global addresses
    dynamic DHCPv4 addresses
    dynamic RA/SLAAC IPv6 addresses
    observed link-local IPv6 addresses
- Interface classification should happen before adoption decides whether an address is
  managed intent or observed evidence.
- Minimum classifier:
    supported/manageable:
      eth*, en*, ens*, eno*, enp*, peth*, wlan*, ppp*, pppoe*, eth*.*
    observed-only:
      wg*, tun*, tap*, gre*, pim6reg, docker*, veth*, virbr*, br*, bond*
- Observed-only interfaces should be included in state with managed=false and classified
  transport/kind, but their global addresses should go under observed.addresses, not
  ipv4.addresses/ipv6.addresses. They should not render systemd-networkd files.
- WireGuard/tun/tap/gre-style interfaces are observed-only until ip-mgr has explicit
  lifecycle/rendering support for them.
- Link-local addresses are observed only, not managed static config.

IPv6 link-local rules:
- LLA range is fe80::/10, i.e. fe80 through febf.
- Detection function should not be used via command substitution; it should return an exit code:
    is_lla() {
      local ip="${1%%/*}"
      ip="${ip,,}"
      [[ "$ip" =~ ^fe[89ab][0-9a-f]: ]]
    }
  Usage:
    if [[ "$(family_of "$addr")" == 6 ]] && is_lla "$addr"; then ...
- Reject LLAs as managed `--address` entries.
- Do not promote LLAs into candidate/expected static addresses during clean/adopt-live.
- Store LLAs in actual/observed, e.g.:
    observed.link_local = ["fe80::.../64"]

Gateway caveat:
- IPv6 default gateways are often router LLAs.
- Do not silently skip them.
- Current short-term behavior may skip LLA gateways with a clear note:
    NOTE: IPv6 LLA gateway fe80::... on eth0 skipped; scoped LLA gateways not supported yet
- Long-term design should support scoped gateways, probably as objects:
    gateways: [
      { "address": "fe80::1", "family": 6, "interface": "eth0", "scope": "link" }
    ]
- Renderer should eventually emit proper systemd-networkd [Route] entries, likely with GatewayOnLink=yes where needed.

IPv6 options:
- Prefer grouped policy:
    ip-mgr.sh -6 set eth0 --options:stable,privacy
    ip-mgr.sh -6 set eth0 -6o:none
- Recognized (v1):
    stable
    privacy
    none
- RA acceptance is controlled by ipv6.accept_ra (boolean field), not by options[].
  The old `ndpra` option was removed in v0.6.0.
- `none` is not a hard error when combined with other options. It overrides/obviates all other IPv6 automatic addressing options and should produce a note:
    NOTE: 'none' overrides all other IPv6 automatic addressing options. Ignoring: stable, privacy
- Store policy as interface IPv6 policy, not as addresses.
- privacy/stable may be stored before renderer support exists.
- Renderer support for privacy/stable can be TODO.

Dynamic addressing representation:
- Candidate/expected store mechanism/policy, not dynamic lease addresses.
- Example:
    dhcp4: true
    ipv6.accept_ra: true
    ipv6.options: ["stable"]
- Actual stores dynamic addresses:
    dynamic.dhcp4 = ["10.0.130.101/24"]
    dynamic.ra = ["2607:.../64"]
- Dynamic addresses should not become static expected addresses unless explicitly requested.

Renderer:
- Backend target is systemd-networkd.
- Render candidate/expected into /etc/systemd/network/10-ip-mgr-IFACE.network.
- Implemented (v0.6.0):
    [Match] Name=
    [Link] MTUBytes=
    [Network] DHCP=yes/ipv4/ipv6/no (combined from ipv4.dhcp + ipv6.dhcp)
    [Network] IPv6AcceptRA=yes/no
    [Network] DNS= / Domains= (per-interface)
    Gateway=
    [Address] Address=
    [Route] default gateways with Metric=
    Unmanaged=yes for observed-only interfaces
    VLAN .netdev files + VLAN= stanzas injected into parent .network
    PPPoE [PPPoE] section appended to parent .network; secrets via systemd-creds
    /etc/systemd/resolved.conf.d/ip-mgr.conf (global DNS + search domains)
    /etc/systemd/timesyncd.conf.d/ip-mgr.conf (global NTP)
    /etc/resolv.conf symlinked to stub-resolv (idempotent, backup-once)
- Future:
    non-default [Route] entries
    LLA gateway support (scoped gateways)
    WiFi PSK / WireGuard key injection (v2.0.0)
- Do not manually edit random distro config as normal operation.

Commit:
- Validate candidate.
- Backup previous expected into commits/.
- Render systemd-networkd files, resolved drop-in, timesyncd drop-in.
- Wire /etc/resolv.conf symlink (idempotent; original backed up to .ip-mgr-bak once).
- Enable systemd-networkd, systemd-resolved, systemd-timesyncd.
- Apply/restart/reconfigure systemd-networkd, systemd-resolved, systemd-timesyncd.
- Promote candidate to expected only after successful render/apply.
- Safe window (default 60s): auto-rollback timer starts; user must run `confirm` to cancel it.

Confirm:
- Cancels the pending auto-rollback timer.
- Required after any commit from an SSH session.
- Idempotent if no rollback is pending.

Rollback:
- Restore previous expected from commits/.
- Copy expected to candidate.
- Render/apply networkd.
- Longer-term staged rollback history is desirable.

Snapshot:
- Always snapshot before destructive or major operations.
- Should capture:
    ip -json link
    ip -json addr
    ip -json route
    ip -json -6 route
    actual.json
    candidate.json
    expected.json
    relevant config directories:
      /etc/network
      /etc/NetworkManager
      /etc/netplan
      /etc/systemd/network
      resolver state where possible

Detect:
- Detect installed/active stacks:
    systemd-networkd
    NetworkManager
    networking / ifupdown
    dhcpcd
    connman
    netplan
    systemd-resolved
- Do not assume active service means it owns every interface.
- Longer-term detection should include confidence/evidence:
    config files
    lease files
    live addresses
    manager-specific introspection

Clean:
- This is high priority and next major feature.
- Purpose: normalize target server from existing live networking to ip-mgr/systemd-networkd.
- Clean is not a single action; it is a staged pipeline.
- Pipeline:
    1. Snapshot
       - capture current state before making or proposing changes
    2. Detect
       - detect active control planes and ownership evidence
    3. Acquire   [actual_json()]
       - interrogate actual live network state
       - pure import: no display, no filtering, no transformation
       - produces a complete NetworkState IR from Linux runtime state
    4. Report    [report_state()]
       - read-only pass over the IR; display what was imported
       - emits per-interface summary and per-address disposition lines
       - does NOT mutate the IR
    5. Transform [transform_state()]
       - mutate the IR according to user-supplied policy flags
       - current switches:
           --no-dhcp:  strip dynamic DHCP/RA evidence; set dhcp=false / accept_ra=false
           --to-dhcp:  convert static addresses to DHCPv4 / RA+DHCPv6 policy intent
       - prints each change before applying it
       - future switches:
           --to-static
           --renumber
           --normalize
    6. Analyze   [analyze_*()]
       - read-only passes over the transformed IR; report hazards
       - current hazards:
           multiple default gateways per IP family
           missing route metrics on multiple default gateways
           static plus dynamic addressing on same interface
           multiple control planes active
           renderer cannot emit requested DHCPv6
           static IPv6 + LLA gateway + accept_ra=false (routing gap)
           DNS loopback mixed with external DNS
           interface marked managed but networkd says unmanaged
    7. Validate  [cmd_validate()]
       - schema and consistency checks
       - renderer capability checks before commit/apply
       - block apply when candidate uses policy the renderer cannot faithfully emit
    8. Compare   [cmd_compare()]
       - show expected -> candidate so candidate additions appear as + lines
    9. Write
       - write candidate.json unless --no-candidate is selected
       - commit/apply only when explicitly requested
       - block clean --apply on HIGH hazards
       - prompt before clean --apply unless --confirm or -y/--yes is supplied
       - warn when applying from an SSH session
- `clean --adopt-live` and bare `clean` should run the safe default pipeline.
- `clean --no-candidate` should run snapshot/detect/acquire/report/transform/analyze/validate/compare
  without writing candidate.json and should obviate apply/disable behavior.
- If the host is already normalized to systemd-networkd, with no active competing managers,
  clean should report that finding and avoid changing live networking.
- If the adopted candidate already matches expected.json, clean should report that the host
  already matches ip-mgr expected state and exit without a noisy compare/apply path.
- When clean is applied, disable old/competing control-plane services by default after
  successful networkd apply. Use --no-disable to leave old services running.
- Use --confirm or the global -y/--yes option to bypass interactive confirmation in scripts.
- Later:
    clean --apply
    clean --no-disable
    clean --safe
    clean --scorched-earth
- Safe default:
    snapshot -> detect -> acquire -> report -> transform -> analyze -> validate -> compare -> write candidate
- Scorched-earth:
    still snapshot first
    then disable/remove old managers earlier
    should require explicit confirm, especially over SSH
- Important: clean/adopt-live must not convert LLA addresses into static managed addresses.
- It should recognize dynamic IPv4 address as DHCP policy when possible, not static address.
- It should treat dynamic RA/SLAAC IPv6 addresses as RA policy when possible, not static address.
- It should warn visibly about skipped unsupported LLA gateways.
- Switch placement should be documented by pipeline stage, not as a flat option list.

Self-elevation:
- Read-only commands should not require root if possible:
    show candidate/expected
    compare expected candidate
    version
    help
- Mutating commands should self-elevate via sudo/doas:
    set/add/remove
    commit
    rollback
    snapshot
    clean
- `show actual` may need elevated or not depending on data gathered.
- Keep behavior sane.

Validation:
- jq validity
- schema_version sanity
- interface existence
- address syntax eventually
- reject IPv6 LLA as managed addresses
- reject invalid MTU
- reject ambiguous commands
- reject unknown options
- normalize obvious duplicates/conflicts

Important implementation fixes already identified:
- Old is_lla implementation was incomplete and was incorrectly used via command substitution.
- Fix LLA range to fe80::/10.
- Replace hardcoded /tmp actual JSON with mktemp or output-path argument.
- Use /sys/class/net/*/ glob instead of ls.
- IPv6 LLA gateways must be warned about, not silently skipped.
- If actual_json writes to a path, avoid also piping its stdout back into the same path.

Completed milestones:
v0.3.1:
- LLA detection fixed (fe80::/10 full range, no command substitution).
- Replaced hardcoded /tmp with mktemp-based tmp paths.
- Interface enumeration via /sys/class/net/*/.
- LLA gateways warned and skipped (not silently dropped).

v0.4.0:
- clean --adopt-live pipeline (8 stages: snapshot/detect/acquire/filter/
  analyze/transform/validate/compare/write).
- Schema v1 migration (nested ipv4/ipv6, address/gateway objects).
- iface_class() classifier: transport/kind/managed per interface type.
- VLAN detection with parent + vlan_id fields.
- PPPoE/point-to-point address prefix normalization (/32 /128).
- transport reclassified to ethernet | tunnel (kind carries the detail).
- WireGuard, tun, tap, gre, pim6reg correctly observed-only (managed=false).
- Hazard analysis: multiple gateways, mixed addressing, competing managers,
  DHCPv6 renderer gap, DNS loopback mixing.
- --no-candidate dry-run mode, --no-dhcp, --to-dhcp, --apply pipeline.
- Single-file deployment decision (no lib/ split).

v0.5.0:
- Unmanaged=yes rendered for observed-only interfaces (prevents networkd
  from hijacking WireGuard/tunnel/etc. interfaces on commit).
- LLA gateway handling corrected: stored in observed.gateways, adoption
  message updated to "RA-managed; covered by ipv6.accept_ra=true".
- New hazard: static IPv6 + LLA gateway + accept_ra=false warns that
  IPv6 default routing may be absent after commit.
- cmd_validate: transport/kind enum enforcement.
- show [state] [IFACE]: show actual eth0 / show expected wg0 etc.
- Compiler architecture refactor: import/report/transform stages fully
  separated. actual_json() is a pure importer; report_state() is a
  read-only display pass; transform_state() is the sole mutation pass.
  adopt_interface_to_candidate() eliminated; pipeline reduced to 4 lines.
- DRY: record_address/collect_addresses/record_gateway/collect_gateways
  unified into pure importers (report and filter params removed).
  managed_ifaces() helper eliminates repeated inline jq patterns.
- Principles 12-15 added to reflect compiler/IR architecture.

v0.6.0:
- IPv6 addressing model: ipv6.dhcp boolean + ipv6.accept_ra boolean;
  DHCP= renderer combines both into yes/ipv4/ipv6/no; ndpra option
  removed from schema and migrated out of existing state files.
- audit command: full interface inventory against expected+actual with
  sync status and observed-vs-managed diff.
- check_deps: validates required tools (jq, ip, networkctl, etc.)
  present at startup; clear error if not.
- VLAN lifecycle: create/modify/delete via parent.vlanid naming (e.g.
  eth1.100); auto-detected from BASH_REMATCH; generates .netdev file
  and injects VLAN= stanza into parent .network; parent validated.
- systemd-resolved integration: dns:/domains:/ntp: pseudo-targets for
  global resolver and NTP config; per-interface -s:/--search: for
  search domains; render_resolved_conf() drop-in at commit; resolv.conf
  symlinked to /run/systemd/resolve/stub-resolv.conf (idempotent,
  backup-once to .ip-mgr-bak); systemd-resolved enabled at commit.
- NTP: ntp: pseudo-target; render_timesyncd_conf() drop-in;
  systemd-timesyncd enabled at commit.
- PPPoE: full lifecycle via pppoe0 / -i:eth0 --identity:USER --pass:PW
  --svcname:SVC; systemd-creds encryption (machine-bound); base64 blob
  stored in IR; secrets decrypted to $BASE/secrets/pppoe-IFACE.secret
  (mode 0600) at render time; [PPPoE] section injected into parent
  .network; secrets cleaned on every render (rollback-safe).
- commit-confirm / auto-rollback: safe window (default 60s) with
  countdown; confirm command cancels the timer; auto-rollback unit
  reverts to last expected if confirm is not run in time.
- schema_version stays at 1; json-schema.md document version bumped
  to 1.1; Principles.txt remains at 15 principles (no additions needed).

v0.7.0:
- IPv6 privacy/stable rendering: IPv6PrivacyExtensions= emitted from
  ipv6.options[]; stable→no, privacy→prefer, both→yes, none/empty→omit.
- route: pseudo-target: static routes managed globally via
  ip-mgr [-4|-6] add route: --net NET --via GW --if IFACE [--metric N]
  ip-mgr remove route: --net NET --if IFACE [--metric]  (bare --metric clears only)
  Routes stored in interfaces[$if].ipv4|ipv6.routes[]; rendered as
  [Route] sections after gateway [Route] entries.
- Space-separated flag values: normalize_flags(set|remove) preprocessor
  converts --flag VALUE to --flag:VALUE before set_option/remove_option,
  making --address 2602:f925::1/64 equivalent to --address:2602:f925::1/64.
  route: pseudo-target uses its own lookahead parser (same effect).
- discard command: resets candidate.json to last committed expected.json
  without touching the running system. Counterpart to commit.
- Batch/heredoc mode: ip-mgr <<EOF ... EOF pipes one sub-command per line;
  comments (#) and blank lines ignored; stops on first error; elevation
  done once upfront (exec sudo inherits the stdin pipe).

Next milestone:
v0.8.0 (candidates):
- Real-target field test on Debian Bookworm and Trixie hardware.
- Fix any issues discovered during field testing.
- clean --apply end-to-end testing.
- export {filename} [--source:active|expected|rollback:ID|rollback:N]
  [--as:JSON|CMD]: saves a NetworkState to a file. --as:CMD produces
  perfectly-issuable ip-mgr commands that reproduce the configuration
  (VyOS-style "show configuration-commands"); family flags derived from
  address content; PPPoE passwords emitted as a comment (machine-bound).
  No filename → stdout. Rollback IDs are commit filenames (stem) or
  ordinal shorthand (rollback:1 = most recent, rollback:latest = same).
- apply {filename} [--save]: applies a (partial) NetworkState JSON to
  the running system. Without --save: render+restart networkd only;
  expected.json untouched; auto-rollback timer fires if not confirmed.
  With --save: merge file settings into expected.json, archive old
  expected to rollback queue, make merged result authoritative.
- Manpage (ip-mgr.1).
- CHANGELOG.md populated from git log.

Coding preference:
- Avoid dumping huge code into chat.
- Work in VS Code/Codex with files and diffs.
- Keep functions modular.
- Commit small logical steps.
- Bash strict mode is desired:
    set -euo pipefail
  but be careful with commands that intentionally return nonzero.
  
