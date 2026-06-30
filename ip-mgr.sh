#!/usr/bin/env bash
# =============================================================================
#  ip-mgr — Network Interface Manager for systemd-networkd
#  © 2026 Brett D. Leuszler o/a Net-Xpert Consulting
#  SPDX-License-Identifier: GPL-3.0-or-later
#  See LICENSE for full terms.  <https://nxios.ca>
# =============================================================================
set -euo pipefail

# ===== constants/version =====

SCRIPT_VERSION="1.0.0"
SCHEMA_VERSION="1"

APP="ip-mgr"
BASE="/etc/ip-mgr"
CANDIDATE="$BASE/candidate.json"  # JSON state: wholesale replacement (cmd_clean)
JOURNAL="$BASE/candidate"          # JSONL journal: incremental mutations (set/add/remove)
JOURNAL_MODE="yes"                 # "yes" = mutations append to journal; "no" = mutations write JSON
PROJECTING="no"                    # "yes" during journal replay — suppresses filesystem side effects
EXPECTED="$BASE/expected.json"
COMMITS="$BASE/commits"
SNAPS="$BASE/snapshots"
LAST_COMMIT="$BASE/last-commit"
NETWORKD="/etc/systemd/network"
SYS_NET_CLASS="/sys/class/net"
TMP_DIR="${TMPDIR:-/tmp}"
ETC_NETWORK="/etc/network"
NETWORK_INTERFACES="$ETC_NETWORK/interfaces"
NETWORKMANAGER="/etc/NetworkManager"
NETWORKMANAGER_CONNECTIONS="$NETWORKMANAGER/system-connections"
NETPLAN="/etc/netplan"
RESOLV_CONF="/etc/resolv.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
RESOLVED_CONF_D="/etc/systemd/resolved.conf.d"
TIMESYNCD_CONF_D="/etc/systemd/timesyncd.conf.d"
PPPOE_SECRETS_DIR="$BASE/secrets"

AUTOROLLBACK_UNIT="ip-mgr-autorollback"
AUTOROLLBACK_DEADLINE="$BASE/autorollback-deadline"
ALIGN_UNIT="ip-mgr-align"
SYSTEMD_SYSTEM="/etc/systemd/system"
DEFAULT_SAFE_WINDOW=60

COMMANDS=(set add remove show compare validate commit confirm discard clean detect audit snapshot apply align version help status)

# ===== logging/errors =====

die(){ echo "ERROR: $*" >&2; exit 1; }
note(){ echo "NOTE: $*" >&2; }

# ===== dependencies =====

check_deps(){
  local ok="yes" tool pkg
  for tool in jq ip diff; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      case "$tool" in
        jq)   pkg="jq" ;;
        ip)   pkg="iproute2" ;;
        diff) pkg="diffutils" ;;
      esac
      echo "ERROR: '$tool' not found; install with: apt-get install $pkg" >&2
      ok="no"
    fi
  done
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemctl not found; ip-mgr requires a systemd-based Linux system." >&2
    ok="no"
  fi
  [[ "$ok" == "yes" ]] || exit 1
}

# ===== command parsing =====

resolve_command(){
  local input="$1"

  case "$input" in
    delete|del|rem|rm|no) echo "remove"; return ;;
  esac

  [[ ${#input} -ge 2 ]] || die "command '$input' is too short; minimum is 2 chars"

  local matches=()
  for c in "${COMMANDS[@]}"; do
    [[ "$c" == "$input"* ]] && matches+=("$c")
  done

  case "${#matches[@]}" in
    0) die "unknown command '$input'" ;;
    1) echo "${matches[0]}" ;;
    *) die "'$input' is ambiguous: ${matches[*]}" ;;
  esac
}

needs_root(){
  case "$1" in
    set|add|remove|commit|confirm|discard|clean|audit|snapshot|apply|align|status) return 0 ;;
    *) return 1 ;;
  esac
}

needs_store(){
  local cmd="$1"
  shift || true

  if [[ "$cmd" == "clean" ]]; then
    local arg
    for arg in "$@"; do
      [[ "$arg" == "--no-candidate" ]] && return 1
    done
  fi

  case "$cmd" in
    set|add|remove|show|compare|validate|commit|discard|clean|audit|snapshot|apply|align) return 0 ;;
    *) return 1 ;;
  esac
}

elevate(){
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -- bash "$0" "$@"
  elif command -v doas >/dev/null 2>&1; then
    exec doas -- bash "$0" "$@"
  else
    die "root required; sudo/doas not found"
  fi
}

maybe_elevate(){
  [[ $EUID -eq 0 ]] && return

  local args=("$@")
  local i=0
  while [[ "${args[$i]:-}" == "-4" || "${args[$i]:-}" == "-6" || "${args[$i]:-}" == "-y" || "${args[$i]:-}" == "--yes" ]]; do
    i=$(( i + 1 ))
  done

  local raw="${args[$i]:-help}"
  case "$raw" in
    help|--help|version|--version) return ;;
  esac

  local cmd
  cmd="$(resolve_command "$raw")"

  if needs_root "$cmd"; then
    elevate "$@"
  fi
}

# ===== JSON state helpers =====

init_store(){
  # Read-only commands (show, compare) may run without root — skip all writes.
  if [[ $EUID -ne 0 ]]; then return 0; fi

  mkdir -p "$BASE" "$COMMITS" "$SNAPS"

  if [[ ! -f "$EXPECTED" ]]; then
    jq -n --arg ver "$SCRIPT_VERSION" --argjson schema "$SCHEMA_VERSION" '{
      schema_version: $schema,
      managed_by: "ip-mgr",
      tool_version: $ver,
      host: { name: null },
      resolver: { dns: [], search_domains: [] },
      ntp: { servers: [] },
      interfaces: {}
    }' > "$EXPECTED"
  fi

  local _tmp
  _tmp="$(state_tmp_path)"

  # Strip legacy 'ndpra' from options[] — moved to accept_ra field in v0.6.0
  local _mig_ndpra='
    .interfaces |= with_entries(
      .value.ipv6.options = (.value.ipv6.options // [] | map(select(. != "ndpra")))
    )
  '
  jq "$_mig_ndpra" "$EXPECTED" > "$_tmp" && mv "$_tmp" "$EXPECTED"

  # Ensure ntp root key present — added in v0.6.0
  local _mig_ntp='.ntp //= {"servers":[]}'
  jq "$_mig_ntp" "$EXPECTED" > "$_tmp" && mv "$_tmp" "$EXPECTED"
}

ensure_iface(){
  local iface="$1"
  local tmp kind parent_json vlan_id_json
  tmp="$(candidate_tmp_path)"

  kind="ethernet"
  parent_json="null"
  vlan_id_json="null"
  if [[ "$iface" =~ ^(.+)\.([0-9]+)$ ]]; then
    kind="vlan"
    parent_json="\"${BASH_REMATCH[1]}\""
    vlan_id_json="${BASH_REMATCH[2]}"
  fi

  jq --arg i "$iface" --arg kind "$kind" \
     --argjson parent "$parent_json" \
     --argjson vlan_id "$vlan_id_json" '
    .interfaces[$i] //= {
      "managed":     true,
      "transport":   "ethernet",
      "kind":        $kind,
      "enabled":     true,
      "mtu":         null,
      "description": null,
      "parent":      $parent,
      "vlan_id":     $vlan_id,
      "ipv4": { "dhcp": false, "addresses": [], "gateways": [], "routes": [] },
      "ipv6": { "dhcp": false, "accept_ra": false, "options": [], "addresses": [], "gateways": [], "routes": [] },
      "resolver": { "dns": [], "search_domains": [] }
    }
  ' "$CANDIDATE" > "$tmp"
  mv "$tmp" "$CANDIDATE"
}

jwrite(){
  local tmp
  tmp="$(candidate_tmp_path)"
  jq "$@" "$CANDIDATE" > "$tmp"
  mv "$tmp" "$CANDIDATE"
}

# True if any staged changes exist (journal or wholesale candidate.json)
has_pending(){  [[ -f "$JOURNAL" || -f "$CANDIDATE" ]]; }
# True if there is a journal (incremental mutations)
has_journal(){  [[ -f "$JOURNAL" ]]; }

split_csv(){
  local value="$1"
  IFS=',' read -ra PARTS <<< "$value"
  printf '%s\n' "${PARTS[@]}"
}

empty_state_json(){
  jq -n --arg ver "$SCRIPT_VERSION" --argjson schema "$SCHEMA_VERSION" '{
    schema_version: $schema,
    managed_by: "ip-mgr",
    tool_version: $ver,
    host: { name: null },
    resolver: { dns: [], search_domains: [] },
    interfaces: {}
  }'
}

state_tmp_path(){
  mktemp "$TMP_DIR/ip-mgr-state.XXXXXX.json"
}

actual_tmp_path(){
  mktemp "$TMP_DIR/ip-mgr-actual.XXXXXX.json"
}

work_tmp_path(){
  mktemp "$TMP_DIR/ip-mgr-work.XXXXXX.tmp"
}

candidate_tmp_path(){
  printf '%s\n' "$CANDIDATE.tmp"
}

# Append a JSONL entry to the journal.
# Usage: _journal_append FAM CMD [ARGS...]  (FAM is "" | "4" | "6")
# Each line is: {"fam":"","cmd":"set","args":["eth0","--address:1.2.3.4/24"]}
# jq --args encodes any value safely — no shell-quoting or '#' truncation issues.
_journal_append(){
  local fam="$1" cmd="$2"
  shift 2
  if [[ ! -f "$JOURNAL" ]]; then
    (umask 177 && printf '# ip-mgr staged changes — staged: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$JOURNAL")
  fi
  jq -cn --arg fam "$fam" --arg cmd "$cmd" --args \
    '{"fam":$fam,"cmd":$cmd,"args":$ARGS.positional}' "$@" >> "$JOURNAL"
}

# Replay the JSONL journal against BASE_JSON into DEST_JSON.
# CANDIDATE, JOURNAL_MODE, and PROJECTING are locally overridden so that
# mutation functions write to DEST_JSON and skip filesystem side effects.
_replay_journal(){
  local _base="$1" _dest="$2"
  cp "$_base" "$_dest"
  local CANDIDATE="$_dest" JOURNAL_MODE="no" PROJECTING="yes"
  local _line _fam _cmd _a
  local -a _entry_args
  while IFS= read -r _line; do
    [[ -z "$_line" || "${_line:0:1}" == "#" ]] && continue
    # Three separate jq calls — avoids null bytes in filter strings.
    # Newline-delimited arg reading is safe for all valid ip-mgr argument values.
    _fam="$(jq -r '.fam // ""' <<< "$_line")"
    _cmd="$(jq -r '.cmd'       <<< "$_line")"
    _entry_args=()
    [[ -n "$_fam" ]] && _entry_args+=("-$_fam")
    _entry_args+=("$_cmd")
    while IFS= read -r _a; do
      _entry_args+=("$_a")
    done < <(jq -r '.args // [] | .[]?' <<< "$_line")
    dispatch_one "${_entry_args[@]}" || return 1
  done < "$JOURNAL"
}

# Project the journal onto expected into a fresh temp file.
# Prints the temp path; caller is responsible for cleanup.
_project_candidate(){
  local _tmp
  _tmp="$(state_tmp_path)"
  _replay_journal "$EXPECTED" "$_tmp" || { rm -f "$_tmp"; die "candidate projection failed"; }
  echo "$_tmp"
}

state_file(){
  case "$1" in
    candidate|cand)
      if has_journal; then
        _project_candidate   # temp path; caller must clean up
      elif [[ -f "$CANDIDATE" ]]; then
        echo "$CANDIDATE"
      else
        die "no staged changes (use 'show expected' to see the current committed state)"
      fi
      ;;
    expected|exp)   echo "$EXPECTED" ;;
    actual|act)
      local _f; _f="$(state_tmp_path)"
      actual_json > "$_f"
      echo "$_f"
      ;;
    --file:*|-f:*)
      local _p="${1#*:}"
      [[ -f "$_p" ]] || die "file not found: $_p"
      echo "$_p"
      ;;
    *) die "unknown state '$1'; use candidate, expected, actual, or --file:PATH / -f:PATH" ;;
  esac
}

# ===== IP/address helpers =====

iface_path(){
  printf '%s/%s\n' "$SYS_NET_CLASS" "$1"
}

iface_exists(){
  [[ -d "$(iface_path "$1")" ]]
}

each_physical_iface(){
  local iface_path iface
  for iface_path in "$SYS_NET_CLASS"/*/; do
    [[ -d "$iface_path" ]] || continue
    iface="$(basename "$iface_path")"
    [[ "$iface" == "lo" ]] && continue
    printf '%s\n' "$iface"
  done
}

family_of(){
  [[ "$1" == *:* ]] && echo 6 || echo 4
}

is_lla(){
  local ip="${1%%/*}"
  [[ "${ip,,}" =~ ^fe[89ab][0-9a-f]: ]]
}

iface_class(){
  local iface="$1"

  case "$iface" in
    wg*)                                echo "tunnel wireguard false" ;;
    tun*)                               echo "tunnel tun false" ;;
    tap*)                               echo "tunnel tap false" ;;
    gre*|pim6reg)                       echo "tunnel gre false" ;;
    docker*|veth*|virbr*|br*|bond*)    echo "ethernet ethernet false" ;;
    wlan*)                              echo "ethernet wifi true" ;;
    ppp*|pppoe*)                        echo "tunnel pppoe true" ;;
    eth*.*|en*.*|ens*.*|eno*.*|enp*.*) echo "ethernet vlan true" ;;
    eth*|en*|ens*|eno*|enp*|peth*)     echo "ethernet ethernet true" ;;
    *)
      local link_type
      link_type="$(ip -json link show dev "$iface" 2>/dev/null | jq -r '.[0].link_type // "ether"')"
      case "$link_type" in
        tun) echo "tunnel tun false" ;;
        gre) echo "tunnel gre false" ;;
        *)   echo "ethernet ethernet false" ;;
      esac
      ;;
  esac
}

iface_transport(){ iface_class "$1" | awk '{print $1}'; }
iface_kind(){ iface_class "$1" | awk '{print $2}'; }
iface_managed_default(){ iface_class "$1" | awk '{print $3}'; }

iface_mtu(){
  # Returns JSON-safe value: number string or "null" when sysfs file is absent.
  local m
  m="$(cat "$(iface_path "$1")/mtu" 2>/dev/null)" && printf '%s' "$m" || printf 'null'
}

iface_operstate(){
  cat "$(iface_path "$1")/operstate" 2>/dev/null || echo "unknown"
}

ip_addr_rows(){
  local iface="$1"
  ip -o addr show dev "$iface" |
    awk '{
      family=$3; addr=$4; scope=""; proto="static"
      for(i=1;i<=NF;i++){
        if($i=="scope"){scope=$(i+1)}
        if($i=="dynamic"){proto="dynamic"}
      }
      if (addr !~ /\//) {
        addr = addr (family == "inet" ? "/32" : "/128")
      }
      print family, addr, proto, scope
    }'
}

default_gateway_rows(){
  local fam="$1" iface="$2"
  ip "-$fam" route show default dev "$iface" 2>/dev/null |
    awk '$1=="default" && $2=="via" {
      metric=""
      for(i=1;i<=NF;i++){
        if($i=="metric"){metric=$(i+1)}
      }
      print $3, metric
    }'
}

# ===== validation =====

validate_iface(){
  local iface="$1"
  [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "invalid interface name '$iface'"
  # VLANs (parent.vlanid) are created by commit — don't require them to exist yet
  [[ "$iface" =~ ^.+\.[0-9]+$ ]] && return 0
  iface_exists "$iface" || die "interface '$iface' does not exist"
}

# ===== candidate mutation =====

set_option(){
  local fam="$1" iface="$2" token="$3"

  validate_iface "$iface"
  ensure_iface "$iface"

  case "$token" in
    -a:*|--address:*)
      local val fk
      for val in $(split_csv "${token#*:}"); do
        if [[ "$(family_of "$val")" == 6 ]] && is_lla "$val"; then
          die "IPv6 link-local addresses are observed only, not managed static addresses"
        fi
        [[ -z "$fam" || "$(family_of "$val")" == "$fam" ]] || die "$val does not match -$fam"
        if [[ "$(family_of "$val")" == 6 ]]; then fk="ipv6"; else fk="ipv4"; fi
        jwrite --arg i "$iface" --arg fk "$fk" --arg v "$val" '
          .interfaces[$i][$fk].addresses |= (. + [{"address": $v}] | unique_by(.address))
        '
      done
      ;;

    -g:*|--gateway:*|--gw:*)
      local val fk
      for val in $(split_csv "${token#*:}"); do
        if [[ "$(family_of "$val")" == 6 ]] && is_lla "$val"; then
          die "link-local gateway requires scope handling; not supported yet"
        fi
        [[ -z "$fam" || "$(family_of "$val")" == "$fam" ]] || die "$val does not match -$fam"
        if [[ "$(family_of "$val")" == 6 ]]; then fk="ipv6"; else fk="ipv4"; fi
        jwrite --arg i "$iface" --arg fk "$fk" --arg v "$val" '
          .interfaces[$i][$fk].gateways |= (. + [{"address": $v, "metric": null, "scope": "global", "on_link": false}] | unique_by(.address))
        '
      done
      ;;

    -d:*|--dns:*)
      local val
      for val in $(split_csv "${token#*:}"); do
        jwrite --arg i "$iface" --arg v "$val" '
          .interfaces[$i].resolver.dns |= (. + [$v] | unique)
        '
      done
      ;;

    -m:*|--mtu:*)
      local val="${token#*:}"
      [[ "$val" =~ ^[0-9]+$ ]] || die "invalid MTU '$val'"
      jwrite --arg i "$iface" --argjson v "$val" '.interfaces[$i].mtu = $v'
      ;;

    -D:*|--description:*)
      local val="${token#*:}"
      jwrite --arg i "$iface" --arg v "$val" '.interfaces[$i].description = $v'
      ;;

    -s:*|--search:*)
      local val
      for val in $(split_csv "${token#*:}"); do
        jwrite --arg i "$iface" --arg v "$val" \
          '.interfaces[$i].resolver.search_domains |= (. + [$v] | unique)'
      done
      ;;

    -h|--dhcp)
      if [[ -z "$fam" || "$fam" == 4 ]]; then
        jwrite --arg i "$iface" '.interfaces[$i].ipv4.dhcp = true'
      fi
      if [[ -z "$fam" || "$fam" == 6 ]]; then
        jwrite --arg i "$iface" '
          .interfaces[$i].ipv6.accept_ra = true |
          .interfaces[$i].ipv6.dhcp = true
        '
      fi
      ;;

    -u|--up)
      jwrite --arg i "$iface" '.interfaces[$i].enabled = true'
      ;;

    -x|--down)
      jwrite --arg i "$iface" '.interfaces[$i].enabled = false'
      ;;

    -6o:*|--options:*)
      [[ "$fam" == 6 ]] || die "--options is only valid with -6"
      local raw="${token#*:}"
      local opts
      opts="$(printf '%s\n' $(split_csv "$raw") | sort -u | jq -R . | jq -s .)"
      echo "$opts" | jq -e '.[] | select(. == "ndpra")' >/dev/null 2>&1 \
        && die "'ndpra' is no longer a valid option; use -n / --ra to enable Router Advertisement acceptance"

      if echo "$opts" | jq -e 'index("none")' >/dev/null; then
        note "'none' disables all IPv6 automatic addressing"
        jwrite --arg i "$iface" '
          .interfaces[$i].ipv6.options = ["none"] |
          .interfaces[$i].ipv6.accept_ra = false |
          .interfaces[$i].ipv6.dhcp = false
        '
      else
        jwrite --arg i "$iface" --argjson opts "$opts" '
          .interfaces[$i].ipv6.options = $opts
        '
      fi
      ;;

    -n|--ndpra|--ra)
      [[ -z "$fam" || "$fam" == 6 ]] || die "--ra is IPv6-only"
      jwrite --arg i "$iface" '
        .interfaces[$i].ipv6.accept_ra = true |
        .interfaces[$i].ipv6.dhcp = false
      '
      ;;

    -i:*|--if:*)
      local val="${token#*:}"
      # Setting a parent on a non-VLAN interface declares it as PPPoE
      if [[ "$iface" =~ ^.+\.[0-9]+$ ]]; then
        die "--if: cannot override a VLAN parent; parent is derived from the interface name"
      fi
      jwrite --arg i "$iface" --arg v "$val" '
        .interfaces[$i].parent    = $v |
        .interfaces[$i].kind      = "pppoe" |
        .interfaces[$i].transport = "tunnel"
      '
      ;;

    --identity:*)
      local val="${token#*:}"
      jwrite --arg i "$iface" --arg v "$val" '.interfaces[$i].pppoe.identity = $v'
      ;;

    --pass:*)
      local val="${token#*:}"
      command -v systemd-creds >/dev/null 2>&1 \
        || die "--pass: requires systemd-creds (part of systemd)"
      local encrypted
      encrypted="$(printf '%s' "$val" \
        | systemd-creds encrypt --name="ip-mgr-pppoe-${iface}" - - \
        | base64 -w 0)" \
        || die "systemd-creds encryption failed for $iface"
      jwrite --arg i "$iface" --arg v "$encrypted" \
        '.interfaces[$i].pppoe.password = {"encrypted": $v}'
      ;;

    --svcname:*)
      local val="${token#*:}"
      jwrite --arg i "$iface" --arg v "$val" '.interfaces[$i].pppoe.service = $v'
      ;;

    *)
      die "unknown option '$token'"
      ;;
  esac
}

remove_option(){
  local fam="$1" iface="$2" token="$3"

  validate_iface "$iface"
  ensure_iface "$iface"

  case "$token" in
    -a:*|--address:*)
      local val fk
      for val in $(split_csv "${token#*:}"); do
        if [[ "$(family_of "$val")" == 6 ]]; then fk="ipv6"; else fk="ipv4"; fi
        jwrite --arg i "$iface" --arg fk "$fk" --arg v "$val" \
          '.interfaces[$i][$fk].addresses |= map(select(.address != $v))'
      done
      ;;

    -a|--address)
      if [[ "$fam" == 4 ]]; then
        jwrite --arg i "$iface" '.interfaces[$i].ipv4.addresses = []'
      elif [[ "$fam" == 6 ]]; then
        jwrite --arg i "$iface" '.interfaces[$i].ipv6.addresses = []'
      else
        jwrite --arg i "$iface" '.interfaces[$i].ipv4.addresses = [] | .interfaces[$i].ipv6.addresses = []'
      fi
      ;;

    -g:*|--gateway:*|--gw:*)
      local val fk
      for val in $(split_csv "${token#*:}"); do
        if [[ "$(family_of "$val")" == 6 ]]; then fk="ipv6"; else fk="ipv4"; fi
        jwrite --arg i "$iface" --arg fk "$fk" --arg v "$val" \
          '.interfaces[$i][$fk].gateways |= map(select(.address != $v))'
      done
      ;;

    -g|--gateway|--gw)
      if [[ "$fam" == 4 ]]; then
        jwrite --arg i "$iface" '.interfaces[$i].ipv4.gateways = []'
      elif [[ "$fam" == 6 ]]; then
        jwrite --arg i "$iface" '.interfaces[$i].ipv6.gateways = []'
      else
        jwrite --arg i "$iface" '.interfaces[$i].ipv4.gateways = [] | .interfaces[$i].ipv6.gateways = []'
      fi
      ;;

    -d:*|--dns:*)
      local val
      for val in $(split_csv "${token#*:}"); do
        jwrite --arg i "$iface" --arg v "$val" '.interfaces[$i].resolver.dns -= [$v]'
      done
      ;;

    -h|--dhcp)
      if [[ -z "$fam" || "$fam" == 4 ]]; then
        jwrite --arg i "$iface" '.interfaces[$i].ipv4.dhcp = false'
      fi
      if [[ -z "$fam" || "$fam" == 6 ]]; then
        jwrite --arg i "$iface" '.interfaces[$i].ipv6.dhcp = false'
      fi
      ;;

    -n|--ndpra|--ra)
      [[ -z "$fam" || "$fam" == 6 ]] || die "--ra is IPv6-only"
      jwrite --arg i "$iface" '
        .interfaces[$i].ipv6.accept_ra = false |
        .interfaces[$i].ipv6.dhcp = false
      '
      ;;

    -6o:*|--options:*)
      [[ "$fam" == 6 ]] || die "--options is only valid with -6"
      local val
      for val in $(split_csv "${token#*:}"); do
        jwrite --arg i "$iface" --arg v "$val" '.interfaces[$i].ipv6.options -= [$v]'
      done
      ;;

    -s:*|--search:*)
      local val
      for val in $(split_csv "${token#*:}"); do
        jwrite --arg i "$iface" --arg v "$val" \
          '.interfaces[$i].resolver.search_domains -= [$v]'
      done
      ;;

    -s|--search)
      jwrite --arg i "$iface" '.interfaces[$i].resolver.search_domains = []'
      ;;

    -i:|--if:)
      die "--if: defines the PPPoE parent; use 'remove $iface' (no options) to delete the connection"
      ;;

    --identity)
      jwrite --arg i "$iface" '.interfaces[$i].pppoe.identity = null'
      ;;

    --pass)
      jwrite --arg i "$iface" '.interfaces[$i].pppoe.password = null'
      ;;

    --svcname)
      jwrite --arg i "$iface" '.interfaces[$i].pppoe.service = null'
      ;;

    *)
      die "unknown remove option '$token'"
      ;;
  esac
}

is_pseudo_target(){
  case "$1" in dns:|domain:|domains:|ntp:|route:|routes:) return 0 ;; *) return 1 ;; esac
}

_note_backend_status(){
  # Emit a NOTE when the backend service for a configured setting isn't usable.
  local svc="$1"
  if ! _unit_installed "$svc"; then
    note "'${svc}' is not installed — setting written but will have no effect until ${svc} is installed and enabled."
  elif ! service_active "$svc"; then
    note "'${svc}' is not active — setting written but will have no effect until ${svc} is started (systemctl enable --now ${svc})."
  fi
}

set_pseudo(){
  local fam="$1" target="$2"
  shift 2

  if [[ "$target" == "route:" ]]; then
    local net="" via="" rif="" metric=""
    local _args=("$@") _i=0
    while [[ $_i -lt ${#_args[@]} ]]; do
      local _a="${_args[$_i]}"
      case "$_a" in
        --net:*)    net="${_a#--net:}" ;;
        --net)      _i=$(( _i + 1 )); net="${_args[$_i]}" ;;
        --via:*)    via="${_a#--via:}" ;;
        --via)      _i=$(( _i + 1 )); via="${_args[$_i]}" ;;
        --if:*)     rif="${_a#--if:}" ;;
        --if)       _i=$(( _i + 1 )); rif="${_args[$_i]}" ;;
        --metric:*) metric="${_a#--metric:}" ;;
        --metric)   _i=$(( _i + 1 )); metric="${_args[$_i]}" ;;
        *) die "route: unknown flag '$_a'" ;;
      esac
      _i=$(( _i + 1 ))
    done
    [[ -n "$net" ]] || die "route: --net is required"
    [[ -n "$via" ]] || die "route: --via is required"
    [[ -n "$rif" ]] || die "route: --if is required"
    validate_iface "$rif"
    ensure_iface "$rif"
    local net_fam via_fam fkey
    net_fam="$(family_of "$net")"
    via_fam="$(family_of "$via")"
    [[ "$net_fam" == "$via_fam" ]] || die "route: --net and --via address families do not match"
    [[ -z "$fam" || "$net_fam" == "$fam" ]] || die "route: --net does not match -$fam"
    [[ "$net_fam" == "4" ]] && fkey="ipv4" || fkey="ipv6"
    jwrite --arg rif "$rif" --arg net "$net" --arg via "$via" \
           --arg fkey "$fkey" --argjson met "${metric:-null}" '
      .interfaces[$rif][$fkey].routes |=
        (map(select(.destination != $net))
         + [{"destination": $net, "gateway": {"address": $via, "metric": $met}}])
    '
    return 0
  fi

  [[ $# -gt 0 ]] || die "$target: specify at least one value"

  local val
  for val in "$@"; do
    case "$target" in
      dns:|ntp:)
        [[ -z "$fam" || "$(family_of "$val")" == "$fam" ]] \
          || die "$val does not match -$fam"
        case "$target" in
          dns:) jwrite --arg v "$val" '.resolver.dns |= (. + [$v] | unique)' ;;
          ntp:) jwrite --arg v "$val" '.ntp.servers  |= (. + [$v] | unique)' ;;
        esac
        ;;
      domain:|domains:)
        jwrite --arg v "$val" '.resolver.search_domains |= (. + [$v] | unique)'
        ;;
    esac
  done

  case "$target" in
    dns:|domain:|domains:) _note_backend_status systemd-resolved  ;;
    ntp:)                  _note_backend_status systemd-timesyncd ;;
  esac
}

remove_pseudo(){
  local fam="$1" target="$2"
  shift 2

  if [[ "$target" == "route:" ]]; then
    local net="" rif="" clear_metric=false
    local _args=("$@") _i=0
    while [[ $_i -lt ${#_args[@]} ]]; do
      local _a="${_args[$_i]}"
      case "$_a" in
        --net:*)  net="${_a#--net:}" ;;
        --net)    _i=$(( _i + 1 )); net="${_args[$_i]}" ;;
        --if:*)   rif="${_a#--if:}" ;;
        --if)     _i=$(( _i + 1 )); rif="${_args[$_i]}" ;;
        --metric) clear_metric=true ;;
        *) die "route: unknown flag '$_a'" ;;
      esac
      _i=$(( _i + 1 ))
    done
    [[ -n "$net" ]] || die "route: --net is required"
    [[ -n "$rif" ]] || die "route: --if is required"
    local net_fam fkey
    net_fam="$(family_of "$net")"
    [[ "$net_fam" == "4" ]] && fkey="ipv4" || fkey="ipv6"
    if [[ "$clear_metric" == true ]]; then
      jwrite --arg rif "$rif" --arg net "$net" --arg fkey "$fkey" '
        .interfaces[$rif][$fkey].routes |=
          map(if .destination == $net then .gateway.metric = null else . end)
      '
    else
      jwrite --arg rif "$rif" --arg net "$net" --arg fkey "$fkey" '
        .interfaces[$rif][$fkey].routes |= map(select(.destination != $net))
      '
    fi
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    case "$target" in
      domains:)
        jwrite '.resolver.search_domains = []'
        return 0
        ;;
      domain:)
        die "domain: requires explicit names to remove; use 'domains:' with no arguments to clear all"
        ;;
      dns:|ntp:)
        [[ -n "$fam" ]] \
          || die "$target: specify values to remove, or use -4/-6 to clear all of that family"
        local jq_filter
        case "$target" in
          dns:) jq_filter='.resolver.dns  |= map(select(if $f=="4" then test(":") else (test(":")|not) end))' ;;
          ntp:) jq_filter='.ntp.servers   |= map(select(if $f=="4" then test(":") else (test(":")|not) end))' ;;
        esac
        jwrite --arg f "$fam" "$jq_filter"
        return 0
        ;;
    esac
  fi

  local val
  for val in "$@"; do
    case "$target" in
      dns:|ntp:)
        [[ -z "$fam" || "$(family_of "$val")" == "$fam" ]] \
          || die "$val does not match -$fam"
        case "$target" in
          dns:) jwrite --arg v "$val" '.resolver.dns   -= [$v]' ;;
          ntp:) jwrite --arg v "$val" '.ntp.servers    -= [$v]' ;;
        esac
        ;;
      domain:|domains:)
        jwrite --arg v "$val" '.resolver.search_domains -= [$v]'
        ;;
    esac
  done
}

# Normalize --flag VALUE (space-separated) to --flag:VALUE for known value-taking flags.
# ctx must be "set" or "remove" — the same flag may be bare in remove but valued in set.
# Populates global _NORMALIZED_FLAGS array.
normalize_flags(){
  local ctx="$1"; shift
  _NORMALIZED_FLAGS=()
  local _args=("$@") _i=0
  while [[ $_i -lt ${#_args[@]} ]]; do
    local _a="${_args[$_i]}" _valued=false
    case "$ctx:$_a" in
      # set: every flag that accepts a value
      set:-[agdmDsi]|set:--address|set:--gateway|set:--gw|set:--dns|\
      set:--mtu|set:--description|set:--search|set:-6o|set:--options|\
      set:-i|set:--if|set:--identity|set:--pass|set:--svcname)
        _valued=true ;;
      # remove: only list-item flags (address/gateway/dns/search need a value
      # to identify which entry to remove; mtu/description/identity/etc. are bare)
      remove:-[agds]|remove:--address|remove:--gateway|remove:--gw|\
      remove:--dns|remove:--search)
        _valued=true ;;
    esac
    if [[ "$_valued" == true ]]; then
      _i=$(( _i + 1 ))
      [[ $_i -lt ${#_args[@]} ]] || die "$_a requires a value"
      _NORMALIZED_FLAGS+=("${_a}:${_args[$_i]}")
    else
      _NORMALIZED_FLAGS+=("$_a")
    fi
    _i=$(( _i + 1 ))
  done
}

cmd_set(){
  local fam="$1" iface="$2"
  shift 2
  if is_pseudo_target "$iface"; then
    set_pseudo "$fam" "$iface" "$@"
    return 0
  fi
  normalize_flags set "$@"
  for t in "${_NORMALIZED_FLAGS[@]}"; do set_option "$fam" "$iface" "$t"; done
}
cmd_add(){ cmd_set "$@"; }

cmd_remove(){
  local fam="$1" iface="$2"
  shift 2

  if is_pseudo_target "$iface"; then
    remove_pseudo "$fam" "$iface" "$@"
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    validate_iface "$iface"
    local kind
    kind="$(jq -r --arg i "$iface" '.interfaces[$i].kind // empty' "$CANDIDATE")"
    [[ -n "$kind" ]] || die "interface '$iface' is not in the candidate"
    [[ "$kind" == "vlan" || "$kind" == "pppoe" ]] \
      || die "'remove $iface' with no settings only removes VLAN or PPPoE interfaces; specify a setting to remove"
    [[ "$kind" == "pppoe" && "${PROJECTING:-no}" != "yes" ]] && rm -f "$PPPOE_SECRETS_DIR/pppoe-${iface}.secret"
    local tmp
    tmp="$(candidate_tmp_path)"
    jq --arg i "$iface" 'del(.interfaces[$i])' "$CANDIDATE" > "$tmp"
    mv "$tmp" "$CANDIDATE"
    echo "$kind interface $iface removed from candidate."
    return 0
  fi

  normalize_flags remove "$@"
  for t in "${_NORMALIZED_FLAGS[@]}"; do remove_option "$fam" "$iface" "$t"; done
}

# ===== state collection =====

write_iface_json(){
  local file="$1" tmp="$2" iface="$3"
  local mtu state transport kind managed parent="" vlan_id_json="null"
  mtu="$(iface_mtu "$iface")"
  state="$(iface_operstate "$iface")"
  transport="$(iface_transport "$iface")"
  kind="$(iface_kind "$iface")"
  managed="$(iface_managed_default "$iface")"
  if [[ "$kind" == "vlan" ]]; then
    parent="${iface%.*}"
    vlan_id_json="${iface##*.}"
  fi

  jq --arg i "$iface" --arg transport "$transport" --arg kind "$kind" \
     --argjson managed "$managed" --argjson mtu "$mtu" --arg state "$state" \
     --arg parent "$parent" --argjson vlan_id "$vlan_id_json" '
    .interfaces[$i] = {
      managed:     $managed,
      transport:   $transport,
      kind:        $kind,
      enabled:     ($state != "down"),
      mtu:         $mtu,
      description: null,
      parent:      (if $parent != "" then $parent else null end),
      vlan_id:     $vlan_id,
      ipv4:     { dhcp: false, addresses: [], gateways: [], routes: [] },
      ipv6:     { dhcp: false, accept_ra: false, options: [], addresses: [], gateways: [], routes: [] },
      resolver: { dns: [], search_domains: [] },
      observed: { addresses: [], link_local: [], gateways: [], dynamic: { dhcp4: [], ra: [] } }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

record_address(){
  local file="$1" tmp="$2" iface="$3" family="$4" addr="$5" proto="$6" scope="$7"
  local fk managed
  managed="$(jq -r --arg i "$iface" '.interfaces[$i].managed' "$file")"

  if [[ "$managed" != "true" ]]; then
    if [[ "$family" == "inet6" ]] && is_lla "$addr"; then
      jq --arg i "$iface" --arg a "$addr" \
        '.interfaces[$i].observed.link_local += [$a]' "$file" > "$tmp"
    else
      jq --arg i "$iface" --arg a "$addr" \
        '.interfaces[$i].observed.addresses |= (. + [$a] | unique)' "$file" > "$tmp"
    fi
    mv "$tmp" "$file"
    return
  fi

  case "$family:$scope" in
    inet6:link)
      jq --arg i "$iface" --arg a "$addr" \
        '.interfaces[$i].observed.link_local += [$a]' "$file" > "$tmp"
      ;;
    inet:global|inet6:global)
      if [[ "$family" == "inet6" ]] && is_lla "$addr"; then
        jq --arg i "$iface" --arg a "$addr" \
          '.interfaces[$i].observed.link_local += [$a]' "$file" > "$tmp"
      elif [[ "$proto" == "dynamic" ]]; then
        if [[ "$family" == "inet" ]]; then
          jq --arg i "$iface" --arg a "$addr" '
            .interfaces[$i].ipv4.dhcp = true |
            .interfaces[$i].observed.dynamic.dhcp4 += [$a]
          ' "$file" > "$tmp"
        else
          jq --arg i "$iface" --arg a "$addr" '
            .interfaces[$i].ipv6.accept_ra = true |
            .interfaces[$i].observed.dynamic.ra += [$a]
          ' "$file" > "$tmp"
        fi
      else
        if [[ "$family" == "inet6" ]]; then fk="ipv6"; else fk="ipv4"; fi
        jq --arg i "$iface" --arg fk "$fk" --arg a "$addr" '
          .interfaces[$i][$fk].addresses |= (. + [{"address": $a}] | unique_by(.address))
        ' "$file" > "$tmp"
      fi
      ;;
    *) return ;;
  esac

  mv "$tmp" "$file"
}

collect_addresses(){
  local file="$1" tmp="$2" iface="$3"
  local family addr proto scope
  while read -r family addr proto scope; do
    record_address "$file" "$tmp" "$iface" "$family" "$addr" "$proto" "$scope"
  done < <(ip_addr_rows "$iface")
}

record_gateway(){
  local file="$1" tmp="$2" iface="$3" fam="$4" gw="$5" metric="${6:-}"
  local fk metric_json="null" managed

  [[ -z "$gw" ]] && return 0
  managed="$(jq -r --arg i "$iface" '.interfaces[$i].managed' "$file")"
  [[ "$managed" == "true" ]] || return 0

  if [[ "$fam" == 6 ]] && is_lla "$gw"; then
    jq --arg i "$iface" --arg g "$gw" \
      '.interfaces[$i].observed.gateways |= (. + [$g] | unique)' "$file" > "$tmp"
    mv "$tmp" "$file"
    return
  fi

  [[ -n "$metric" ]] && metric_json="$metric"
  if [[ "$fam" == 6 ]]; then fk="ipv6"; else fk="ipv4"; fi

  jq --arg i "$iface" --arg fk "$fk" --arg g "$gw" --argjson metric "$metric_json" '
    .interfaces[$i][$fk].gateways |= (. + [{"address": $g, "metric": $metric, "scope": "global", "on_link": false}] | unique_by(.address))
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

collect_gateways(){
  local file="$1" tmp="$2" iface="$3"
  local gw metric

  while read -r gw metric; do
    record_gateway "$file" "$tmp" "$iface" 4 "$gw" "$metric"
  done < <(default_gateway_rows 4 "$iface")

  while read -r gw metric; do
    record_gateway "$file" "$tmp" "$iface" 6 "$gw" "$metric"
  done < <(default_gateway_rows 6 "$iface")
}

actual_json(){
  local work tmp iface
  work="$(actual_tmp_path)"
  tmp="$(work_tmp_path)"

  empty_state_json > "$work"

  while read -r iface; do
    write_iface_json "$work" "$tmp" "$iface"
    collect_addresses "$work" "$tmp" "$iface"
    collect_gateways "$work" "$tmp" "$iface"
  done < <(each_physical_iface)

  cat "$work"
  rm -f "$work" "$tmp"
}

# ===== display/compare/version =====

render_state_as_commands(){
  local file="$1"
  local filter="${2:-}"   # optional: interface name or pseudo-target (dns: ntp: domains:)
  local tool; tool="$(basename "$0")"

  echo "# ip-mgr configuration export"
  echo "# Source: $file"
  [[ -n "$filter" ]] && echo "# Filter: $filter"
  echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo

  # Global resolver and NTP — emitted only when no filter or filter is a pseudo-target
  case "$filter" in
    ""|dns:|domains:|ntp:)
      jq -r --arg t "$tool" --arg f "$filter" '
        ([ .resolver.dns[]? | select(test(":")|not) ] | join(" ")) as $v4dns |
        ([ .resolver.dns[]? | select(test(":"))      ] | join(" ")) as $v6dns |
        (  .resolver.search_domains // []            | join(" ")) as $sd |
        (  .ntp.servers // []                        | join(" ")) as $ntp |
        if ($f != "ntp:" and ($v4dns|length) > 0) then $t + " set dns: "     + $v4dns else empty end,
        if ($f != "ntp:" and ($v6dns|length) > 0) then $t + " -6 set dns: "  + $v6dns else empty end,
        if ($f != "ntp:" and ($sd   |length) > 0) then $t + " set domains: " + $sd    else empty end,
        if ($f == "" or $f == "ntp:") then
          if ($ntp|length) > 0 then $t + " set ntp: " + $ntp else empty end
        else empty end
      ' "$file"
      ;;
  esac

  # Pseudo-target filters are fully handled above
  case "$filter" in
    dns:|domains:|ntp:) return ;;
    route:|routes:)
      jq -r --arg t "$tool" '
        .interfaces | to_entries[] | .key as $i |
        (.value.ipv4.routes[]? | $t + " -4 add route: --net " + .destination + " --via " + .gateway.address
          + (if .gateway.metric != null then " --metric " + (.gateway.metric|tostring) else "" end)
          + " --if " + $i),
        (.value.ipv6.routes[]? | $t + " -6 add route: --net " + .destination + " --via " + .gateway.address
          + (if .gateway.metric != null then " --metric " + (.gateway.metric|tostring) else "" end)
          + " --if " + $i)
      ' "$file"
      return ;;
    "")  ;;  # no filter — process all interfaces below
    *)
      # Validate the interface filter before looping
      jq -e --arg i "$filter" '.interfaces | has($i)' "$file" >/dev/null 2>&1 \
        || die "show: '$filter' not found in state"
      ;;
  esac

  # Per-interface commands
  jq -r '.interfaces | keys[]' "$file" | while IFS= read -r iface; do
    [[ -n "$filter" && "$filter" != "$iface" ]] && continue
    local managed kind
    managed="$(jq -r --arg i "$iface" '.interfaces[$i].managed' "$file")"
    [[ "$managed" == "true" ]] || continue
    kind="$(jq -r --arg i "$iface" '.interfaces[$i].kind // "ethernet"' "$file")"

    echo
    echo "# --- $iface ---"

    jq -r --arg i "$iface" --arg t "$tool" '
      .interfaces[$i] as $cfg |
      if $cfg.description != null then $t + " set " + $i + " --description " + ($cfg.description | @sh) else empty end,
      if $cfg.mtu        != null then $t + " set " + $i + " --mtu "         + ($cfg.mtu | tostring)    else empty end,
      if $cfg.enabled    == false then $t + " set " + $i + " --down"                                   else empty end,
      if $cfg.ipv4.dhcp          then $t + " set " + $i + " --dhcp"                                   else empty end,
      if $cfg.ipv6.dhcp          then $t + " -6 set " + $i + " --dhcp"                                else empty end,
      if $cfg.ipv6.accept_ra     then $t + " set " + $i + " --ra"                                     else empty end,
      ([ $cfg.ipv6.options[]? | select(. != "none") ] | join(",")) as $opts |
      if ($opts | length) > 0  then $t + " -6 set " + $i + " --options " + $opts                    else empty end,
      ($cfg.ipv4.addresses[]?.address  | $t + " set "    + $i + " --address " + .),
      ($cfg.ipv6.addresses[]?.address  | $t + " -6 set " + $i + " --address " + .),
      ($cfg.ipv4.gateways[]? |
        if .metric == null
        then $t + " set "    + $i + " --gateway " + .address
        else "# metric " + (.metric|tostring) + ": " + $t + " -4 add route: --net 0.0.0.0/0 --via " + .address + " --if " + $i + " --metric " + (.metric|tostring)
        end),
      ($cfg.ipv6.gateways[]? |
        if .metric == null
        then $t + " -6 set " + $i + " --gateway " + .address
        else "# metric " + (.metric|tostring) + ": " + $t + " -6 add route: --net ::/0 --via " + .address + " --if " + $i + " --metric " + (.metric|tostring)
        end),
      ($cfg.resolver.dns[]?             | $t + " set " + $i + " --dns "    + .),
      ($cfg.resolver.search_domains[]?  | $t + " set " + $i + " --search " + .),
      ($cfg.ipv4.routes[]? | $t + " -4 add route: --net " + .destination + " --via " + .gateway.address
        + (if .gateway.metric != null then " --metric " + (.gateway.metric|tostring) else "" end)
        + " --if " + $i),
      ($cfg.ipv6.routes[]? | $t + " -6 add route: --net " + .destination + " --via " + .gateway.address
        + (if .gateway.metric != null then " --metric " + (.gateway.metric|tostring) else "" end)
        + " --if " + $i)
    ' "$file"

    # PPPoE credentials — password cannot be exported (machine-bound)
    if [[ "$kind" == "pppoe" ]]; then
      local parent identity svcname pline
      parent="$(  jq -r --arg i "$iface" '.interfaces[$i].parent            // empty' "$file")"
      identity="$(jq -r --arg i "$iface" '.interfaces[$i].pppoe.identity    // empty' "$file")"
      svcname="$( jq -r --arg i "$iface" '.interfaces[$i].pppoe.service     // empty' "$file")"
      pline="$tool set $iface"
      [[ -n "$parent"   ]] && pline+=" --if $parent"
      [[ -n "$identity" ]] && pline+=" --identity $identity"
      [[ -n "$svcname"  ]] && pline+=" --svcname $svcname"
      echo "$pline"
      echo "# $tool set $iface --pass <re-enter manually — credential is machine-bound>"
    fi
  done
}

render_state_human(){
  local file="$1"
  local fam="${2:-}"
  local filter="${3:-}"
  local label="${4:-}"   # contextual "source · timestamp" line for plain output

  # Join a jq array expression into "a, b, c" or "-" if empty.
  _rsh_csv(){
    jq -r "$1 | if length == 0 then \"-\" else join(\", \") end" "$file"
  }

  _rsh_global(){
    jq -r '
      "System:",
      "  host:       " + (.host.name // "-"),
      "  tool:       " + (.managed_by // "-") + " " + (.tool_version // "-"),
      "  schema:     " + ((.schema_version // "-") | tostring)
    ' "$file"
    [[ -n "$label" ]] && printf '  source:     %s\n' "$label"

    echo
    echo "Resolver:"
    case "$fam" in
      4)
        printf '  dns:        %s\n' "$(_rsh_csv '.resolver.dns // [] | map(select(test(":")|not))')"
        ;;
      6)
        printf '  dns:        %s\n' "$(_rsh_csv '.resolver.dns // [] | map(select(test(":")))')"
        ;;
      *)
        printf '  dns4:       %s\n' "$(_rsh_csv '.resolver.dns // [] | map(select(test(":")|not))')"
        printf '  dns6:       %s\n' "$(_rsh_csv '.resolver.dns // [] | map(select(test(":")))')"
        ;;
    esac
    printf '  search:     %s\n' "$(_rsh_csv '.resolver.search_domains // []')"

    local _ntp
    _ntp="$(_rsh_csv '.ntp.servers // []')"
    if [[ "$_ntp" != "-" ]]; then
      echo
      echo "NTP:"
      printf '  servers:    %s\n' "$_ntp"
    fi
  }

  _rsh_routes(){
    local _out
    _out="$(jq -r --arg fam "$fam" '
      def gw_str:
        if .gateway then
          .gateway.address
          + (if (.gateway.metric // null) != null
             then " metric " + (.gateway.metric|tostring) else "" end)
        else "-" end;
      .interfaces | to_entries[] | .key as $i |
      if $fam == "4" then
        .value.ipv4.routes[]? | "  " + $i + "  ipv4  " + .destination + " via " + gw_str
      elif $fam == "6" then
        .value.ipv6.routes[]? | "  " + $i + "  ipv6  " + .destination + " via " + gw_str
      else
        (.value.ipv4.routes[]? | "  " + $i + "  ipv4  " + .destination + " via " + gw_str),
        (.value.ipv6.routes[]? | "  " + $i + "  ipv6  " + .destination + " via " + gw_str)
      end
    ' "$file")"
    if [[ -n "$_out" ]]; then
      echo "$_out"
    else
      echo "  (none)"
    fi
  }

  _rsh_iface(){
    local i="$1"

    jq -r --arg i "$i" '
      .interfaces[$i] as $x |
      ($x.kind // "unknown") + "/" + ($x.transport // "unknown") as $type |
      (if $x.enabled then "UP"      else "DOWN"     end)         as $state |
      (if $x.managed then "managed" else "observed" end)         as $mgmt  |
      $i + ":  " + $type + "  " + $state + "  " + $mgmt,
      "  mtu:        " + (($x.mtu // "-") | tostring),
      "  desc:       " + ($x.description // "-"),
      if ($x.parent  // null) != null then "  parent:     " + $x.parent             else empty end,
      if ($x.vlan_id // null) != null then "  vlan:       " + ($x.vlan_id|tostring) else empty end,
      if $x.kind == "pppoe" then
        "  identity:   " + ($x.pppoe.identity // "-"),
        "  pppoe-svc:  " + (if ($x.pppoe.service // "") == "" then "(any)" else $x.pppoe.service end),
        "  password:   " + (if ($x.pppoe.password.encrypted // null) != null then "set" else "unset" end)
      else empty end
    ' "$file"

    if [[ "$fam" != "6" ]]; then
      jq -r --arg i "$i" '
        .interfaces[$i] as $x |
        "  inet4:",
        "    dhcp:    " + ($x.ipv4.dhcp|tostring),
        "    addr:    " + ([$x.ipv4.addresses[]?.address]
                          | if length == 0 then "-" else join(", ") end),
        "    gw:      " + ([$x.ipv4.gateways[]?
                           | .address + (if (.metric // null) != null
                             then " metric " + (.metric|tostring) else "" end)]
                          | if length == 0 then "-" else join(", ") end),
        "    routes:  " + ([$x.ipv4.routes[]?
                           | .destination + " via " + (.gateway.address // "-")
                             + (if (.gateway.metric // null) != null
                                then " metric " + (.gateway.metric|tostring) else "" end)]
                          | if length == 0 then "-" else join("; ") end),
        "    dyn:     " + ([$x.observed.dynamic.dhcp4[]?]
                          | if length == 0 then "-" else join(", ") end)
      ' "$file"
    fi

    if [[ "$fam" != "4" ]]; then
      jq -r --arg i "$i" '
        .interfaces[$i] as $x |
        "  inet6:",
        "    dhcp:    " + ($x.ipv6.dhcp|tostring),
        "    ra:      " + ($x.ipv6.accept_ra|tostring),
        "    opts:    " + ($x.ipv6.options // [] | if length == 0 then "-" else join(", ") end),
        "    addr:    " + ([$x.ipv6.addresses[]?.address]
                          | if length == 0 then "-" else join(", ") end),
        "    gw:      " + ([$x.ipv6.gateways[]?
                           | .address + (if (.metric // null) != null
                             then " metric " + (.metric|tostring) else "" end)]
                          | if length == 0 then "-" else join(", ") end),
        "    routes:  " + ([$x.ipv6.routes[]?
                           | .destination + " via " + (.gateway.address // "-")
                             + (if (.gateway.metric // null) != null
                                then " metric " + (.gateway.metric|tostring) else "" end)]
                          | if length == 0 then "-" else join("; ") end),
        "    lla:     " + ([$x.observed.link_local[]?]
                          | if length == 0 then "-" else join(", ") end),
        "    dyn-ra:  " + ([$x.observed.dynamic.ra[]?]
                          | if length == 0 then "-" else join(", ") end)
      ' "$file"
    fi

    jq -r --arg i "$i" '
      .interfaces[$i] as $x |
      "  resolver:",
      "    dns:     " + ($x.resolver.dns // [] | if length == 0 then "-" else join(", ") end),
      "    search:  " + ($x.resolver.search_domains // [] | if length == 0 then "-" else join(", ") end)
    ' "$file"

    echo
  }

  # Pseudo-target fast-path
  case "$filter" in
    dns:)
      case "$fam" in
        4) _rsh_csv '.resolver.dns // [] | map(select(test(":")|not))' ;;
        6) _rsh_csv '.resolver.dns // [] | map(select(test(":")))'     ;;
        *) _rsh_csv '.resolver.dns // []' ;;
      esac
      return ;;
    domain:|domains:)
      _rsh_csv '.resolver.search_domains // []'
      return ;;
    ntp:)
      _rsh_csv '.ntp.servers // []'
      return ;;
    route:|routes:)
      echo "Routes:"
      _rsh_routes
      return ;;
  esac

  # Single interface filter
  if [[ -n "$filter" ]]; then
    if ! jq -e --arg i "$filter" '.interfaces | has($i)' "$file" >/dev/null 2>&1; then
      local _avail
      _avail="$(jq -r '.interfaces | keys | if length == 0 then "(none)" else join(", ") end' "$file")"
      die "show: interface '${filter}' not found in state (available: ${_avail})"
    fi
    _rsh_iface "$filter"
    return
  fi

  # Full state
  _rsh_global
  echo
  echo "Interfaces:"
  jq -r '.interfaces | keys[]' "$file" | while IFS= read -r iface; do
    _rsh_iface "$iface"
  done
}

cmd_show(){
  local fam="${1:-}"
  shift || true
  local what="expected"
  local iface=""
  local output_fmt="plain"
  local _what_explicit=no

  for arg in "$@"; do
    case "$arg" in
      --as:*)
        case "${arg#--as:}" in
          [Jj][Ss][Oo][Nn])         output_fmt="json"  ;;
          [Cc][Mm][Dd])             output_fmt="cmd"   ;;
          [Pp][Ll][Aa][Ii][Nn])     output_fmt="plain" ;;
          *) die "show: unknown --as value '${arg#--as:}' (expected: plain, json, cmd)" ;;
        esac ;;
      --file:*|-f:*)
        what="$arg" ;;
      candidate|cand|expected|exp|actual|act)
        what="$arg"; _what_explicit=yes ;;
      version)
        cmd_version; return ;;
      -*)
        die "show: unknown option '$arg'" ;;
      *)
        [[ -z "$iface" ]] || die "show: unexpected argument '$arg'"
        iface="$arg"
        ;;
    esac
  done

  # JSON-mode iface display — preserves pre-3.0 semantics
  _show_iface_json(){
    local _f="$1" _i="$2"
    if ! jq -e --arg i "$_i" '.interfaces | has($i)' "$_f" >/dev/null 2>&1; then
      local _avail
      _avail="$(jq -r '.interfaces | keys | if length == 0 then "(none)" else join("  ") end' "$_f")"
      printf "ERROR: '%s' not found.\n" "$_i" >&2
      printf '%-28s  %s\n' "Available interfaces:" "Available objects:" >&2
      printf '  %-26s  %s\n' "$_avail" "dns:  domains:  ntp:  route:" >&2
      return 1
    fi
    if [[ "$fam" == "4" ]]; then
      jq --arg i "$_i" '.interfaces[$i].ipv4' "$_f"
    elif [[ "$fam" == "6" ]]; then
      jq --arg i "$_i" '.interfaces[$i].ipv6' "$_f"
    else
      local parent
      parent="$(jq -r --arg i "$_i" '.interfaces[$i].parent // empty' "$_f")"
      if [[ -n "$parent" ]] && jq -e --arg p "$parent" '.interfaces | has($p)' "$_f" >/dev/null 2>&1; then
        jq --arg i "$_i" --arg p "$parent" '{($p): .interfaces[$p], ($i): .interfaces[$i]}' "$_f"
      else
        jq --arg i "$_i" '.interfaces[$i]' "$_f"
      fi
    fi
  }

  # JSON-mode pseudo-target display — preserves pre-3.0 semantics
  _show_pseudo_json(){
    local _f="$1" _tgt="$2"
    case "$_tgt" in
      dns:)
        case "$fam" in
          4) jq '.resolver.dns | map(select(test(":")|not))' "$_f" ;;
          6) jq '.resolver.dns | map(select(test(":")))' "$_f" ;;
          *) jq '.resolver' "$_f" ;;
        esac ;;
      domain:|domains:) jq '.resolver.search_domains' "$_f" ;;
      ntp:)             jq '.ntp // {"servers":[]}' "$_f" ;;
      route:|routes:)
        case "$fam" in
          4) jq '[.interfaces | to_entries[] | .key as $i |
                  .value.ipv4.routes[]? | {interface: $i, family: "ipv4"} + .]' "$_f" ;;
          6) jq '[.interfaces | to_entries[] | .key as $i |
                  .value.ipv6.routes[]? | {interface: $i, family: "ipv6"} + .]' "$_f" ;;
          *) jq '[.interfaces | to_entries[] | .key as $i |
                  (.value.ipv4.routes[]? | {interface: $i, family: "ipv4"} + .),
                  (.value.ipv6.routes[]? | {interface: $i, family: "ipv6"} + .)
                ]' "$_f" ;;
        esac ;;
      *) die "show: unknown pseudo-target '$_tgt'" ;;
    esac
  }

  # When show is called with no explicit source and changes are staged,
  # default to showing the pending (candidate) state.
  if [[ "$_what_explicit" == "no" ]] && has_pending; then
    what="candidate"
  fi

  local file _tmp=""
  case "$what" in
    actual|act)
      _tmp="$(state_tmp_path)"
      actual_json > "$_tmp"
      file="$_tmp" ;;
    candidate|cand)
      if has_journal; then
        _tmp="$(_project_candidate)"
        file="$_tmp"
      elif [[ -f "$CANDIDATE" ]]; then
        file="$CANDIDATE"
      else
        die "show: no staged changes (use 'show expected' to see the committed state)"
      fi ;;
    *)
      file="$(state_file "$what")" ;;
  esac

  # Compute a contextual source label for plain output.
  # File mtimes are used (not JSON created/modified fields) so the timestamp is
  # meaningful for actual (captured now) and candidate (when last staged).
  local _state_label="" _mts
  case "$what" in
    actual|act)
      _state_label="actual · $(date '+%Y-%m-%d %H:%M:%S')" ;;
    candidate|cand)
      if has_journal; then
        _mts="$(date -d "@$(stat -c '%Y' "$JOURNAL" 2>/dev/null)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
        _state_label="candidate · staged $_mts"
      elif [[ -f "$CANDIDATE" ]]; then
        _mts="$(date -d "@$(stat -c '%Y' "$CANDIDATE" 2>/dev/null)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
        _state_label="candidate · staged $_mts"
      fi ;;
    expected|exp)
      _mts="$(date -d "@$(stat -c '%Y' "$EXPECTED" 2>/dev/null)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
      _state_label="expected · committed $_mts" ;;
    --file:*|-f:*)
      local _fpath="${what#*:}"
      _mts="$(date -d "@$(stat -c '%Y' "$_fpath" 2>/dev/null)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
      _state_label="file: $(basename "$_fpath") · $_mts" ;;
  esac

  case "$output_fmt" in
    cmd)
      render_state_as_commands "$file" "$iface"
      ;;
    json)
      if [[ -n "$iface" ]]; then
        if is_pseudo_target "$iface"; then
          _show_pseudo_json "$file" "$iface"
        else
          _show_iface_json  "$file" "$iface"
        fi
      elif [[ -n "$fam" ]]; then
        jq --arg f "ipv${fam}" \
          '.interfaces | to_entries | map({key: .key, value: .value[$f]}) | from_entries' "$file"
      else
        jq . "$file"
      fi
      ;;
    plain)
      render_state_human "$file" "$fam" "$iface" "$_state_label"
      ;;
  esac

  [[ -n "$_tmp" ]] && rm -f "$_tmp"
}

cmd_compare(){
  # Smart default for b: compare against staged changes if present, live state if not.
  local _b_def; has_pending && _b_def="candidate" || _b_def="actual"
  local a="${1:-expected}"
  local b="${2:-$_b_def}"
  local -a _cleanup=()
  local fa fb

  # Print context when both sides came from smart defaults (user typed just 'compare')
  if [[ $# -eq 0 ]]; then
    has_pending \
      && echo "# staged changes present — comparing: expected → candidate" \
      || echo "# no staged changes — comparing: expected → actual"
  fi

  fa="$(state_file "$a")"
  # actual always returns a temp; candidate returns a temp only when journal exists
  if [[ "$a" == "actual" || "$a" == "act" ]] || \
     { [[ "$a" == "candidate" || "$a" == "cand" ]] && has_journal; }; then
    _cleanup+=("$fa")
  fi

  fb="$(state_file "$b")"
  if [[ "$b" == "actual" || "$b" == "act" ]] || \
     { [[ "$b" == "candidate" || "$b" == "cand" ]] && has_journal; }; then
    _cleanup+=("$fb")
  fi

  diff -u <(jq -S . "$fa") <(jq -S . "$fb") || true
  (( ${#_cleanup[@]} > 0 )) && rm -f "${_cleanup[@]}"
}

# ===== validation commands =====

validate_pppoe(){
  local errors
  errors="$(jq -r '
    .interfaces as $ifaces
    | $ifaces | to_entries[]
    | select(.value.kind == "pppoe")
    | .key as $iface
    | .value as $cfg
    | if $cfg.parent == null then
        "ERROR: " + $iface + ": PPPoE interface has no parent set (use -i:IFACE)"
      elif $ifaces[$cfg.parent] == null then
        "ERROR: " + $iface + ": parent interface " + $cfg.parent + " is not in candidate"
      elif $ifaces[$cfg.parent].managed != true then
        "ERROR: " + $iface + ": parent interface " + $cfg.parent + " is not managed by ip-mgr"
      elif ($cfg.pppoe.identity // "") == "" then
        "ERROR: " + $iface + ": PPPoE identity not set (use --identity:USER)"
      elif $cfg.pppoe.password == null then
        "ERROR: " + $iface + ": PPPoE password not set (use --pass:SECRET)"
      else empty end
  ' "$CANDIDATE")"
  if [[ -n "$errors" ]]; then
    printf '%s\n' "$errors" >&2
    return 1
  fi
}

validate_vlan_parents(){
  local errors
  errors="$(jq -r '
    .interfaces as $ifaces
    | $ifaces | to_entries[]
    | select(.value.kind == "vlan")
    | .key as $vlan
    | .value.parent as $parent
    | if $parent == null then
        "ERROR: " + $vlan + ": VLAN has no parent set"
      elif $ifaces[$parent] == null then
        "ERROR: " + $vlan + ": parent interface " + $parent + " is not in candidate"
      elif $ifaces[$parent].managed != true then
        "ERROR: " + $vlan + ": parent interface " + $parent + " is not managed by ip-mgr"
      else empty end
  ' "$CANDIDATE")"
  if [[ -n "$errors" ]]; then
    printf '%s\n' "$errors" >&2
    return 1
  fi
}

cmd_validate(){
  # When called by the user (journal mode), project the journal into a temp
  # state and shadow CANDIDATE so every read below uses the projected JSON.
  # When called during commit replay JOURNAL_MODE="no" and CANDIDATE already
  # points at the projected temp — so we fall straight through.
  local _val_tmp=""
  if [[ "${JOURNAL_MODE:-yes}" == "yes" ]]; then
    has_pending || die "nothing to validate (no staged changes)"
    if has_journal; then
      _val_tmp="$(_project_candidate)"
    else
      _val_tmp="$CANDIDATE"   # wholesale candidate.json from cmd_clean
    fi
    local CANDIDATE="$_val_tmp"
  fi
  local _cleanup_val="${_val_tmp:+$_val_tmp}"

  jq empty "$CANDIDATE" >/dev/null || { rm -f "$_cleanup_val"; die "candidate JSON invalid"; }

  local enum_errors
  enum_errors="$(jq -r '
    .interfaces | to_entries[] | .key as $i | .value |
    if (.transport | IN("ethernet","tunnel") | not) then
      $i + ": unknown transport \"" + .transport + "\""
    elif (.kind | IN("ethernet","vlan","wifi","pppoe","wireguard","tun","tap","gre","nhrp","ike") | not) then
      $i + ": unknown kind \"" + .kind + "\""
    else empty
    end
  ' "$CANDIDATE")"
  [[ -z "$enum_errors" ]] || die "$enum_errors"

  managed_ifaces | while read -r iface; do
    validate_iface "$iface"

    jq -r --arg i "$iface" '.interfaces[$i].ipv4.addresses[].address // empty' "$CANDIDATE" | while read -r addr; do
      if [[ "$(family_of "$addr")" == 6 ]] && is_lla "$addr"; then
        die "$iface: invalid managed LLA in ipv4.addresses: $addr"
      fi
    done

    jq -r --arg i "$iface" '.interfaces[$i].ipv6.addresses[].address // empty' "$CANDIDATE" | while read -r addr; do
      if [[ "$(family_of "$addr")" == 6 ]] && is_lla "$addr"; then
        die "$iface: invalid managed LLA in ipv6.addresses: $addr"
      fi
    done
  done

  validate_vlan_parents || die "VLAN parent validation failed"
  validate_pppoe        || die "PPPoE validation failed"

  echo "candidate validates"
  [[ -n "$_cleanup_val" ]] && has_journal && rm -f "$_cleanup_val"
}

validate_renderer_capabilities(){
  local blockers

  blockers="$(
    jq -r '
      .interfaces
      | to_entries[]
      | .key as $iface
      | .value.ipv6.gateways[]?
      | select((.scope // "global") == "link" or (.on_link // false) == true)
      | "  " + $iface + ": scoped/on-link IPv6 gateway " + .address + " is not rendered yet."
    ' "$CANDIDATE"
  )"

  if [[ -n "$blockers" ]]; then
    echo "ERROR: candidate uses features the current renderer cannot safely apply:" >&2
    printf '%s\n' "$blockers" >&2
    return 1
  fi
}

managed_ifaces(){
  jq -r '.interfaces | to_entries[] | select(.value.managed == true) | .key' "$CANDIDATE"
}

# ===== renderer =====

render_networkd(){
  rm -f "$NETWORKD"/10-ip-mgr-*.network
  rm -f "$NETWORKD"/10-ip-mgr-*.netdev
  rm -f "$PPPOE_SECRETS_DIR"/pppoe-*.secret
  mkdir -p "$NETWORKD"

  # Generate .netdev files for VLAN interfaces
  jq -r '
    .interfaces | to_entries[]
    | select(.value.kind == "vlan" and .value.managed == true)
    | .key
  ' "$CANDIDATE" | while read -r iface; do
    local vlan_id
    vlan_id="$(jq -r --arg i "$iface" '.interfaces[$i].vlan_id' "$CANDIDATE")"
    {
      echo "[NetDev]"
      echo "Name=$iface"
      echo "Kind=vlan"
      echo
      echo "[VLAN]"
      echo "Id=$vlan_id"
    } > "$NETWORKD/10-ip-mgr-$iface.netdev"
  done

  managed_ifaces | while read -r iface; do
    # PPPoE interfaces render via their parent's .network file — no separate file
    local kind
    kind="$(jq -r --arg i "$iface" '.interfaces[$i].kind' "$CANDIDATE")"
    [[ "$kind" == "pppoe" ]] && continue

    local f="$NETWORKD/10-ip-mgr-$iface.network"
    local enabled mtu

    enabled="$(jq -r --arg i "$iface" '.interfaces[$i].enabled' "$CANDIDATE")"
    mtu="$(jq -r --arg i "$iface" '.interfaces[$i].mtu // empty' "$CANDIDATE")"

    {
      echo "[Match]"
      echo "Name=$iface"
      echo
      echo "[Link]"
      [[ "$enabled" == false ]] && echo "Unmanaged=yes"
      [[ -n "$mtu" ]] && echo "MTUBytes=$mtu"
      echo
      echo "[Network]"

      jq -r --arg i "$iface" '
        (.interfaces[$i].ipv4.dhcp // false) as $d4 |
        (.interfaces[$i].ipv6.dhcp // false) as $d6 |
        if $d4 and $d6 then "DHCP=yes"
        elif $d4 then "DHCP=ipv4"
        elif $d6 then "DHCP=ipv6"
        else "DHCP=no" end
      ' "$CANDIDATE"

      [[ "$(jq -r --arg i "$iface" '.interfaces[$i].ipv6.accept_ra' "$CANDIDATE")" == true ]] \
        && echo "IPv6AcceptRA=yes" || echo "IPv6AcceptRA=no"

      jq -r --arg i "$iface" '
        .interfaces[$i].ipv6.options as $o |
        if ($o | contains(["none"])) then empty
        elif ($o | contains(["stable"]) and contains(["privacy"])) then "IPv6PrivacyExtensions=yes"
        elif ($o | contains(["privacy"])) then "IPv6PrivacyExtensions=prefer"
        elif ($o | contains(["stable"])) then "IPv6PrivacyExtensions=no"
        else empty end
      ' "$CANDIDATE"

      jq -r --arg i "$iface" '.interfaces[$i].resolver.dns[]? | "DNS=" + .' "$CANDIDATE"
      jq -r --arg i "$iface" '.interfaces[$i].resolver.search_domains[]? | "Domains=" + .' "$CANDIDATE"

      # VLAN sub-interfaces bound to this parent
      jq -r --arg parent "$iface" '
        .interfaces | to_entries[]
        | select(.value.kind == "vlan" and .value.parent == $parent and .value.managed == true)
        | "VLAN=" + .key
      ' "$CANDIDATE"

      jq -r --arg i "$iface" '
        (.interfaces[$i].ipv4.gateways[]?, .interfaces[$i].ipv6.gateways[]?)
        | select(.metric == null)
        | "Gateway=" + .address
      ' "$CANDIDATE"

      jq -r --arg i "$iface" '
        .interfaces[$i].ipv4.gateways[]?
        | select(.metric != null)
        | "\n[Route]\nDestination=0.0.0.0/0\nGateway=" + .address + "\nMetric=" + (.metric|tostring)
      ' "$CANDIDATE"

      jq -r --arg i "$iface" '
        .interfaces[$i].ipv6.gateways[]?
        | select(.metric != null)
        | "\n[Route]\nDestination=::/0\nGateway=" + .address + "\nMetric=" + (.metric|tostring)
      ' "$CANDIDATE"

      jq -r --arg i "$iface" '
        (.interfaces[$i].ipv4.routes[]?, .interfaces[$i].ipv6.routes[]?)
        | "\n[Route]\nDestination=" + .destination
          + "\nGateway=" + .gateway.address
          + if .gateway.metric != null then "\nMetric=" + (.gateway.metric|tostring) else "" end
      ' "$CANDIDATE"

      jq -r --arg i "$iface" '
        (.interfaces[$i].ipv4.addresses[]?, .interfaces[$i].ipv6.addresses[]?) | "\n[Address]\nAddress=" + .address
      ' "$CANDIDATE"
    } > "$f"
  done

  jq -r '.interfaces | to_entries[] | select(.value.managed == false) | .key' "$CANDIDATE" | while read -r iface; do
    {
      echo "[Match]"
      echo "Name=$iface"
      echo
      echo "[Link]"
      echo "Unmanaged=yes"
    } > "$NETWORKD/10-ip-mgr-$iface.network"
  done

  # Inject [PPPoE] sections into parent .network files + write secrets
  jq -r '
    .interfaces | to_entries[]
    | select(.value.kind == "pppoe" and .value.managed == true)
    | .key
  ' "$CANDIDATE" | while read -r pppoe_iface; do
    local parent identity service encrypted secrets_file parent_net
    parent="$(jq -r --arg i "$pppoe_iface" '.interfaces[$i].parent' "$CANDIDATE")"
    identity="$(jq -r --arg i "$pppoe_iface" '.interfaces[$i].pppoe.identity // empty' "$CANDIDATE")"
    service="$(jq -r --arg i "$pppoe_iface" '.interfaces[$i].pppoe.service // empty' "$CANDIDATE")"
    encrypted="$(jq -r --arg i "$pppoe_iface" '.interfaces[$i].pppoe.password.encrypted // empty' "$CANDIDATE")"
    secrets_file="$PPPOE_SECRETS_DIR/pppoe-${pppoe_iface}.secret"
    parent_net="$NETWORKD/10-ip-mgr-${parent}.network"

    if [[ -n "$encrypted" ]]; then
      mkdir -p "$PPPOE_SECRETS_DIR"
      chmod 0700 "$PPPOE_SECRETS_DIR"
      local decrypted
      decrypted="$(printf '%s' "$encrypted" | base64 -d \
        | systemd-creds decrypt --name="ip-mgr-pppoe-${pppoe_iface}" - -)" \
        || die "failed to decrypt PPPoE password for $pppoe_iface; re-set with --pass:"
      printf '%s' "$decrypted" > "$secrets_file"
      chmod 0600 "$secrets_file"
    fi

    [[ -f "$parent_net" ]] || die "PPPoE parent .network file not found: $parent_net"
    {
      echo
      echo "[PPPoE]"
      [[ -n "$service" ]]   && echo "Service=$service"
      [[ -n "$identity" ]]  && echo "User=$identity"
      [[ -n "$encrypted" ]] && echo "PasswordFile=$secrets_file"
    } >> "$parent_net"
  done
}

# ===== cleaner =====

report_state(){
  local file="$1"
  jq -r '
    .interfaces | to_entries[] |
    .key as $iface | .value as $v |
    (
      "  " + $iface + "  (" + $v.transport + "/" + $v.kind +
      (if $v.managed then ", managed" else ", observed-only" end) +
      ", mtu=" + ($v.mtu | if . then tostring else "?" end) + ")"
    ),
    (
      ($v.ipv4.addresses[]?.address | "    " + . + "  [static ] -> ipv4.addresses"),
      ($v.ipv6.addresses[]?.address | "    " + . + "  [static ] -> ipv6.addresses"),
      ($v.observed.link_local[]?    | "    " + . + "  [lla    ] -> observed.link_local"),
      ($v.observed.addresses[]?     | "    " + . + "  [observe] -> observed.addresses"),
      ($v.observed.dynamic.dhcp4[]? | "    " + . + "  [dhcp4  ] -> ipv4.dhcp=true"),
      ($v.observed.dynamic.ra[]?    | "    " + . + "  [ra     ] -> ipv6.accept_ra=true"),
      ($v.ipv4.gateways[]?          | "    " + .address + "  [gw-ipv4] -> ipv4.gateways metric " + (.metric | if . then tostring else "none" end)),
      ($v.ipv6.gateways[]?          | "    " + .address + "  [gw-ipv6] -> ipv6.gateways metric " + (.metric | if . then tostring else "none" end)),
      ($v.observed.gateways[]?      | "    " + . + "  [gw-ipv6] -> RA-managed; recorded in observed.gateways")
    ),
    (
      if (
        $v.managed and ($v.enabled | not) and
        (($v.ipv4.addresses | length) == 0) and ($v.ipv4.dhcp | not) and
        (($v.ipv6.addresses | length) == 0) and ($v.ipv6.accept_ra | not) and
        (($v.observed.addresses | length) == 0) and (($v.observed.dynamic.dhcp4 | length) == 0)
      ) then
        "  NOTE: " + $iface + ": no addresses and operstate down; candidate will manage it as disabled."
      else empty end
    ),
    ""
  ' "$file"
}

transform_state(){
  local file="$1" ignore_dynamic="${2:-no}" convert_static="${3:-no}"
  local tmp
  tmp="$(state_tmp_path)"

  if [[ "$ignore_dynamic" == "yes" ]]; then
    jq -r '
      .interfaces | to_entries[] | select(.value.managed) | .value |
      ((.observed.dynamic.dhcp4[]?, .observed.dynamic.ra[]?) | "    " + . + "  [dynamic] -> ignored (--no-dhcp)")
    ' "$file"
    jq '
      .interfaces |= map_values(
        if .managed then
          .ipv4.dhcp = false |
          .ipv6.accept_ra = false |
          .ipv6.dhcp = false |
          .observed.dynamic.dhcp4 = [] |
          .observed.dynamic.ra = []
        else . end
      )
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi

  if [[ "$convert_static" == "yes" ]]; then
    jq -r '
      .interfaces | to_entries[] | select(.value.managed) | .value |
      ((.ipv4.addresses[]?.address) | "    " + . + "  [static ] -> ipv4.dhcp=true (--to-dhcp)"),
      ((.ipv6.addresses[]?.address) | "    " + . + "  [static ] -> ipv6.accept_ra=true / ipv6.dhcp=true (--to-dhcp)")
    ' "$file"
    jq '
      .interfaces |= map_values(
        if .managed then
          if (.ipv4.addresses | length) > 0 then
            .ipv4.dhcp = true | .ipv4.addresses = []
          else . end |
          if (.ipv6.addresses | length) > 0 then
            .ipv6.dhcp = true | .ipv6.accept_ra = true |
            .ipv6.addresses = []
          else . end
        else . end
      )
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi
}

adopt_actual_to_candidate(){
  echo
  if [[ "${CLEAN_NO_CANDIDATE:-no}" == "yes" ]]; then
    echo "Analyzing adoptable network state:"
  else
    echo "Adopting live network state:"
  fi
  echo

  actual_json > "$CANDIDATE"
  report_state "$CANDIDATE"
  transform_state "$CANDIDATE" "${CLEAN_IGNORE_DYNAMIC:-no}" "${CLEAN_CONVERT_STATIC:-no}"
  adopt_dns_to_candidate
}

adopt_dns_to_candidate(){
  local adopted="no"
  local tmp
  tmp="$(candidate_tmp_path)"

  echo "Adopting resolver state:"

  if command -v resolvectl >/dev/null 2>&1; then
    while read -r iface dns; do
      [[ -z "$iface" || -z "$dns" ]] && continue
      iface_exists "$iface" || continue

      jq --arg i "$iface" --arg d "$dns" '
        .interfaces[$i].resolver.dns |= (. + [$d] | unique)
      ' "$CANDIDATE" > "$tmp"
      mv "$tmp" "$CANDIDATE"
      printf "  %-42s -> interfaces.%s.resolver.dns\n" "$dns" "$iface"
      adopted="yes"
    done < <(
      resolvectl dns 2>/dev/null |
        awk '{ iface=$1; sub(":", "", iface); for(i=2;i<=NF;i++) print iface, $i }'
    )
  fi

  if [[ "$adopted" == "no" ]]; then
    while read -r dns; do
      jq --arg d "$dns" '.resolver.dns |= (. + [$d] | unique)' \
        "$CANDIDATE" > "$tmp"
      mv "$tmp" "$CANDIDATE"
      printf "  %-42s -> resolver.dns\n" "$dns"
      adopted="yes"
    done < <(awk '/^nameserver / {print $2}' "$RESOLV_CONF" 2>/dev/null)
  fi

  if [[ "$adopted" == "no" ]]; then
    echo "  none detected"
  fi
}

analyze_default_gateways(){
  local family="$1" fk="$2" label="$3"
  local rows count missing_metric

  rows="$(jq -r --arg fk "$fk" '
    .interfaces
    | to_entries[]
    | .key as $iface
    | .value[$fk].gateways[]?
    | [$iface, .address, (.metric // "none")] | @tsv
  ' "$CANDIDATE")"

  count="$(printf '%s\n' "$rows" | awk 'NF {count++} END {print count+0}')"
  [[ "$count" -gt 1 ]] || return 0

  missing_metric="$(printf '%s\n' "$rows" | awk '$3=="none" {missing=1} END {print missing+0}')"
  if [[ "$missing_metric" -eq 1 ]]; then
    echo "HIGH: Multiple $label default gateways detected without complete explicit metrics."
  else
    echo "NOTE: Multiple $label default gateways detected, but explicit metrics are present."
  fi

  printf '%s\n' "$rows" | awk 'NF {
    printf "  %s -> %s metric %s\n", $1, $2, $3
  }'

  if [[ "$missing_metric" -eq 1 ]]; then
    echo "  Candidate preserved all gateways; commit may produce ambiguous routing."
  fi
}

analyze_mixed_addressing(){
  jq -r '
    .interfaces
    | to_entries[]
    | .key as $iface
    | select(.value.ipv4.dhcp == true and ((.value.ipv4.addresses // []) | length) > 0)
    | "WARNING: " + $iface + " has IPv4 DHCP enabled and static IPv4 addresses."
  ' "$CANDIDATE"

  jq -r '
    .interfaces
    | to_entries[]
    | .key as $iface
    | select(.value.ipv6.accept_ra == true and ((.value.ipv6.addresses // []) | length) > 0)
    | "WARNING: " + $iface + " has IPv6 RA enabled and static IPv6 addresses."
  ' "$CANDIDATE"
}

analyze_resolver_hazards(){
  local mixed_dns

  mixed_dns="$(jq -r '
    ([.resolver.dns[]?] | any(. == "127.0.0.1" or . == "::1")) as $has_loopback
    | ([.resolver.dns[]?] | any(. != "127.0.0.1" and . != "::1")) as $has_external
    | ($has_loopback and $has_external)
  ' "$CANDIDATE")"

  if [[ "$mixed_dns" == "true" ]]; then
    echo "WARNING: Global DNS mixes loopback resolvers with external DNS."
    jq -r '.resolver.dns[]? | "  resolver.dns -> " + .' "$CANDIDATE"
  fi

  # DNS configured but systemd-resolved not active — rendered config is silently ignored
  local has_dns
  has_dns="$(jq -r '
    ((.resolver.dns | length) > 0) or
    ([.interfaces[].resolver.dns | length] | any(. > 0))
  ' "$CANDIDATE")"

  if [[ "$has_dns" == "true" ]] && ! service_active systemd-resolved; then
    echo "WARNING: DNS servers are configured but systemd-resolved is not active."
    echo "  Rendered /etc/systemd/resolved.conf.d/ip-mgr.conf will have no effect."
    echo "  Enable with: systemctl enable --now systemd-resolved"
  fi
}


analyze_lla_gateway_hazards(){
  jq -r '
    .interfaces
    | to_entries[]
    | .key as $iface
    | select(
        ((.value.observed.gateways // []) | length) > 0
        and (.value.ipv6.accept_ra == false)
        and ((.value.ipv6.addresses // []) | length) > 0
      )
    | "NOTE: " + $iface + ": static IPv6 addresses present with LLA gateway but accept_ra=false; IPv6 default routing may be absent after commit."
  ' "$CANDIDATE"
}


analyze_candidate_hazards(){
  echo
  echo "Analyzing adopted candidate:"

  local output
  output="$(
    analyze_default_gateways 4 ipv4 IPv4
    analyze_default_gateways 6 ipv6 IPv6
    analyze_mixed_addressing
    analyze_resolver_hazards
    analyze_lla_gateway_hazards
  )"

  if [[ -z "$output" ]]; then
    echo "  no immediate hazards detected"
  else
    printf '%s\n' "$output"
  fi
}

service_active(){
  systemctl is-active "$1.service" >/dev/null 2>&1
}

_unit_installed(){
  local ls
  ls="$(systemctl show "${1}.service" --property=LoadState --value 2>/dev/null || true)"
  [[ "$ls" == "loaded" ]]
}

running_over_ssh(){
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]
}

clean_control_planes_active(){
  service_active systemd-networkd || return 1

  local svc
  for svc in NetworkManager networking dhcpcd connman; do
    if service_active "$svc"; then
      return 1
    fi
  done

  return 0
}

candidate_matches_expected(){
  [[ -f "$EXPECTED" ]] || return 1
  diff -q <(jq -S . "$EXPECTED") <(jq -S . "$CANDIDATE") >/dev/null 2>&1
}

report_clean_state_outcome(){
  if candidate_matches_expected; then
    echo
    echo "This host already matches ip-mgr expected state."
    echo "No candidate changes needed."
    return 0
  fi

  if clean_control_planes_active; then
    echo
    echo "This host appears already normalized to systemd-networkd."
    if service_active systemd-resolved; then
      echo "systemd-resolved is active."
    else
      echo "systemd-resolved is not active; resolver state was still captured where available."
    fi
    echo "Candidate state was generated for review, but no live networking changes are needed."
    return 0
  fi

  return 1
}

disable_competing_stacks(){
  echo "Disabling competing network managers..."

  for svc in NetworkManager networking dhcpcd connman; do
    if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
      systemctl disable --now "$svc.service" 2>/dev/null || true
    fi
  done

  systemctl enable --now systemd-networkd
}

validate_adopted_candidate(){
  echo
  echo "Validating adopted candidate..."
  cmd_validate
}

validate_clean_apply(){
  local blockers

  blockers="$(
    analyze_default_gateways 4 ipv4 IPv4
    analyze_default_gateways 6 ipv6 IPv6
  )" || true

  if printf '%s\n' "$blockers" | grep -q '^HIGH:'; then
    echo "ERROR: clean --apply blocked by high-severity hazards:" >&2
    printf '%s\n' "$blockers" | awk '/^HIGH:/ || /^  / {print}' >&2
    echo "Review with clean without --apply, or adjust the candidate before committing." >&2
    return 1
  fi

  validate_renderer_capabilities
}

show_clean_apply_summary(){
  echo
  echo "Clean apply summary:"
  echo "  Candidate will be rendered to: $NETWORKD/10-ip-mgr-*.network"
  echo "  systemd-networkd will be enabled/restarted"
  if [[ "$1" == "yes" ]]; then
    echo "  Competing control-plane services will be disabled after successful commit"
  else
    echo "  Competing control-plane services will be left running (--no-disable)"
  fi
  if running_over_ssh; then
    echo "  WARNING: SSH session detected; a bad network apply may disconnect this session."
  fi
}

require_clean_apply_confirm(){
  local confirmed="$1"
  local answer

  [[ "$confirmed" == "yes" ]] && return

  if [[ ! -t 0 ]]; then
    echo "ERROR: clean --apply requires --confirm or -y/--yes when running non-interactively." >&2
    echo "Run clean without --apply to review, or rerun with --apply --confirm when ready." >&2
    return 1
  fi

  printf "Confirm application of this network candidate? Type 'yes' to continue: " >&2
  IFS= read -r answer
  case "$answer" in
    yes|YES|y|Y) return 0 ;;
    *)
      echo "Apply cancelled." >&2
      return 1
      ;;
  esac
}

show_clean_review_steps(){
  echo
  echo "Candidate generated and validated from actual state."
  echo "Review changes with:"
  echo "  $0 show candidate"
  echo "  $0 compare expected candidate"
  echo
}

show_clean_next_steps(){
  echo
  echo "No running network configuration changed."
  echo "Next commands:"
  echo "  $0 show candidate"
  echo "  $0 compare expected candidate"
  echo "  $0 commit"
}

# ===== audit =====

_audit_ok()    { printf "  [ ok  ] %s\n" "$*"; }
_audit_warn()  { printf "  [warn ] %s\n" "$*"; }
_audit_issue() { printf "  [issue] %s\n" "$*"; }

cmd_audit_file(){
  local file="$1"
  [[ -f "$file" ]] || die "audit: file not found: $file"

  echo
  echo "=== ip-mgr File Audit: $file ==="
  echo

  # JSON validity
  if ! jq empty "$file" 2>/dev/null; then
    echo "  [FAIL ] not valid JSON — cannot continue"
    return 1
  fi
  _audit_ok "valid JSON"

  # schema_version
  local sv
  sv="$(jq -r '.schema_version // empty' "$file")"
  if [[ -z "$sv" ]];   then _audit_warn "schema_version missing"
  elif [[ "$sv" != "1" ]]; then _audit_warn "schema_version $sv (expected 1)"
  else _audit_ok "schema_version: $sv"; fi

  # Required root fields
  local missing
  missing="$(jq -r '
    (if .managed_by  == null then "managed_by"  else empty end),
    (if .host        == null then "host"        else empty end),
    (if .resolver    == null then "resolver"    else empty end),
    (if .interfaces  == null then "interfaces"  else empty end)
  ' "$file")"
  if [[ -n "$missing" ]]; then
    while IFS= read -r f; do _audit_issue "missing required field: $f"; done <<< "$missing"
  else
    _audit_ok "required root fields present"
  fi

  # Interface enum validation
  local enum_errors
  enum_errors="$(jq -r '
    .interfaces | to_entries[] | .key as $i | .value |
    if (.transport | IN("ethernet","tunnel") | not) then
      $i + ": unknown transport \"" + .transport + "\""
    elif (.kind | IN("ethernet","vlan","wifi","pppoe","wireguard","tun","tap","gre","nhrp","ike") | not) then
      $i + ": unknown kind \"" + .kind + "\""
    else empty end
  ' "$file" 2>/dev/null)"
  if [[ -n "$enum_errors" ]]; then
    while IFS= read -r e; do _audit_issue "$e"; done <<< "$enum_errors"
  else
    _audit_ok "interface types valid"
  fi

  # VLAN interface key consistency (Linux names VLANs as parent.vlan_id)
  local vlan_issues
  vlan_issues="$(jq -r '
    .interfaces | to_entries[] |
    select(.value.kind == "vlan" and .value.parent != null and .value.vlan_id != null) |
    select(.key != (.value.parent + "." + (.value.vlan_id | tostring))) |
    "VLAN \"" + .key + "\" should be keyed as \"" + .value.parent + "." + (.value.vlan_id | tostring) + "\""
  ' "$file" 2>/dev/null)"
  if [[ -n "$vlan_issues" ]]; then
    while IFS= read -r e; do _audit_issue "$e"; done <<< "$vlan_issues"
  else
    local _n_vlans
    _n_vlans="$(jq '[.interfaces[] | select(.kind == "vlan")] | length' "$file" 2>/dev/null || echo 0)"
    [[ "$_n_vlans" -gt 0 ]] && _audit_ok "VLAN interface keys consistent (${_n_vlans} VLAN(s))"
  fi

  # Hazard analysis
  echo
  echo "Hazard analysis:"
  local CANDIDATE="$file"
  local hazards
  hazards="$(
    analyze_default_gateways 4 ipv4 IPv4
    analyze_default_gateways 6 ipv6 IPv6
    analyze_mixed_addressing
    analyze_resolver_hazards
    analyze_lla_gateway_hazards
  )"
  if [[ -z "$hazards" ]]; then
    echo "  no hazards detected"
  else
    printf '%s\n' "$hazards"
  fi

  # Renderer compatibility
  echo
  echo "Renderer compatibility:"
  local rc_blockers
  rc_blockers="$(jq -r '
    .interfaces | to_entries[] | .key as $iface | .value.ipv6.gateways[]?
    | select((.scope // "global") == "link" or (.on_link // false) == true)
    | "  " + $iface + ": scoped/on-link IPv6 gateway " + .address + " cannot be rendered"
  ' "$file")"
  if [[ -n "$rc_blockers" ]]; then
    while IFS= read -r line; do _audit_issue "$line"; done <<< "$rc_blockers"
  else
    _audit_ok "no renderer blockers"
  fi

  echo
  echo "File audit complete."
}
_audit_issue() { printf "  [issue] %s\n" "$*"; }

# Packages that --purge:NAME may never target.
_PROTECTED_PURGE_PKGS=(systemd udev libudev1 libsystemd0 dbus init)

# Packages purged by --purge:all (every competing control plane).
_ALL_COMPETING_PKGS=(network-manager ifupdown dhcpcd5 connman netplan.io)

_svc_pkg(){
  case "$1" in
    NetworkManager) echo "network-manager" ;;
    networking)     echo "ifupdown" ;;
    dhcpcd)         echo "dhcpcd5" ;;
    connman)        echo "connman" ;;
    *)              echo "$1" ;;
  esac
}

_purge_validate_pkg(){
  local pkg="$1" p
  for p in "${_PROTECTED_PURGE_PKGS[@]}"; do
    [[ "$pkg" == "$p"* ]] && die "refusing to purge protected package: $pkg"
  done
}

_audit_control_plane_health(){
  # Appends to _AUDIT_FIXES[] and _AUDIT_PURGE[] in caller's dynamic scope.
  echo "Control plane health:"
  echo

  # is-enabled/is-active return non-zero for disabled/inactive services but
  # still print a value; || echo "..." would append a second line. Use || true
  # and treat empty output as "not-found" (systemctl itself unavailable).
  local nd_enabled nd_active
  nd_enabled="$(systemctl is-enabled systemd-networkd.service 2>/dev/null || true)"
  nd_active="$(systemctl is-active  systemd-networkd.service 2>/dev/null || true)"
  [[ -z "$nd_enabled" ]] && nd_enabled="not-found"
  [[ -z "$nd_active"  ]] && nd_active="not-found"
  if [[ "$nd_active" == "active" ]]; then
    _audit_ok "systemd-networkd: ${nd_enabled} / ${nd_active}"
  else
    _audit_issue "systemd-networkd: enabled=${nd_enabled} active=${nd_active}"
    _AUDIT_FIXES+=("enable-networkd")
  fi

  local svc
  for svc in NetworkManager networking dhcpcd connman; do
    local load_state
    load_state="$(systemctl show "${svc}.service" --property=LoadState --value 2>/dev/null || echo "not-found")"
    [[ "$load_state" == "loaded" ]] || continue

    local svc_e svc_a
    svc_e="$(systemctl is-enabled "${svc}.service" 2>/dev/null || true)"
    svc_a="$(systemctl is-active  "${svc}.service" 2>/dev/null || true)"

    if [[ "$svc_a" == "active" || "$svc_e" == "enabled" ]]; then
      _audit_issue "${svc}: enabled=${svc_e} active=${svc_a}"
      _AUDIT_FIXES+=("disable:${svc}")
      _AUDIT_PURGE+=("$(_svc_pkg "$svc")")
    else
      _audit_ok "${svc}: installed, not active/enabled"
    fi
  done
  echo
}

_audit_expected_state(){
  # Appends to _AUDIT_FIXES[] in caller's dynamic scope.
  echo "ip-mgr state:"
  echo

  if [[ ! -f "$EXPECTED" ]]; then
    _audit_issue "no expected.json — ip-mgr has never committed a configuration"
    _audit_issue "run 'ip-mgr clean --apply' to generate an initial configuration"
    echo
    return
  fi

  local last="(unknown)"
  [[ -f "$LAST_COMMIT" ]] && last="$(cat "$LAST_COMMIT")"
  _audit_ok "expected.json present (last commit: ${last})"

  local n_net=0
  [[ -d "$NETWORKD" ]] && n_net="$(find "$NETWORKD" -maxdepth 1 -name '10-ip-mgr-*.network' 2>/dev/null | wc -l)"
  if [[ "$n_net" -gt 0 ]]; then
    _audit_ok "${n_net} rendered .network file(s) present in $NETWORKD"
  else
    _audit_issue "no rendered .network files found in $NETWORKD"
    _AUDIT_FIXES+=("rerender")
  fi
  echo
}

_audit_state_drift(){
  # Appends to _AUDIT_FIXES[] in caller's dynamic scope.
  [[ -f "$EXPECTED" ]] || return 0

  echo "State drift (expected vs live):"
  echo

  local any_issues="no"

  while read -r iface; do
    [[ -z "$iface" ]] && continue

    if ! iface_exists "$iface"; then
      _audit_issue "${iface}: not present on system (expected: managed+enabled)"
      _AUDIT_FIXES+=("recommit")
      any_issues="yes"
      continue
    fi

    if command -v networkctl &>/dev/null && service_active systemd-networkd; then
      local setup
      setup="$(networkctl list --no-legend 2>/dev/null | awk -v i="$iface" '$2==i {print $4}')"
      case "${setup:-unknown}" in
        configured|routable|carrier|degraded)
          _audit_ok "${iface}: networkd ${setup}" ;;
        unmanaged)
          _audit_issue "${iface}: networkd reports unmanaged"
          _AUDIT_FIXES+=("recommit")
          any_issues="yes"
          ;;
        *)
          _audit_warn "${iface}: networkd setup=${setup:-unknown}" ;;
      esac
    fi

    local addrs
    addrs="$(jq -r --arg i "$iface" '
      [
        (.interfaces[$i].ipv4.addresses // [])[]?.address,
        (.interfaces[$i].ipv6.addresses // [])[]?.address
      ] | .[]
    ' "$EXPECTED" 2>/dev/null || true)"

    while read -r addr; do
      [[ -z "$addr" ]] && continue
      if ip addr show dev "$iface" 2>/dev/null | grep -qF "$addr"; then
        _audit_ok "${iface}: ${addr} present"
      else
        _audit_issue "${iface}: ${addr} expected but not present on live interface"
        _AUDIT_FIXES+=("recommit")
        any_issues="yes"
      fi
    done <<< "$addrs"

    local gw4 gw6
    gw4="$(jq -r --arg i "$iface" '(.interfaces[$i].ipv4.gateways // [])[]?.address // empty' "$EXPECTED" 2>/dev/null || true)"
    gw6="$(jq -r --arg i "$iface" '(.interfaces[$i].ipv6.gateways // [])[]?.address // empty' "$EXPECTED" 2>/dev/null || true)"

    while read -r gw; do
      [[ -z "$gw" ]] && continue
      if ip route show default via "$gw" dev "$iface" &>/dev/null; then
        _audit_ok "${iface}: gateway ${gw} present"
      else
        _audit_warn "${iface}: gateway ${gw} not in live routing table"
      fi
    done <<< "$gw4"

    while read -r gw; do
      [[ -z "$gw" ]] && continue
      if ip -6 route show default via "$gw" dev "$iface" &>/dev/null; then
        _audit_ok "${iface}: gateway ${gw} present (IPv6)"
      else
        _audit_warn "${iface}: gateway ${gw} not in live routing table (IPv6)"
      fi
    done <<< "$gw6"

  done < <(jq -r '
    .interfaces | to_entries[]
    | select(.value.managed and .value.enabled)
    | .key
  ' "$EXPECTED")

  [[ "$any_issues" == "no" ]] && _audit_ok "live state matches expected configuration"
  echo
}

_audit_apply_fixes(){
  # $1 = purge_mode ("no"|"active"|"all"|"named")
  # $2 = confirmed ("yes"|"no")
  # $3+ = named packages (only when purge_mode="named")
  local purge_mode="$1" confirmed="$2"
  shift 2
  local named_pkgs=("$@")

  local unique_fixes=()
  mapfile -t unique_fixes < <(printf '%s\n' "${_AUDIT_FIXES[@]}" | sort -u)

  local have_work="no"
  [[ ${#unique_fixes[@]} -gt 0 ]] && have_work="yes"
  case "$purge_mode" in
    active) [[ ${#_AUDIT_PURGE[@]} -gt 0 ]] && have_work="yes" ;;
    all|named) have_work="yes" ;;
  esac
  [[ "$have_work" == "no" ]] && return 0

  echo
  echo "=== Applying Fixes ==="
  echo

  local fix
  for fix in "${unique_fixes[@]}"; do
    case "$fix" in
      enable-networkd)
        echo "  Enabling and starting systemd-networkd..."
        systemctl enable --now systemd-networkd
        ;;
      disable:*)
        local svc="${fix#disable:}"
        echo "  Disabling ${svc}..."
        systemctl disable --now "${svc}.service" 2>/dev/null || true
        ;;
      fix-vlan-keys)
        echo "  Renaming miskeyed VLAN interfaces in candidate.json..."
        local _fixed
        _fixed="$(jq 'reduce (
          .interfaces | to_entries[] |
          select(.value.kind == "vlan" and .value.parent != null and .value.vlan_id != null) |
          select(.key != (.value.parent + "." + (.value.vlan_id | tostring)))
        ) as $e (
          .;
          .interfaces[($e.value.parent + "." + ($e.value.vlan_id | tostring))] = $e.value |
          del(.interfaces[$e.key])
        )' "$CANDIDATE")"
        jwrite "$CANDIDATE" <<< "$_fixed"
        echo "  Done. Run 'ip-mgr validate && ip-mgr commit' to apply."
        ;;
      recommit|rerender)
        : ;;  # handled together below
    esac
  done

  if printf '%s\n' "${unique_fixes[@]}" | grep -qE '^(recommit|rerender)$'; then
    if has_pending; then
      _audit_warn "there are uncommitted staged changes that will be discarded by this restore"
    fi
    echo "  Restoring expected network state from expected.json..."

    local _do_restore="no"
    if [[ "$confirmed" == "yes" ]]; then
      _do_restore="yes"
    else
      printf "  Re-render and restart systemd-networkd from expected.json? Type 'yes' to continue: " >&2
      local _ans
      IFS= read -r _ans
      case "$_ans" in yes|YES|y|Y) _do_restore="yes" ;; esac
    fi

    if [[ "$_do_restore" == "yes" ]]; then
      cp "$EXPECTED" "$CANDIDATE"
      cmd_commit
    else
      echo "  State restore skipped."
    fi
  fi

  if [[ "$purge_mode" != "no" ]]; then
    local pkg_list=()
    case "$purge_mode" in
      active)
        if [[ ${#_AUDIT_PURGE[@]} -gt 0 ]]; then
          mapfile -t pkg_list < <(printf '%s\n' "${_AUDIT_PURGE[@]}" | sort -u)
        fi
        ;;
      all)
        pkg_list=("${_ALL_COMPETING_PKGS[@]}")
        ;;
      named)
        local p
        for p in "${named_pkgs[@]}"; do
          _purge_validate_pkg "$p"
          pkg_list+=("$p")
        done
        ;;
    esac

    if [[ ${#pkg_list[@]} -eq 0 ]]; then
      echo "  Nothing to purge."
    else
      echo
      echo "  Packages to purge: ${pkg_list[*]}"

      local _do_purge="no"
      if [[ "$confirmed" == "yes" ]]; then
        _do_purge="yes"
      else
        printf "  Permanently remove these packages with apt purge? This cannot be undone. Type 'purge' to continue: " >&2
        local _pans
        IFS= read -r _pans
        case "$_pans" in Purge|purge|PURGE) _do_purge="yes" ;; esac
      fi

      if [[ "$_do_purge" == "yes" ]]; then
        apt-get purge -y "${pkg_list[@]}"
        apt-get autoremove -y
      else
        echo "  Purge skipped."
      fi
    fi
  fi

  echo
  echo "Fixes applied."
}

_audit_schema_consistency(){
  # Appends to _AUDIT_FIXES[] in caller's dynamic scope.
  [[ -f "$CANDIDATE" ]] || return 0

  echo "Schema consistency:"
  echo

  local vlan_issues
  vlan_issues="$(jq -r '
    .interfaces | to_entries[] |
    select(.value.kind == "vlan" and .value.parent != null and .value.vlan_id != null) |
    select(.key != (.value.parent + "." + (.value.vlan_id | tostring))) |
    "VLAN \"" + .key + "\" should be keyed as \"" + .value.parent + "." + (.value.vlan_id | tostring) + "\""
  ' "$CANDIDATE" 2>/dev/null)"

  if [[ -n "$vlan_issues" ]]; then
    while IFS= read -r e; do _audit_issue "$e"; done <<< "$vlan_issues"
    _AUDIT_FIXES+=("fix-vlan-keys")
  else
    local _n_vlans
    _n_vlans="$(jq '[.interfaces[] | select(.kind == "vlan")] | length' "$CANDIDATE" 2>/dev/null || echo 0)"
    [[ "$_n_vlans" -gt 0 ]] && _audit_ok "VLAN interface keys consistent"
  fi
  echo
}

investigate_system(){
  # Common opening investigation shared by 'audit' and 'clean'.
  # Populates _AUDIT_FIXES[] and _AUDIT_PURGE[] in caller's dynamic scope.
  cmd_detect
  _audit_schema_consistency
  _audit_expected_state
  _audit_control_plane_health
}

cmd_audit(){
  local fix="no"
  local purge_mode="no"   # "no" | "active" | "all" | "named"
  local purge_named=()
  local confirmed="${GLOBAL_CONFIRM:-no}"
  local audit_file=""

  for arg in "$@"; do
    case "$arg" in
      --file:*|-f:*) audit_file="${arg#*:}" ;;
      --fix)        fix="yes" ;;
      --purge)      purge_mode="active" ;;
      --purge:all)  purge_mode="all" ;;
      --purge:*)
        purge_mode="named"
        IFS=',' read -ra purge_named <<< "${arg#--purge:}"
        ;;
      --confirm)    confirmed="yes" ;;
      *) die "unknown audit option '$arg'" ;;
    esac
  done

  if [[ -n "$audit_file" ]]; then
    cmd_audit_file "$audit_file"
    return
  fi

  [[ "$purge_mode" != "no" && "$fix" != "yes" ]] && die "--purge requires --fix"

  local _AUDIT_FIXES=()
  local _AUDIT_PURGE=()

  echo
  echo "=== ip-mgr Audit ==="
  echo

  investigate_system
  _audit_state_drift

  if [[ ${#_AUDIT_FIXES[@]} -eq 0 ]]; then
    echo "Audit complete: no issues found."
    return 0
  fi

  local unique_issue_count
  unique_issue_count="$(printf '%s\n' "${_AUDIT_FIXES[@]}" | sort -u | wc -l)"
  echo "Audit complete: ${unique_issue_count} issue(s) found."

  if [[ "$fix" != "yes" ]]; then
    echo
    echo "  To fix:   ip-mgr audit --fix"
    [[ ${#_AUDIT_PURGE[@]} -gt 0 ]] && echo "  To purge: ip-mgr audit --fix --purge"
    return 0
  fi

  if [[ "$purge_mode" != "no" ]]; then
    command -v apt-get >/dev/null 2>&1 || die "apt-get not found; --purge requires apt-get"
  fi

  _snapshot_create "pre-audit --fix" >/dev/null || true
  _audit_apply_fixes "$purge_mode" "$confirmed" "${purge_named[@]+"${purge_named[@]}"}"
}

cmd_clean(){
  local mode="safe"
  local adopt="yes"
  local apply="no"
  local disable_old="yes"
  local disable_old_explicit="no"
  local no_candidate="no"
  local ignore_dynamic="no"
  local convert_static="no"
  local confirmed="${GLOBAL_CONFIRM:-no}"
  local safe_window_arg=""   # passed through to cmd_commit

  for arg in "$@"; do
    case "$arg" in
      --safe) mode="safe" ;;
      --scorched-earth|--force) mode="scorched" ;;
      --adopt-live|--adopt-actual) adopt="yes" ;;
      --apply|--commit) apply="yes" ;;
      --disable-old)
        disable_old="yes"
        disable_old_explicit="yes"
        ;;
      --no-disable)       disable_old="no" ;;
      --no-candidate)     no_candidate="yes" ;;
      --no-dhcp)          ignore_dynamic="yes" ;;
      --to-dhcp)          convert_static="yes" ;;
      --confirm)          confirmed="yes" ;;
      --safe-window)      safe_window_arg="--safe-window" ;;
      --safe-window:*)    safe_window_arg="$arg" ;;
      --no-safe-window)   safe_window_arg="--no-safe-window" ;;
      *) die "unknown clean option '$arg'" ;;
    esac
  done

  if [[ "$no_candidate" == "yes" ]]; then
    if [[ "$apply" == "yes" ]]; then
      note "--no-candidate selected; ignoring --apply"
    fi
    if [[ "$disable_old_explicit" == "yes" ]]; then
      note "--no-candidate selected; ignoring --disable-old"
    fi
    if [[ "$mode" == "scorched" ]]; then
      note "--no-candidate selected; ignoring --scorched-earth"
    fi
    apply="no"
    disable_old="no"
    mode="safe"
  fi

  [[ "$mode" != "scorched" || "$apply" == "yes" ]] || die "--scorched-earth requires --apply"

  local _AUDIT_FIXES=()
  local _AUDIT_PURGE=()

  # Snapshot
  echo "Capturing pre-clean snapshot..."
  local snap
  snap="$(_snapshot_create "pre-clean")"
  echo "Snapshot saved: $snap"

  # Investigate
  investigate_system

  if [[ "$mode" == "scorched" ]]; then
    note "scorched-earth selected; old stacks may be disabled before verification"
  fi

  local real_candidate="$CANDIDATE"
  local clean_candidate_tmp=""
  if [[ "$no_candidate" == "yes" ]]; then
    clean_candidate_tmp="$(state_tmp_path)"
    local CANDIDATE="$clean_candidate_tmp"
  else
    local CANDIDATE="$real_candidate"
  fi
  # Mask any existing journal so state_file/cmd_compare use the clean CANDIDATE temp,
  # not a projection of the user's staged changes.
  local JOURNAL="" JOURNAL_MODE="no"
  local CLEAN_IGNORE_DYNAMIC="$ignore_dynamic"
  local CLEAN_CONVERT_STATIC="$convert_static"
  local CLEAN_NO_CANDIDATE="$no_candidate"

  # Acquire, report, and transform
  if [[ "$no_candidate" == "yes" ]]; then
    echo "Collecting network state..."
  else
    echo "Generating candidate configuration from actual state..."
  fi
  adopt_actual_to_candidate

  # Analyze
  analyze_candidate_hazards

  # Validate
  validate_adopted_candidate

  if [[ "$no_candidate" == "yes" ]]; then
    echo
    echo "No candidate file created (--no-candidate)."
    echo "No running network configuration changed."
    rm -f "$clean_candidate_tmp"
    return
  fi

  local already_clean="no"
  if report_clean_state_outcome; then
    already_clean="yes"
  fi

  if [[ "$already_clean" == "yes" && "$apply" == "yes" ]]; then
    note "already-clean state detected; ignoring --apply to avoid changing live networking"
    apply="no"
    disable_old="no"
  fi

  if candidate_matches_expected; then
    return
  fi

  # Compare
  show_clean_review_steps

  cmd_compare expected candidate

  # Write/apply
  if [[ "$apply" == "yes" ]]; then
    validate_clean_apply
    show_clean_apply_summary "$disable_old"
    require_clean_apply_confirm "$confirmed"

    if [[ "$disable_old" == "yes" || "$mode" == "scorched" ]]; then
      disable_competing_stacks
    fi

    echo
    echo "Committing adopted candidate..."
    cmd_commit ${safe_window_arg:+"$safe_window_arg"}
  else
    show_clean_next_steps
  fi
}

# ===== commit/snapshot/detect =====

_disarm_autorollback(){
  systemctl stop "${AUTOROLLBACK_UNIT}.timer" "${AUTOROLLBACK_UNIT}.service" 2>/dev/null || true
  rm -f "$SYSTEMD_SYSTEM/${AUTOROLLBACK_UNIT}.service" \
        "$SYSTEMD_SYSTEM/${AUTOROLLBACK_UNIT}.timer" \
        "$AUTOROLLBACK_DEADLINE"
  systemctl daemon-reload 2>/dev/null || true
}

schedule_autorollback(){
  local window="$1"
  local script_abs
  script_abs="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  # Write persistent unit files so the timer survives a reboot.
  # OnBootSec fires ~15s into the next boot if confirm was never run.
  cat > "$SYSTEMD_SYSTEM/${AUTOROLLBACK_UNIT}.service" <<EOF
[Unit]
Description=ip-mgr auto-rollback
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=bash ${script_abs} snapshot --rollback
EOF

  cat > "$SYSTEMD_SYSTEM/${AUTOROLLBACK_UNIT}.timer" <<EOF
[Unit]
Description=ip-mgr auto-rollback (${window}s safety window)

[Timer]
OnActiveSec=${window}s
OnBootSec=15s
AccuracySec=1s
EOF

  printf '%s\n' "$(( $(date +%s) + window ))" > "$AUTOROLLBACK_DEADLINE"

  systemctl daemon-reload
  systemctl stop "${AUTOROLLBACK_UNIT}.timer" "${AUTOROLLBACK_UNIT}.service" 2>/dev/null || true
  systemctl start "${AUTOROLLBACK_UNIT}.timer"

  echo
  echo "Auto-rollback armed: ${window}s (reboot-safe)."
  echo "Run 'ip-mgr confirm' to make this configuration permanent."
}

cmd_confirm(){
  # Detect pending rollback via unit files on disk (covers reboot case where
  # the timer hasn't fired yet but the unit files are present) or active units.
  local timer_pending="no"
  [[ -f "$SYSTEMD_SYSTEM/${AUTOROLLBACK_UNIT}.timer" ]]                   && timer_pending="yes"
  systemctl is-active --quiet "${AUTOROLLBACK_UNIT}.timer"   2>/dev/null  && timer_pending="yes" || true
  systemctl is-active --quiet "${AUTOROLLBACK_UNIT}.service" 2>/dev/null  && timer_pending="yes" || true

  if [[ "$timer_pending" == "no" ]]; then
    if [[ -f "$AUTOROLLBACK_DEADLINE" ]]; then
      local deadline remaining
      deadline="$(cat "$AUTOROLLBACK_DEADLINE")"
      remaining="$(( deadline - $(date +%s) ))"
      rm -f "$AUTOROLLBACK_DEADLINE"
      if [[ "$remaining" -le 0 ]]; then
        echo "Auto-rollback window already expired — rollback has run."
        return 1
      fi
    fi
    echo "No pending auto-rollback found."
    return 0
  fi

  local msg="Auto-rollback cancelled."
  if [[ -f "$AUTOROLLBACK_DEADLINE" ]]; then
    local deadline remaining
    deadline="$(cat "$AUTOROLLBACK_DEADLINE")"
    remaining="$(( deadline - $(date +%s) ))"
    [[ "$remaining" -gt 0 ]] && msg="Auto-rollback cancelled (${remaining}s was remaining)."
  fi

  _disarm_autorollback
  echo "$msg"
  echo "Configuration is now permanent."
}

render_resolved_conf(){
  local f="$RESOLVED_CONF_D/ip-mgr.conf"
  local dns search
  dns="$(jq -r '.resolver.dns[]? // empty' "$CANDIDATE")"
  search="$(jq -r '.resolver.search_domains[]? // empty' "$CANDIDATE")"
  if [[ -z "$dns" && -z "$search" ]]; then
    rm -f "$f"
    return 0
  fi
  mkdir -p "$RESOLVED_CONF_D"
  {
    echo "# Generated by ip-mgr — do not edit manually"
    echo "[Resolve]"
    [[ -n "$dns"    ]] && printf '%s\n' "$dns"    | sed 's/^/DNS=/'
    [[ -n "$search" ]] && printf '%s\n' "$search" | sed 's/^/Domains=/'
  } > "$f"
}

render_timesyncd_conf(){
  local f="$TIMESYNCD_CONF_D/ip-mgr.conf"
  local servers
  servers="$(jq -r '.ntp.servers[]? // empty' "$CANDIDATE")"
  if [[ -z "$servers" ]]; then
    rm -f "$f"
    return 0
  fi
  mkdir -p "$TIMESYNCD_CONF_D"
  {
    echo "# Generated by ip-mgr — do not edit manually"
    echo "[Time]"
    echo "NTP=$(printf '%s\n' "$servers" | tr '\n' ' ' | sed 's/ $//')"
  } > "$f"
}

cmd_commit(){
  local safe_window=""   # empty=auto-detect, "no"=disabled, N=explicit seconds

  for arg in "$@"; do
    case "$arg" in
      --safe-window)    safe_window="$DEFAULT_SAFE_WINDOW" ;;
      --safe-window:*)
        safe_window="${arg#--safe-window:}"
        [[ "$safe_window" =~ ^[0-9]+$ ]] || die "--safe-window value must be a number of seconds"
        [[ "$safe_window" -ge 10 ]]      || die "--safe-window value must be at least 10 seconds"
        ;;
      --no-safe-window) safe_window="no" ;;
      *) die "unknown commit option '$arg'" ;;
    esac
  done

  # Auto-arm when running over SSH unless explicitly disabled
  if [[ -z "$safe_window" ]] && running_over_ssh; then
    safe_window="$DEFAULT_SAFE_WINDOW"
  fi

  has_pending || die "nothing to commit (no staged changes)"

  # Project the staged state into a temp — this becomes the new expected.json.
  # For journal mutations, replay against current expected (no stale-data risk).
  # For wholesale candidates (cmd_clean), copy directly.
  local _commit_tmp
  if has_journal; then
    _commit_tmp="$(_project_candidate)" || die "commit: failed to project staged changes"
  else
    _commit_tmp="$(state_tmp_path)"
    cp "$CANDIDATE" "$_commit_tmp"
  fi
  # Shadow CANDIDATE so validate/render functions operate on the projected temp.
  # JOURNAL_MODE="no" prevents cmd_validate from re-projecting.
  local CANDIDATE="$_commit_tmp" JOURNAL_MODE="no"
  trap 'rm -f "$_commit_tmp"' RETURN

  cmd_validate
  validate_renderer_capabilities

  # Snapshot pre-commit state so 'snapshot --rollback' can restore it
  [[ -f "$EXPECTED" ]] && _snapshot_create "pre-commit" >/dev/null || true

  render_networkd
  render_resolved_conf
  render_timesyncd_conf
  install_boot_services
  cp "$_commit_tmp" "$EXPECTED"

  systemctl enable systemd-networkd
  _unit_installed systemd-resolved  && systemctl enable systemd-resolved.service  || true
  _unit_installed systemd-timesyncd && systemctl enable systemd-timesyncd.service || true

  if [[ "$safe_window" != "no" && -n "$safe_window" ]]; then
    echo
    echo "  SSH session detected — auto-rollback in ${safe_window}s if not confirmed."
    echo "  After reconnecting, run: ip-mgr confirm"
    echo
  fi

  systemctl restart systemd-networkd
  _unit_installed systemd-resolved  && systemctl restart systemd-resolved.service  || true
  _unit_installed systemd-timesyncd && systemctl restart systemd-timesyncd.service || true

  # Wire /etc/resolv.conf to systemd-resolved stub resolver — only if installed
  if _unit_installed systemd-resolved; then
    local _stub="/run/systemd/resolve/stub-resolv.conf"
    if [[ ! -L "$RESOLV_CONF" || "$(readlink "$RESOLV_CONF")" != "$_stub" ]]; then
      if [[ -f "$RESOLV_CONF" && ! -L "$RESOLV_CONF" ]]; then
        local _bak="${RESOLV_CONF}.ip-mgr-bak"
        [[ -f "$_bak" ]] || cp "$RESOLV_CONF" "$_bak"
        echo "  backed up /etc/resolv.conf to $_bak"
      elif [[ -L "$RESOLV_CONF" ]]; then
        echo "  replacing /etc/resolv.conf symlink (was -> $(readlink "$RESOLV_CONF"))"
      fi
      ln -sf "$_stub" "$RESOLV_CONF"
      echo "  /etc/resolv.conf -> $_stub"
    fi
  fi

  local rev
  rev="$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$rev" > "$LAST_COMMIT"
  echo "commit successful: $rev"

  # Discard staged changes — they are now reflected in expected.json
  rm -f "$JOURNAL" "$BASE/candidate.json"

  if [[ "$safe_window" != "no" && -n "$safe_window" ]]; then
    schedule_autorollback "$safe_window"
  fi
}

cmd_apply(){
  local src_file="" save_mode=false safe_window=""
  local confirmed="${GLOBAL_CONFIRM:-no}"

  for arg in "$@"; do
    case "$arg" in
      --save)           save_mode=true ;;
      --confirm|-y)     confirmed="yes" ;;
      --safe-window)    safe_window="$DEFAULT_SAFE_WINDOW" ;;
      --safe-window:*)
        safe_window="${arg#--safe-window:}"
        [[ "$safe_window" =~ ^[0-9]+$ ]] || die "apply: --safe-window value must be a positive integer (seconds)"
        [[ "$safe_window" -ge 10 ]]      || die "apply: --safe-window value must be at least 10 seconds"
        ;;
      --no-safe-window) safe_window="no" ;;
      -*)               die "apply: unknown option '$arg'" ;;
      *)
        [[ -z "$src_file" ]] || die "apply: unexpected argument '$arg'"
        src_file="$arg" ;;
    esac
  done

  [[ -n "$src_file" ]] || die "apply: source file required (ip-mgr apply <file.json> [--save])"
  [[ -f "$src_file" ]] || die "apply: file not found: $src_file"

  jq empty "$src_file" 2>/dev/null || die "apply: invalid JSON in $src_file"

  local sv
  sv="$(jq -r '.schema_version // empty' "$src_file")"
  [[ "$sv" == "1" ]] || die "apply: unsupported schema_version '${sv:-missing}' in $src_file (expected 1)"

  # Auto-arm safe window when running over SSH (mirrors commit behaviour)
  [[ -z "$safe_window" ]] && running_over_ssh && safe_window="$DEFAULT_SAFE_WINDOW"
  # Trial mode always needs a safety net unless explicitly disabled
  [[ "$save_mode" == false && -z "$safe_window" ]] && safe_window="$DEFAULT_SAFE_WINDOW"

  # Merge source file into current expected; source fields win, unmentioned
  # interfaces/settings from expected are preserved.
  local _merged
  _merged="$(mktemp /tmp/ip-mgr-apply-XXXXXX.json)"
  trap 'rm -f "$_merged"' RETURN

  if [[ -f "$EXPECTED" ]]; then
    jq -s '.[0] * .[1]' "$EXPECTED" "$src_file" > "$_merged"
  else
    cp "$src_file" "$_merged"
  fi

  # Shadow CANDIDATE so render_* functions operate on the merged state
  local CANDIDATE="$_merged"

  validate_renderer_capabilities

  # Snapshot current expected before touching anything
  local _snap_reason="pre-apply: $(basename "$src_file")"
  [[ -f "$EXPECTED" ]] && _snapshot_create "$_snap_reason" >/dev/null || true

  render_networkd
  render_resolved_conf
  render_timesyncd_conf

  systemctl enable systemd-networkd
  _unit_installed systemd-resolved  && systemctl enable systemd-resolved.service  || true
  _unit_installed systemd-timesyncd && systemctl enable systemd-timesyncd.service || true
  systemctl restart systemd-networkd
  _unit_installed systemd-resolved  && systemctl restart systemd-resolved.service  || true
  _unit_installed systemd-timesyncd && systemctl restart systemd-timesyncd.service || true

  local rev
  rev="$(date +%Y%m%d-%H%M%S)"

  if [[ "$save_mode" == true ]]; then
    # Let networkd settle before harvesting the running state
    echo "Waiting for network to settle..."
    sleep 3
    actual_json > "$EXPECTED"
    # Discard staged changes — expected now reflects the harvested running state
    rm -f "$JOURNAL" "$BASE/candidate.json"
    printf '%s\n' "$rev" > "$LAST_COMMIT"
    echo "apply --save complete: $rev"
    echo "Running state harvested as new expected."
  else
    echo "Trial apply complete."
    if [[ "$safe_window" != "no" ]]; then
      schedule_autorollback "$safe_window"
      echo "  To keep:   ip-mgr confirm"
      echo "  To revert: ip-mgr snapshot --rollback"
    else
      echo "  No auto-rollback armed. To revert: ip-mgr snapshot --rollback"
    fi
  fi
}


install_boot_services(){
  local script_abs
  script_abs="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  cat > "$SYSTEMD_SYSTEM/${ALIGN_UNIT}.service" <<EOF
[Unit]
Description=ip-mgr boot alignment — re-render expected state before networkd starts
Documentation=https://nxios.ca
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=bash ${script_abs} align
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

  systemctl daemon-reload
  systemctl enable "${ALIGN_UNIT}.service" 2>/dev/null || true
}

cmd_align(){
  [[ -f "$EXPECTED" ]] || { echo "ip-mgr align: no expected state, nothing to do"; return 0; }

  # If a rollback is still pending (unit files present or deadline in the future),
  # defer — the rollback timer will render the correct state when it fires.
  if [[ -f "$AUTOROLLBACK_DEADLINE" ]]; then
    local deadline remaining
    deadline="$(cat "$AUTOROLLBACK_DEADLINE")"
    remaining="$(( deadline - $(date +%s) ))"
    if [[ "$remaining" -gt 0 ]]; then
      echo "ip-mgr align: rollback pending (${remaining}s), deferring to auto-rollback"
      return 0
    fi
  fi
  if [[ -f "$SYSTEMD_SYSTEM/${AUTOROLLBACK_UNIT}.timer" ]]; then
    echo "ip-mgr align: rollback unit present, deferring to auto-rollback"
    return 0
  fi

  # Re-render from expected — networkd hasn't started yet at boot so no restart needed
  local CANDIDATE="$EXPECTED" JOURNAL_MODE="no"
  render_networkd
  render_resolved_conf
  render_timesyncd_conf
  echo "ip-mgr align: boot alignment applied"
}

cmd_discard(){
  has_pending || die "nothing to discard (no staged changes)"
  rm -f "$JOURNAL" "$CANDIDATE"
  echo "Staged changes discarded."
}

# Returns snapshot dirs sorted newest-first (one per line).
_snapshot_dirs(){
  local d
  while IFS= read -r d; do
    [[ -d "$SNAPS/$d" ]] && echo "$SNAPS/$d"
  done < <(ls -1 "$SNAPS" 2>/dev/null | sort -r)
}

# Create a snapshot; writes meta.json with reason. Prints the snapshot dir path.
_snapshot_create(){
  local reason="${1:-manual}"
  local ts dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$SNAPS/$ts"
  mkdir -p "$dir"

  printf '{"timestamp":"%s","reason":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$reason" \
    > "$dir/meta.json"

  ip -json link  > "$dir/ip-link.json"  2>/dev/null || true
  ip -json addr  > "$dir/ip-addr.json"  2>/dev/null || true
  ip -json route > "$dir/ip-route4.json" 2>/dev/null || true
  ip -json -6 route > "$dir/ip-route6.json" 2>/dev/null || true
  actual_json > "$dir/actual.json" 2>/dev/null || true
  [[ -f "$EXPECTED"  ]] && cp "$EXPECTED"  "$dir/expected.json"  || true
  [[ -f "$CANDIDATE" ]] && cp "$CANDIDATE" "$dir/candidate.json" || true

  local conf_dir="$dir/configs"
  mkdir -p "$conf_dir"
  [[ -d "$ETC_NETWORK"    ]] && cp -a "$ETC_NETWORK"    "$conf_dir/network"         || true
  [[ -d "$NETWORKMANAGER" ]] && cp -a "$NETWORKMANAGER" "$conf_dir/NetworkManager"  || true
  [[ -d "$NETPLAN"        ]] && cp -a "$NETPLAN"        "$conf_dir/netplan"         || true
  [[ -d "$NETWORKD"       ]] && cp -a "$NETWORKD"       "$conf_dir/systemd-network" || true
  [[ -f "$RESOLV_CONF"    ]] && cp    "$RESOLV_CONF"    "$conf_dir/resolv.conf"     || true

  command -v nmcli      &>/dev/null && nmcli device status > "$dir/nmcli-devices.txt"   2>/dev/null || true
  command -v networkctl &>/dev/null && networkctl list      > "$dir/networkctl-list.txt" 2>/dev/null || true
  command -v resolvectl &>/dev/null && resolvectl status    > "$dir/resolvectl-status.txt" 2>/dev/null || true
  ip route show    > "$dir/ip-route4.txt" 2>/dev/null || true
  ip -6 route show > "$dir/ip-route6.txt" 2>/dev/null || true
  ip rule show     > "$dir/ip-rule.txt"   2>/dev/null || true

  echo "$dir"
}

# Print an indexed table of snapshots, newest-first. Optional limit N.
_snapshot_list(){
  local limit="${1:-0}"  # 0 = unlimited
  local idx=0
  printf '%-4s  %-19s  %s\n' '#' 'Timestamp' 'Reason'
  printf '%-4s  %-19s  %s\n' '----' '-------------------' '------'
  while IFS= read -r d; do
    idx=$(( idx + 1 ))
    [[ "$limit" -gt 0 && "$idx" -gt "$limit" ]] && break
    local ts reason
    ts="$(basename "$d")"
    reason="$(jq -r '.reason // "unknown"' "$d/meta.json" 2>/dev/null || echo "unknown")"
    printf '%-4s  %-19s  %s\n' "$idx" "$ts" "$reason"
  done < <(_snapshot_dirs)
  [[ "$idx" -eq 0 ]] && echo "(no snapshots)"
}

# Restore from snapshot by index (1=newest) or default to most recent.
# Falls back to $COMMITS/ entries if no snapshots with expected.json exist.
_snapshot_rollback(){
  local id="${1:-1}"
  local target="" idx=0

  while IFS= read -r d; do
    idx=$(( idx + 1 ))
    if [[ "$idx" -eq "$id" ]]; then
      target="$d"
      break
    fi
  done < <(_snapshot_dirs)

  # Fallback: look in legacy $COMMITS/ dir if no snapshot found
  if [[ -z "$target" || ! -f "$target/expected.json" ]]; then
    if [[ "$id" -eq 1 ]]; then
      local legacy_last
      if [[ -f "$LAST_COMMIT" ]]; then
        legacy_last="$COMMITS/$(cat "$LAST_COMMIT").expected.json"
      else
        legacy_last="$(ls -1 "$COMMITS"/*.expected.json 2>/dev/null | sort | tail -n 1 || true)"
      fi
      if [[ -n "$legacy_last" && -f "$legacy_last" ]]; then
        echo "WARNING: no snapshots found; falling back to legacy commit store."
        cp "$legacy_last" "$EXPECTED"
        rm -f "$JOURNAL" "$BASE/candidate.json"
        local CANDIDATE="$EXPECTED" JOURNAL_MODE="no"
        cmd_validate || die "rollback target failed validation; aborting"
        render_networkd; render_resolved_conf; render_timesyncd_conf
        systemctl restart systemd-networkd
        _unit_installed systemd-resolved  && systemctl restart systemd-resolved.service  || true
        _unit_installed systemd-timesyncd && systemctl restart systemd-timesyncd.service || true
        _disarm_autorollback
        echo "rolled back to $(basename "$legacy_last")"
        return
      fi
    fi
    die "snapshot #${id} not found or has no expected.json"
  fi

  local reason
  reason="$(jq -r '.reason // "unknown"' "$target/meta.json" 2>/dev/null || echo "unknown")"

  cp "$target/expected.json" "$EXPECTED"
  rm -f "$JOURNAL" "$BASE/candidate.json"
  local CANDIDATE="$EXPECTED" JOURNAL_MODE="no"

  cmd_validate || die "rollback target failed validation; aborting to avoid applying broken config"
  render_networkd
  render_resolved_conf
  render_timesyncd_conf
  systemctl restart systemd-networkd
  _unit_installed systemd-resolved  && systemctl restart systemd-resolved.service  || true
  _unit_installed systemd-timesyncd && systemctl restart systemd-timesyncd.service || true
  _disarm_autorollback

  echo "rolled back to snapshot #${id}: $(basename "$target") (${reason})"
}

# Delete snapshots beyond the N most recent.
_snapshot_prune(){
  local limit="${1:-50}"
  [[ "$limit" =~ ^[0-9]+$ ]] || die "snapshot --prune: limit must be a positive integer"
  [[ "$limit" -ge 1 ]]       || die "snapshot --prune: limit must be at least 1"

  local idx=0 pruned=0
  while IFS= read -r d; do
    idx=$(( idx + 1 ))
    if [[ "$idx" -gt "$limit" ]]; then
      rm -rf "$d"
      pruned=$(( pruned + 1 ))
    fi
  done < <(_snapshot_dirs)

  echo "snapshot --prune: kept ${limit}, removed ${pruned} snapshot(s)."
}

cmd_snapshot(){
  local reason="manual"
  local list_limit=0
  local rollback_id=1
  local action="create"  # create | list | rollback | prune
  local prune_limit=50

  for arg in "$@"; do
    case "$arg" in
      --reason:*)    reason="${arg#--reason:}" ;;
      --list)        action="list";    list_limit=0 ;;
      --list:*)
        action="list"
        list_limit="${arg#--list:}"
        [[ "$list_limit" =~ ^[0-9]+$ ]] || die "snapshot --list: limit must be a positive integer"
        ;;
      --rollback)    action="rollback"; rollback_id=1 ;;
      --rollback:*)
        action="rollback"
        rollback_id="${arg#--rollback:}"
        [[ "$rollback_id" =~ ^[0-9]+$ && "$rollback_id" -ge 1 ]] \
          || die "snapshot --rollback: id must be a positive integer"
        ;;
      --prune)       action="prune"; prune_limit=50 ;;
      --prune:*)
        action="prune"
        prune_limit="${arg#--prune:}"
        [[ "$prune_limit" =~ ^[0-9]+$ && "$prune_limit" -ge 1 ]] \
          || die "snapshot --prune: limit must be a positive integer"
        ;;
      *) die "snapshot: unknown option '$arg'" ;;
    esac
  done

  case "$action" in
    create)   _snapshot_create "$reason" ;;
    list)     _snapshot_list   "$list_limit" ;;
    rollback) _snapshot_rollback "$rollback_id" ;;
    prune)    _snapshot_prune    "$prune_limit" ;;
  esac
}

cmd_detect(){
  echo
  echo "=== Network Stack Detection ==="
  echo

  # ── Service table ─────────────────────────────────────────────────────────
  printf "%-22s  %-10s  %-10s  %-10s  %s\n" \
    "Service" "Installed" "Enabled" "Active" "Config"
  printf "%-22s  %-10s  %-10s  %-10s  %s\n" \
    "----------------------" "---------" "---------" "---------" "-------------------------------"

  local svc
  for svc in systemd-networkd NetworkManager networking dhcpcd connman systemd-resolved; do
    local installed="no" enabled="-" active="-" config="-"
    local load_state
    load_state="$(systemctl show "${svc}.service" --property=LoadState --value 2>/dev/null || echo "not-found")"

    if [[ "$load_state" == "loaded" || "$load_state" == "masked" ]]; then
      installed="yes"
      enabled="$(systemctl is-enabled "${svc}.service" 2>/dev/null || true)"
      active="$(systemctl is-active  "${svc}.service" 2>/dev/null || true)"
    fi

    case "$svc" in
      NetworkManager)
        local n_conn=0
        if [[ -d "$NETWORKMANAGER_CONNECTIONS" ]]; then
          n_conn="$(find "$NETWORKMANAGER_CONNECTIONS" -maxdepth 1 -type f 2>/dev/null | wc -l)"
        fi
        if [[ "$n_conn" -gt 0 ]]; then config="${n_conn} connection file(s)"; fi
        ;;
      networking)
        if [[ -f "$NETWORK_INTERFACES" ]]; then config="$NETWORK_INTERFACES"; fi
        ;;
      systemd-networkd)
        local n_net=0
        if [[ -d "$NETWORKD" ]]; then
          n_net="$(find "$NETWORKD" -maxdepth 1 -name '*.network' 2>/dev/null | wc -l)"
        fi
        if [[ "$n_net" -gt 0 ]]; then config="${n_net} .network file(s)"; fi
        ;;
      dhcpcd)
        if [[ -f "$DHCPCD_CONF" ]]; then config="$DHCPCD_CONF"; fi
        ;;
    esac

    printf "%-22s  %-10s  %-10s  %-10s  %s\n" \
      "$svc" "$installed" "$enabled" "$active" "$config"
  done

  # netplan is not a systemd service
  local np_count=0
  if [[ -d "$NETPLAN" ]]; then
    np_count="$(find "$NETPLAN" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l)"
  fi
  local np_installed="no" np_config="-"
  if [[ "$np_count" -gt 0 ]]; then
    np_installed="yes"
    np_config="${np_count} YAML file(s) in $NETPLAN/"
  fi
  printf "%-22s  %-10s  %-10s  %-10s  %s\n" \
    "netplan" "$np_installed" "n/a" "n/a" "$np_config"

  echo

  # ── Interface ownership ────────────────────────────────────────────────────
  echo "Interface ownership:"
  echo

  if command -v nmcli &>/dev/null; then
    echo "  NetworkManager:"
    nmcli device status 2>/dev/null | awk 'NR>1 && $1 != "lo" {
      printf "    %-12s %-14s", $1, $3
      for (i=4; i<=NF; i++) printf " %s", $i
      print ""
    }' || true
    echo
  fi

  if [[ -f "$NETWORK_INTERFACES" ]]; then
    echo "  ifupdown ($NETWORK_INTERFACES):"
    awk '/^iface / && $2 != "lo" { printf "    %-16s %s %s\n", $2, $3, $4 }' \
      "$NETWORK_INTERFACES"
    echo
  fi

  local nd_active
  nd_active="$(systemctl is-active systemd-networkd 2>/dev/null || true)"
  if [[ "$nd_active" == "active" ]] && command -v networkctl &>/dev/null; then
    echo "  systemd-networkd:"
    networkctl list --no-legend 2>/dev/null | \
      awk 'NF>=4 && $2 != "lo" { printf "    %-12s %-12s %s\n", $2, $4, $5 }' || true
    echo
  fi

  if [[ "$np_count" -gt 0 ]]; then
    echo "  netplan config files:"
    find "$NETPLAN" -maxdepth 1 -name '*.yaml' 2>/dev/null | sort | while read -r f; do
      echo "    $f"
    done
    echo
  fi
}

# ===== help/version =====

cmd_version(){
  echo "$APP version $SCRIPT_VERSION"
  echo "schema version $SCHEMA_VERSION"
}

usage(){
  cat <<EOF
$APP $SCRIPT_VERSION

USAGE:
  ip-mgr.sh [-4|-6] [-y|--yes] set IFACE OPTIONS...
  ip-mgr.sh [-4|-6] [-y|--yes] add IFACE OPTIONS...
  ip-mgr.sh [-4|-6] [-y|--yes] remove|delete|del|rem|rm|no IFACE [OPTIONS...]
  ip-mgr.sh show [candidate|expected|actual|--file:PATH] [IFACE|dns:|ntp:|route:] [--as:plain|json|cmd]
  ip-mgr.sh compare [candidate|expected|actual] [candidate|expected|actual]
  ip-mgr.sh validate
  ip-mgr.sh commit [--safe-window[:N]] [--no-safe-window]
  ip-mgr.sh confirm
  ip-mgr.sh apply <file.json> [--save] [--confirm] [--safe-window[:N]] [--no-safe-window]
  ip-mgr.sh [-y|--yes] clean [--adopt-live] [--no-dhcp] [--to-dhcp] [--no-candidate] [--apply] [--confirm] [--no-disable] [--safe-window[:N]] [--no-safe-window]
  ip-mgr.sh detect
  ip-mgr.sh audit [--fix] [--purge[:[all|PKG,...]]] [--confirm]
  ip-mgr.sh snapshot [--reason:TEXT] [--list[:N]] [--rollback[:ID]] [--prune[:N]]
  ip-mgr.sh discard
  ip-mgr.sh align
  ip-mgr.sh version

Config model:
  set / add / remove  → append commands to the staged journal ($BASE/candidate)
  validate            → validate the projected staged state against schema and rules
  compare             → diff expected vs staged state (shows pending changes)
  commit              → replay journal against current expected.json → validate →
                        snapshot → promote to expected.json → apply → clear journal
  discard             → delete the staged journal (no effect on expected.json)
  show                → defaults to staged state when changes are pending, else expected

OPTIONS:
  -y, --yes     Answer yes to confirmation prompts; skip failed lines in batch mode
  -a:ADDR       --address:ADDR
  -g:ADDR       --gateway:ADDR / --gw:ADDR
  -d:ADDR       --dns:ADDR
  -s:DOMAIN     --search:DOMAIN  (search domain, per-interface)
  -m:N          --mtu:N
  -D:TEXT       --description:TEXT
  -h            --dhcp
  -n            --ra
  -6o:LIST      --options:LIST
  -u            --up
  -x            --down

Pseudo-targets (use in place of IFACE):
  dns:          Global DNS servers  (values are bare IP addresses)
  domains:      Global search domains  (values are bare domain names)
  domain:       Alias for domains: — bare remove requires explicit names
  ntp:          NTP servers  (values are bare addresses or hostnames)

  ip-mgr add dns: 8.8.8.8 2001:4860:4860::8888
  ip-mgr add domains: internal.corp example.com
  ip-mgr add ntp: pool.ntp.org 192.168.1.1
  ip-mgr -4 remove dns:            # clear all IPv4 DNS entries
  ip-mgr remove dns: 8.8.8.8      # remove specific entry
  ip-mgr remove domains:           # clear all search domains
  ip-mgr remove domain: corp.net   # remove specific search domain

PPPoE:
  -i:IFACE      --if:IFACE    Parent Ethernet interface (implies kind=pppoe)
  --identity:   PPPoE username / identity
  --pass:       PPPoE password (encrypted with systemd-creds before storage)
  --svcname:    PPPoE service name (optional; most ISPs leave this empty)

  ip-mgr add pppoe0 -i:eth0 --identity:user@isp.net --pass:secret
  ip-mgr set pppoe0 --pass:newpassword
  ip-mgr remove pppoe0            # removes PPPoE connection entirely

IPv6 options:
  stable, privacy, none

VLANs:
  Interface names matching PARENT.VLANID (e.g. eth1.100) are automatically
  created as VLAN sub-interfaces when added. The parent interface must be
  managed by ip-mgr. 'remove IFACE' with no options deletes the VLAN entry.
  Commit generates a .netdev file to create the device and adds VLAN= to the
  parent .network file.

Clean pipeline:
  Snapshot -> Detect -> Acquire -> Report -> Transform -> Analyze -> Validate -> Compare -> Write

Clean stage switches:
  Transform:
    --no-dhcp       Ignore discovered dynamic DHCP/RA lease addresses
    --to-dhcp       Convert discovered static assignments to DHCPv4 / RA+DHCPv6 intent
  Write:
    --no-candidate  Analyze/report without writing candidate.json
    --apply         Commit the generated candidate after confirmation
    --confirm       Skip the interactive --apply prompt for scripts
    --no-disable    With --apply, do not disable old network control-plane services

  --no-dhcp and --to-dhcp can be combined: dynamic lease addresses are ignored
  while static assignments are converted into automatic addressing policy.

Apply:
  Renders and activates a (possibly partial) NetworkState JSON file without
  going through the candidate → validate → commit pipeline.
  Source fields overlay the current expected state; unmentioned interfaces
  and settings are preserved from expected.
  Trial mode (no --save): auto-rollback is always armed.
    ip-mgr apply subset.json              # try it — rolls back automatically
    ip-mgr confirm                        # keep it
    ip-mgr apply subset.json --save       # apply and promote to expected
    --save              Promote merged state to expected.json (permanent)
    --safe-window[:N]   Override rollback window (trial mode)
    --no-safe-window    Disable auto-rollback in trial mode (use with care)

Safe-window (commit / apply / clean --apply):
  When running over SSH, commit automatically arms a ${DEFAULT_SAFE_WINDOW}s auto-rollback timer.
  apply (trial mode) always arms it regardless of SSH.
  If the session is lost and 'ip-mgr confirm' is not run in time, the previous
  configuration is restored automatically.
    --safe-window       Arm with default ${DEFAULT_SAFE_WINDOW}s window (explicit)
    --safe-window:N     Arm with N-second window (minimum 10)
    --no-safe-window    Disable auto-rollback (for scripts/automation)
  confirm cancels a pending auto-rollback.

Audit:
  Investigates the system against the last committed expected state.
  Reports on control plane health, state drift, and rendered file presence.
  Audit switches:
    --fix              Remediate found issues (disable competing stacks, restore expected state)
    --purge            With --fix, purge packages for the disabled competing stacks
    --purge:all        With --fix, purge all known competing stacks
    --purge:PKG,...    With --fix, purge named packages (systemd stack is always protected)
    --confirm          Skip interactive prompts (or use -y/--yes globally)

Snapshot:
  Captures a point-in-time record of running state, ip-mgr config, and rendered
  files. Auto-snapshots are taken before commit, apply, clean, and audit --fix.
  Snapshot switches:
    --reason:TEXT       Label this snapshot (default: "manual")
    --list[:N]          List snapshots newest-first; optional N limits to N entries
    --rollback[:ID]     Restore expected state from snapshot #ID (default: 1 = newest)
    --prune[:N]         Delete snapshots beyond the N most recent (default N=50)

  Examples:
    ip-mgr snapshot                     # manual snapshot
    ip-mgr snapshot --reason:"before lab test"
    ip-mgr snapshot --list
    ip-mgr snapshot --list:10           # show 10 most recent
    ip-mgr snapshot --rollback          # revert to most recent pre-commit snapshot
    ip-mgr snapshot --rollback:3        # revert to 3rd-most-recent snapshot
    ip-mgr snapshot --prune             # keep 50, delete the rest
    ip-mgr snapshot --prune:10          # keep only 10

Align (boot enforcement):
  Installed automatically by commit as a systemd service that runs before
  network-pre.target at every boot. Re-renders expected.json → .network files
  so the system always starts from the JSON source of truth, even if someone
  manually edited a .network file or restored from backup.
  Defers silently when a rollback timer is pending (rollback takes priority).
  Can also be run manually to re-sync rendered files without a full commit.

Commands abbreviate to unique prefixes of at least 2 chars.
EOF
}

# ===== main =====

# Dispatch a single parsed command line (used by both single-command and batch modes).
dispatch_one(){
  local fam="" GLOBAL_CONFIRM="no"
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      -4) fam=4; shift ;;
      -6) fam=6; shift ;;
      -y|--yes) GLOBAL_CONFIRM="yes"; shift ;;
      *) break ;;
    esac
  done

  local raw="${1:-help}"
  shift || true

  case "$raw" in
    help|--help|-?) usage; return ;;
    version|--version) cmd_version; return ;;
  esac

  local cmd
  cmd="$(resolve_command "$raw")"

  if needs_store "$cmd" "$@"; then
    init_store
  fi

  # Journal mode: intercept mutation commands — append to journal instead of
  # writing JSON state.  Commit replay sets JOURNAL_MODE="no" (local override)
  # so mutations write to the temp projected state during replay.
  if [[ "${JOURNAL_MODE:-yes}" == "yes" ]]; then
    case "$cmd" in
      set|add|remove)
        _journal_append "$fam" "$cmd" "$@"
        return ;;
    esac
  fi

  case "$cmd" in
    set)      cmd_set      "$fam" "$@" ;;
    add)      cmd_add      "$fam" "$@" ;;
    remove)   cmd_remove   "$fam" "$@" ;;
    show)     cmd_show     "$fam" "$@" ;;
    compare)  cmd_compare  "$@" ;;
    validate) cmd_validate ;;
    commit)   cmd_commit   "$@" ;;
    confirm)  cmd_confirm ;;
    discard)  cmd_discard ;;
    snapshot) cmd_snapshot "$@" ;;
    apply)    cmd_apply    "$@" ;;
    align)    cmd_align ;;
    detect)   cmd_detect ;;
    audit)    cmd_audit    "$@" ;;
    version)  cmd_version ;;
    status)   cmd_clean    "--no-candidate" "$@" ;;
    clean)    cmd_clean    "$@" ;;
    help)     usage ;;
  esac
}

# Read ip-mgr commands from stdin (heredoc / pipe), one per line.
# Comments (#) and blank lines are ignored.
# On error: prompts "Continue? [Y/n]" via /dev/tty; -y auto-skips.
batch_mode(){
  local _confirm="${1:-no}"
  local line lineno=0

  while IFS= read -r line; do
    lineno=$(( lineno + 1 ))
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    printf '[%d] %s\n' "$lineno" "$line"

    local -a _args
    read -ra _args <<< "$line"

    # Run in a subshell so die()/exit only kills the subshell, not the batch loop.
    if ( dispatch_one "${_args[@]}" ); then
      continue
    fi

    printf '  at line %d: %s\n' "$lineno" "$line" >&2

    if [[ "$_confirm" == "yes" ]]; then
      printf '  Skipping (continuing with -y).\n' >&2
      continue
    fi

    # Read from /dev/tty so the prompt works even when stdin is the heredoc.
    local _ans
    printf '  Continue? [Y/n] ' >&2
    if IFS= read -r _ans </dev/tty 2>/dev/null; then
      case "${_ans:-Y}" in
        [Yy]|[Yy][Ee][Ss]|'') printf '  Skipping.\n' >&2; continue ;;
        *) exit 1 ;;
      esac
    else
      # No controlling terminal and no -y — stop.
      exit 1
    fi
  done
}

main(){
  case "${1:-}" in
    help|--help|version|--version|-?)
      case "$1" in
        version|--version) cmd_version ;;
        *) usage ;;
      esac
      return
      ;;
  esac

  # Batch mode: stdin is a pipe or heredoc.
  # Accept leading global flags (-y/--yes) before the (empty) command list.
  if [[ ! -t 0 ]]; then
    local _orig_args=("$@") _batch_confirm="no" _remaining=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -y|--yes) _batch_confirm="yes"; shift ;;
        *)        _remaining+=("$1");   shift ;;
      esac
    done
    if [[ ${#_remaining[@]} -eq 0 ]]; then
      # Elevate once upfront; pass original args so sudo re-inherits -y and stdin.
      [[ $EUID -eq 0 ]] || elevate "${_orig_args[@]}"
      check_deps
      init_store
      batch_mode "$_batch_confirm"
      return
    fi
    # Non-flag args remain — fall through to single-command dispatch.
    set -- "${_remaining[@]}"
  fi

  if [[ $# -eq 0 ]]; then
    usage
    return
  fi

  maybe_elevate "$@"
  check_deps
  dispatch_one "$@"
}

main "$@"
