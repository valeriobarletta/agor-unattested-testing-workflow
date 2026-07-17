#!/usr/bin/env bash
# =============================================================================
# network-setup.sh — Configure Isolated Docker Network for Agor Executors
# =============================================================================
# Usage:
#   network-setup.sh <create|destroy|status|lockdown|allow>
#
# Commands:
#   create    Create the isolated Docker network with default-deny egress
#   destroy   Remove the network and all iptables rules
#   status    Show network configuration and active rules
#   lockdown  Reapply default-deny egress rules (idempotent)
#   allow     Add a custom endpoint to the allowlist
#
# Description:
#   Creates a Docker bridge network named 'agor-isolated' that has NO
#   external routing. All outbound traffic is blocked by default.
#   Specific endpoints (package registries, GitHub API) can be allowlisted.
#
#   This is the primary defense against data exfiltration from AI agents.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
NETWORK_NAME="agor-isolated"
IPTABLES_CHAIN="AGOR_EGRESS"
DNS_ALLOWLIST=("8.8.8.8" "1.1.1.1")
DEFAULT_ALLOWED_DOMAINS=(
    "registry.npmjs.org"
    "pypi.org"
    "crates.io"
    "github.com"
    "api.github.com"
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
error() { log "ERROR: $*"; exit 1; }
warn() { log "WARN: $*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  create                Create isolated network with default-deny
  destroy               Remove network and all rules
  status                Show network config and active rules
  lockdown              Reapply egress lockdown (idempotent)
  allow --host <host> --port <port>   Add endpoint to allowlist

Examples:
  $(basename "$0") create
  $(basename "$0") status
  $(basename "$0") allow --host registry.example.com --port 443
  $(basename "$0") destroy
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
check_prereqs() {
    command -v docker >/dev/null 2>&1 || error "Docker not found"
    command -v iptables >/dev/null 2>&1 || warn "iptables not found — network filtering may not work"
}

# ---------------------------------------------------------------------------
# Get bridge interface name from Docker network
# ---------------------------------------------------------------------------
get_bridge_interface() {
    docker network inspect "$NETWORK_NAME" \
        --format '{{json .Options}}' 2>/dev/null \
        | python3 -c "
import json, sys
try:
    opts = json.load(sys.stdin)
    print(opts.get('com.docker.network.bridge.name', ''))
except:
    print('')
" || echo ""
}

# ---------------------------------------------------------------------------
# CREATE — Build isolated network
# ---------------------------------------------------------------------------
cmd_create() {
    log "Creating isolated network: $NETWORK_NAME"
    check_prereqs

    # Remove existing network if present
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        warn "Network $NETWORK_NAME already exists — removing"
        docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    fi

    # Create internal bridge network (no external connectivity)
    docker network create \
        --driver bridge \
        --internal \
        --subnet 172.25.0.0/16 \
        --gateway 172.25.0.1 \
        --opt com.docker.network.bridge.name=br-agor \
        --opt com.docker.network.bridge.enable_ip_masquerade=false \
        "$NETWORK_NAME"

    log "Network created: $NETWORK_NAME (internal, no external routing)"

    # Apply iptables lockdown
    cmd_lockdown

    log "Network setup complete. All outbound traffic is blocked by default."
    log "Use '$(basename "$0") allow --host <host> --port <port>' to add endpoints."
}

# ---------------------------------------------------------------------------
# LOCKDOWN — Apply default-deny egress rules
# ---------------------------------------------------------------------------
cmd_lockdown() {
    log "Applying egress lockdown..."

    # Get bridge interface
    local bridge_iface
    bridge_iface="$(get_bridge_interface)"
    [[ -z "$bridge_iface" ]] && {
        warn "Cannot determine bridge interface — skipping iptables rules"
        return 0
    }

    log "Bridge interface: $bridge_iface"

    # Flush and recreate chain
    iptables -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -D FORWARD -o "$bridge_iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -X "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -N "$IPTABLES_CHAIN" 2>/dev/null || true

    # Link chain to FORWARD for this bridge (check for duplicates first)
    iptables -C FORWARD -o "$bridge_iface" -j "$IPTABLES_CHAIN" 2>/dev/null || \
        iptables -A FORWARD -o "$bridge_iface" -j "$IPTABLES_CHAIN"

    # Allow established/related connections (return traffic)
    iptables -A "$IPTABLES_CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow loopback within container
    iptables -A "$IPTABLES_CHAIN" -d 127.0.0.0/8 -j ACCEPT

    # Allow DNS to authorized servers only
    for dns in "${DNS_ALLOWLIST[@]}"; do
        iptables -A "$IPTABLES_CHAIN" -p udp --dport 53 -d "$dns" -j ACCEPT
        iptables -A "$IPTABLES_CHAIN" -p tcp --dport 53 -d "$dns" -j ACCEPT
    done
    # Block all other DNS
    iptables -A "$IPTABLES_CHAIN" -p udp --dport 53 -j DROP
    iptables -A "$IPTABLES_CHAIN" -p tcp --dport 53 -j DROP

    # Allow default endpoints (package registries, GitHub)
    for domain in "${DEFAULT_ALLOWED_DOMAINS[@]}"; do
        local ips
        ips="$(dig +short "$domain" 2>/dev/null || true)"
        for ip in $ips; do
            # Only add IPv4 addresses
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                iptables -A "$IPTABLES_CHAIN" -p tcp -d "$ip" --dport 443 -j ACCEPT
                log "Allowlisted: $domain ($ip:443)"
            fi
        done
    done

    # Log and drop everything else
    iptables -A "$IPTABLES_CHAIN" -j LOG --log-prefix "AGOR_BLOCKED: " --log-level 4 2>/dev/null || true
    iptables -A "$IPTABLES_CHAIN" -j DROP

    log "Egress lockdown applied. Default policy: DENY."
}

# ---------------------------------------------------------------------------
# ALLOW — Add custom endpoint to allowlist
# ---------------------------------------------------------------------------
cmd_allow() {
    local host="" port="443"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host) host="$2"; shift 2 ;;
            --port) port="$2"; shift 2 ;;
            *) error "Unknown option: $1" ;;
        esac
    done
    [[ -z "$host" ]] && error "--host is required"

    log "Adding allowlist entry: $host:$port"

    local bridge_iface
    bridge_iface="$(get_bridge_interface)"
    [[ -z "$bridge_iface" ]] && error "Network not found — run 'create' first"

    local ips
    ips="$(dig +short "$host" 2>/dev/null || true)"
    [[ -z "$ips" ]] && error "Could not resolve $host"

    for ip in $ips; do
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            iptables -I "$IPTABLES_CHAIN" 2 -p tcp -d "$ip" --dport "$port" -j ACCEPT
            log "Allowlisted: $host ($ip:$port)"
        fi
    done
}

# ---------------------------------------------------------------------------
# DESTROY — Remove network and rules
# ---------------------------------------------------------------------------
cmd_destroy() {
    log "Destroying network: $NETWORK_NAME"

    # Remove iptables rules
    local bridge_iface
    bridge_iface="$(get_bridge_interface)"
    if [[ -n "$bridge_iface" ]]; then
        iptables -D FORWARD -o "$bridge_iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    fi
    iptables -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -X "$IPTABLES_CHAIN" 2>/dev/null || true
    log "iptables rules removed"

    # Remove Docker network
    docker network rm "$NETWORK_NAME" 2>/dev/null || warn "Network $NETWORK_NAME not found"
    log "Network destroyed"
}

# ---------------------------------------------------------------------------
# STATUS — Show current configuration
# ---------------------------------------------------------------------------
cmd_status() {
    echo "=== Docker Network ==="
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        docker network inspect "$NETWORK_NAME" --format \
            'Name: {{.Name}}\nDriver: {{.Driver}}\nInternal: {{.Internal}}\nSubnet: {{(index .IPAM.Config 0).Subnet}}\nGateway: {{(index .IPAM.Config 0).Gateway}}'
    else
        echo "Network '$NETWORK_NAME' does not exist"
    fi

    echo ""
    echo "=== iptables Rules ==="
    if iptables -L "$IPTABLES_CHAIN" >/dev/null 2>&1; then
        iptables -L "$IPTABLES_CHAIN" -n --line-numbers
    else
        echo "Chain '$IPTABLES_CHAIN' does not exist"
    fi
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && usage

case "$1" in
    create)   shift; cmd_create "$@" ;;
    destroy)  shift; cmd_destroy "$@" ;;
    status)   shift; cmd_status "$@" ;;
    lockdown) shift; cmd_lockdown "$@" ;;
    allow)    shift; cmd_allow "$@" ;;
    --help|-h) usage ;;
    *) error "Unknown command: $1" ;;
esac
