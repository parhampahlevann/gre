#!/bin/bash
# ============================================================
# GitHub: vatanhost
# Multi-mode Tunnel Manager: GRE+IPsec(AES-256) / WireGuard+udp2raw
# ============================================================
set -e

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
RESET=$(tput sgr0)

GRE_NAME="vatan-m2"
WG_IFACE="wg-vatan"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
UDP2RAW_BIN="/usr/local/bin/udp2raw"
UDP2RAW_SERVICE="/etc/systemd/system/udp2raw-vatan.service"
UDP2RAW_PORT=4096         # raw obfuscated port (TCP-looking), exposed publicly on FOREIGN
WG_LISTEN_PORT=51820      # real WireGuard UDP port (each side's own local socket)
WG_UDP2RAW_LOCAL_PORT=51821  # separate local port the IRAN-side udp2raw client binds to
                              # (must differ from WG_LISTEN_PORT or udp2raw fails with
                              # "socket bind error" since WireGuard already owns that port)

PORT_STATE_DIR="/etc/vatan-tunnel"
PORT_STATE_FILE="${PORT_STATE_DIR}/ports.conf"
RESTORE_SCRIPT="/usr/local/bin/vatan-restore-ports.sh"
RESTORE_SERVICE="/etc/systemd/system/vatan-restore-ports.service"

GRE_CONF_FILE="${PORT_STATE_DIR}/gre.conf"
GRE_RESTORE_SCRIPT="/usr/local/bin/vatan-restore-gre.sh"
GRE_RESTORE_SERVICE="/etc/systemd/system/vatan-gre-tunnel.service"

# ============================================================
# ROBUST APT/DPKG INSTALL HELPER
# Fixes the common "Sub-process /usr/bin/dpkg returned an error
# code" failure automatically, then retries the install.
# ============================================================
safe_apt_install() {
    local packages=("$@")

    # 1) Wait for any other apt/dpkg process to release its lock
    local waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [[ $waited -ge 60 ]]; then
            echo -e "${YELLOW}[!] apt/dpkg lock has been held for 60s, forcing removal of stale lock files...${RESET}"
            sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock
            break
        fi
        echo -e "${YELLOW}[*] Waiting for another apt/dpkg process to finish...${RESET}"
        sleep 5
        waited=$((waited + 5))
    done

    # 2) Repair any half-configured packages from a previous failed run
    sudo dpkg --configure -a >/dev/null 2>&1 || true
    sudo apt-get install -f -y >/dev/null 2>&1 || true

    # 3) Refresh package lists
    sudo apt-get update -y

    # 4) Try the actual install
    if sudo apt-get install -y "${packages[@]}"; then
        return 0
    fi

    # 5) First attempt failed -> run the standard recovery sequence, then retry once
    echo -e "${YELLOW}[!] Install failed, attempting automatic repair (dpkg --configure -a / apt --fix-broken install)...${RESET}"
    sudo dpkg --configure -a || true
    sudo apt-get install -f -y || true
    sudo apt-get clean
    sudo apt-get update -y

    if sudo apt-get install -y "${packages[@]}"; then
        echo -e "${GREEN}[+] Install succeeded after repair.${RESET}"
        return 0
    fi

    # 6) Still broken -> show real dpkg log so the user can see the actual root cause
    echo -e "${RED}[!] Package install still failing after automatic repair.${RESET}"
    echo -e "${YELLOW}---- Last dpkg log entries (real error is usually here) ----${RESET}"
    sudo tail -n 40 /var/log/dpkg.log 2>/dev/null
    echo -e "${YELLOW}---- Disk space ----${RESET}"
    df -h /
    return 1
}

# ============================================================
# SHARED FUNCTIONS (usable from any menu option)
# ============================================================
remove_gre_tunnel() {
    echo -e "${YELLOW}[*] Removing GRE tunnel...${RESET}"
    sudo ip link set "$GRE_NAME" down 2>/dev/null || true
    sudo ip tunnel del "$GRE_NAME" 2>/dev/null || true
    sudo iptables -t nat -D PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2 2>/dev/null || true
    sudo iptables -t nat -D PREROUTING -j DNAT --to-destination 132.168.30.1 2>/dev/null || true
    sudo iptables -A INPUT --proto icmp -j DROP 2>/dev/null || true
    sudo systemctl stop vatan-gre-tunnel 2>/dev/null || true
    sudo systemctl disable vatan-gre-tunnel 2>/dev/null || true
    sudo rm -f "$GRE_RESTORE_SERVICE" "$GRE_RESTORE_SCRIPT" "$GRE_CONF_FILE"
    sudo systemctl daemon-reload 2>/dev/null || true
    echo -e "${GREEN}[+] GRE tunnel removed.${RESET}"
}

remove_wg_udp2raw() {
    echo -e "${YELLOW}[*] Removing WireGuard + udp2raw...${RESET}"
    sudo systemctl stop udp2raw-vatan 2>/dev/null || true
    sudo systemctl disable udp2raw-vatan 2>/dev/null || true
    sudo rm -f "$UDP2RAW_SERVICE"
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo wg-quick down "$WG_IFACE" 2>/dev/null || true
    sudo rm -f "$WG_CONF"
    echo -e "${GREEN}[+] WireGuard + udp2raw removed.${RESET}"
}

# Reads a tunnel interface name and role flag, echoes "iface role proto port" lines'
# peer tunnel IP based on the fixed subnet conventions used at install time.
peer_ip_for() {
    local iface=$1
    local role=$2
    if [[ "$iface" == "$GRE_NAME" ]]; then
        [[ "$role" == "1" ]] && echo "132.168.30.1" || echo "132.168.30.2"
    else
        [[ "$role" == "1" ]] && echo "10.20.30.1" || echo "10.20.30.2"
    fi
}

remove_all_port_forwards() {
    echo -e "${YELLOW}[*] Removing all port-forward rules...${RESET}"
    if [[ -f "$PORT_STATE_FILE" ]]; then
        while read -r iface role proto port; do
            [[ -z "$iface" ]] && continue
            local peer tag
            peer=$(peer_ip_for "$iface" "$role")
            tag="vatan-port-${iface}-${proto}-${port}"
            if [[ "$role" == "1" ]]; then
                sudo iptables -t nat -D PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$peer:$port" -m comment --comment "$tag" 2>/dev/null || true
                sudo iptables -D FORWARD -p "$proto" -d "$peer" --dport "$port" -j ACCEPT -m comment --comment "$tag" 2>/dev/null || true
            else
                sudo iptables -D INPUT -i "$iface" -p "$proto" --dport "$port" -j ACCEPT -m comment --comment "$tag" 2>/dev/null || true
            fi
        done < "$PORT_STATE_FILE"
    fi
    sudo iptables -t nat -D POSTROUTING -o "$GRE_NAME" -j MASQUERADE 2>/dev/null || true
    sudo iptables -t nat -D POSTROUTING -o "$WG_IFACE" -j MASQUERADE 2>/dev/null || true
    sudo systemctl stop vatan-restore-ports 2>/dev/null || true
    sudo systemctl disable vatan-restore-ports 2>/dev/null || true
    sudo rm -f "$RESTORE_SERVICE" "$RESTORE_SCRIPT"
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo rm -rf "$PORT_STATE_DIR"
    echo -e "${GREEN}[+] All port forwards removed.${RESET}"
}

# Installs/refreshes a systemd oneshot service that reapplies $PORT_STATE_FILE
# at every boot, so rules survive a restart without needing iptables-persistent.
install_restore_service() {
    sudo bash -c "cat > $RESTORE_SCRIPT" <<'RESTOREEOF'
#!/bin/bash
PORT_STATE_FILE="/etc/vatan-tunnel/ports.conf"
GRE_NAME="vatan-m2"
WG_IFACE="wg-vatan"
[[ -f "$PORT_STATE_FILE" ]] || exit 0

# give tunnel interfaces time to come up
sleep 5

peer_ip_for() {
    local iface=$1 role=$2
    if [[ "$iface" == "$GRE_NAME" ]]; then
        [[ "$role" == "1" ]] && echo "132.168.30.1" || echo "132.168.30.2"
    else
        [[ "$role" == "1" ]] && echo "10.20.30.1" || echo "10.20.30.2"
    fi
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null

while read -r iface role proto port; do
    [[ -z "$iface" ]] && continue
    ip link show "$iface" >/dev/null 2>&1 || continue

    peer=$(peer_ip_for "$iface" "$role")

    iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE

    tag="vatan-port-${iface}-${proto}-${port}"
    if [[ "$role" == "1" ]]; then
        iptables -t nat -C PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$peer:$port" -m comment --comment "$tag" 2>/dev/null || \
            iptables -t nat -A PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$peer:$port" -m comment --comment "$tag"
        iptables -C FORWARD -p "$proto" -d "$peer" --dport "$port" -j ACCEPT -m comment --comment "$tag" 2>/dev/null || \
            iptables -A FORWARD -p "$proto" -d "$peer" --dport "$port" -j ACCEPT -m comment --comment "$tag"
    else
        iptables -C INPUT -i "$iface" -p "$proto" --dport "$port" -j ACCEPT -m comment --comment "$tag" 2>/dev/null || \
            iptables -A INPUT -i "$iface" -p "$proto" --dport "$port" -j ACCEPT -m comment --comment "$tag"
    fi
done < "$PORT_STATE_FILE"
RESTOREEOF
    sudo chmod +x "$RESTORE_SCRIPT"

    sudo bash -c "cat > $RESTORE_SERVICE" <<EOF
[Unit]
Description=Vatan tunnel port-forward restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RESTORE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable vatan-restore-ports >/dev/null 2>&1 || true
}

echo -e "${CYAN}"
echo "===================================="
echo "        GitHub: vatanhost"
echo "     Tunnel Manager (v2)"
echo "===================================="
echo -e "${RESET}"

echo "1 - Install GRE tunnel (no encryption — fastest, lowest overhead)"
echo "2 - Install WireGuard + udp2raw (obfuscated, encrypted) tunnel"
echo "3 - Show tunnel status"
echo "4 - Uninstall a tunnel (choose which)"
echo "5 - Manage forwarded ports (add/remove/list)"
echo "6 - Full uninstall EVERYTHING (both tunnels + all port forwards, one click)"
read -p "Select an option [1-6]: " MAIN_CHOICE

# ============================================================
# STATUS
# ============================================================
show_status() {
    echo -e "${CYAN}---- GRE interface ----${RESET}"
    if ip link show "$GRE_NAME" >/dev/null 2>&1; then
        ip -brief addr show "$GRE_NAME"
        ip link show "$GRE_NAME" | head -1
    else
        echo "Not present."
    fi

    echo -e "${CYAN}---- GRE boot-persistence service ----${RESET}"
    if systemctl list-unit-files 2>/dev/null | grep -q vatan-gre-tunnel; then
        sudo systemctl is-enabled vatan-gre-tunnel 2>/dev/null
    else
        echo "Not installed."
    fi

    echo -e "${CYAN}---- WireGuard interface ----${RESET}"
    if command -v wg >/dev/null 2>&1 && ip link show "$WG_IFACE" >/dev/null 2>&1; then
        sudo wg show "$WG_IFACE"
        ip -brief addr show "$WG_IFACE"
    else
        echo "Not present."
    fi

    echo -e "${CYAN}---- udp2raw service ----${RESET}"
    if systemctl list-unit-files 2>/dev/null | grep -q udp2raw-vatan; then
        sudo systemctl status udp2raw-vatan --no-pager -l | head -10
    else
        echo "Not installed."
    fi

    echo -e "${CYAN}---- Ping test (if tunnel IP known) ----${RESET}"
    for ip in 132.168.30.1 132.168.30.2 10.20.30.1 10.20.30.2; do
        if ip addr show 2>/dev/null | grep -q "$ip"; then
            continue
        fi
    done
    echo "(Run 'ping <peer-tunnel-ip>' manually to test latency/loss.)"
}

if [[ "$MAIN_CHOICE" == "3" ]]; then
    show_status
    exit 0
fi

# ============================================================
# PORT FORWARDING MANAGEMENT
# ============================================================
if [[ "$MAIN_CHOICE" == "5" ]]; then
    sudo mkdir -p "$PORT_STATE_DIR"
    sudo touch "$PORT_STATE_FILE"

    echo "Which tunnel are these ports for?"
    echo "1 - GRE + IPsec"
    echo "2 - WireGuard + udp2raw"
    read -p "Select: " PF_TUNNEL

    echo "Is this server IRAN or FOREIGN?"
    echo "1 - IRAN   (public entry point; receives inbound traffic and forwards it)"
    echo "2 - FOREIGN (destination; where the real service/app is listening)"
    read -p "Select: " PF_ROLE

    if [[ "$PF_TUNNEL" == "1" ]]; then
        TUN_IFACE="$GRE_NAME"
        [[ "$PF_ROLE" == "1" ]] && { LOCAL_TUN_IP="132.168.30.2"; PEER_TUN_IP="132.168.30.1"; } \
                                 || { LOCAL_TUN_IP="132.168.30.1"; PEER_TUN_IP="132.168.30.2"; }
    elif [[ "$PF_TUNNEL" == "2" ]]; then
        TUN_IFACE="$WG_IFACE"
        [[ "$PF_ROLE" == "1" ]] && { LOCAL_TUN_IP="10.20.30.2"; PEER_TUN_IP="10.20.30.1"; } \
                                 || { LOCAL_TUN_IP="10.20.30.1"; PEER_TUN_IP="10.20.30.2"; }
    else
        echo -e "${RED}[!] Invalid selection.${RESET}"
        exit 1
    fi

    if ! ip link show "$TUN_IFACE" >/dev/null 2>&1; then
        echo -e "${RED}[!] Interface $TUN_IFACE not found. Install that tunnel first (option 1 or 2).${RESET}"
        exit 1
    fi

    ensure_base_forwarding() {
        sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
        if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf >/dev/null
        fi
        if ! sudo iptables -t nat -C POSTROUTING -o "$TUN_IFACE" -j MASQUERADE 2>/dev/null; then
            sudo iptables -t nat -A POSTROUTING -o "$TUN_IFACE" -j MASQUERADE
        fi
    }

    add_port_rule() {
        local proto=$1
        local port=$2
        local tag="vatan-port-${TUN_IFACE}-${proto}-${port}"

        if [[ "$PF_ROLE" == "1" ]]; then
            # IRAN: DNAT public inbound traffic on this port to the FOREIGN tunnel IP
            if ! sudo iptables -t nat -C PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$PEER_TUN_IP:$port" -m comment --comment "$tag" 2>/dev/null; then
                sudo iptables -t nat -A PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$PEER_TUN_IP:$port" -m comment --comment "$tag"
            fi
            if ! sudo iptables -C FORWARD -p "$proto" -d "$PEER_TUN_IP" --dport "$port" -j ACCEPT -m comment --comment "$tag" 2>/dev/null; then
                sudo iptables -A FORWARD -p "$proto" -d "$PEER_TUN_IP" --dport "$port" -j ACCEPT -m comment --comment "$tag"
            fi
        else
            # FOREIGN: make sure inbound on the tunnel interface for this port is allowed
            if ! sudo iptables -C INPUT -i "$TUN_IFACE" -p "$proto" --dport "$port" -j ACCEPT -m comment --comment "$tag" 2>/dev/null; then
                sudo iptables -A INPUT -i "$TUN_IFACE" -p "$proto" --dport "$port" -j ACCEPT -m comment --comment "$tag"
            fi
        fi
        echo "${TUN_IFACE} ${PF_ROLE} ${proto} ${port}" | sudo tee -a "$PORT_STATE_FILE" >/dev/null
        echo -e "${GREEN}[+] Forwarding added: ${proto}/${port} (tunnel=${TUN_IFACE})${RESET}"
    }

    remove_port_rule() {
        local proto=$1
        local port=$2
        local tag="vatan-port-${TUN_IFACE}-${proto}-${port}"

        if [[ "$PF_ROLE" == "1" ]]; then
            sudo iptables -t nat -D PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$PEER_TUN_IP:$port" -m comment --comment "$tag" 2>/dev/null || true
            sudo iptables -D FORWARD -p "$proto" -d "$PEER_TUN_IP" --dport "$port" -j ACCEPT -m comment --comment "$tag" 2>/dev/null || true
        else
            sudo iptables -D INPUT -i "$TUN_IFACE" -p "$proto" --dport "$port" -j ACCEPT -m comment --comment "$tag" 2>/dev/null || true
        fi
        sudo sed -i "\|^${TUN_IFACE} ${PF_ROLE} ${proto} ${port}$|d" "$PORT_STATE_FILE"
        echo -e "${GREEN}[+] Forwarding removed: ${proto}/${port} (tunnel=${TUN_IFACE})${RESET}"
    }

    echo "Action:"
    echo "1 - Add port(s)"
    echo "2 - Remove port(s)"
    echo "3 - List currently forwarded ports"
    read -p "Select: " PF_ACTION

    if [[ "$PF_ACTION" == "3" ]]; then
        echo -e "${CYAN}---- Forwarded ports (${TUN_IFACE}) ----${RESET}"
        grep "^${TUN_IFACE} " "$PORT_STATE_FILE" 2>/dev/null | awk '{print $3"/"$4, ($2==1)?"(IRAN entry)":"(FOREIGN accept)"}' \
            || echo "None configured."
        exit 0
    fi

    read -rp "Enter port(s), comma-separated (e.g. 443,8080,2053): " PORT_LIST
    # strip anything that isn't a digit or comma (handles pasted invisible/
    # non-UTF8 characters that break iptables' --dport parser)
    PORT_LIST=$(printf '%s' "$PORT_LIST" | tr -cd '0-9,')

    echo "Protocol:"
    echo "1 - TCP only"
    echo "2 - UDP only"
    echo "3 - Both TCP and UDP"
    read -p "Select: " PROTO_CHOICE

    case "$PROTO_CHOICE" in
        1) PROTOS=("tcp") ;;
        2) PROTOS=("udp") ;;
        3) PROTOS=("tcp" "udp") ;;
        *) echo -e "${RED}[!] Invalid selection.${RESET}"; exit 1 ;;
    esac

    if [[ "$PF_ACTION" == "1" ]]; then
        ensure_base_forwarding
        install_restore_service
    fi

    IFS=',' read -ra PORTS_ARR <<< "$PORT_LIST"
    for p in "${PORTS_ARR[@]}"; do
        # keep digits only, then validate it's a real port number (1-65535)
        p=$(printf '%s' "$p" | tr -cd '0-9')
        if [[ -z "$p" ]]; then
            continue
        fi
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
            echo -e "${RED}[!] Skipping invalid port: '$p' (must be a number 1-65535)${RESET}"
            continue
        fi
        for proto in "${PROTOS[@]}"; do
            if [[ "$PF_ACTION" == "1" ]]; then
                add_port_rule "$proto" "$p"
            elif [[ "$PF_ACTION" == "2" ]]; then
                remove_port_rule "$proto" "$p"
            else
                echo -e "${RED}[!] Invalid action.${RESET}"
                exit 1
            fi
        done
    done

    echo -e "${GREEN}[i] A systemd service (vatan-restore-ports) now reapplies these rules automatically after every reboot.${RESET}"
    exit 0
fi

# ============================================================
# UNINSTALL (choose which)
# ============================================================
if [[ "$MAIN_CHOICE" == "4" ]]; then
    echo "Which tunnel do you want to remove?"
    echo "1 - GRE"
    echo "2 - WireGuard + udp2raw"
    echo "3 - Both (but keep port-forward rules)"
    read -p "Select: " UN_CHOICE

    case "$UN_CHOICE" in
        1) remove_gre_tunnel ;;
        2) remove_wg_udp2raw ;;
        3) remove_gre_tunnel; remove_wg_udp2raw ;;
        *) echo -e "${RED}[!] Invalid selection.${RESET}"; exit 1 ;;
    esac
    echo -e "${YELLOW}[i] Port-forward rules (if any) were left in place. Use option 5 or 6 to clean those up too.${RESET}"
    exit 0
fi

# ============================================================
# FULL UNINSTALL - EVERYTHING, ONE CLICK
# ============================================================
if [[ "$MAIN_CHOICE" == "6" ]]; then
    echo -e "${YELLOW}[*] Removing GRE tunnel, WireGuard tunnel, and all port forwards...${RESET}"
    remove_gre_tunnel
    remove_wg_udp2raw
    remove_all_port_forwards
    echo -e "${GREEN}[+] Everything has been removed. The server is back to a clean state.${RESET}"
    exit 0
fi

if [[ "$MAIN_CHOICE" != "1" && "$MAIN_CHOICE" != "2" ]]; then
    echo -e "${RED}[!] Invalid selection.${RESET}"
    exit 1
fi

echo "Select server location:"
echo "1 - IRAN"
echo "2 - FOREIGN"
read -p "Enter 1 or 2: " LOCATION
read -p "Enter IRAN server IP: " IP_IRAN
read -p "Enter FOREIGN server IP: " IP_FOREIGN

# ============================================================
# OPTION 1: GRE tunnel (no built-in encryption — fastest, lowest overhead)
# ============================================================
if [[ "$MAIN_CHOICE" == "1" ]]; then

    sudo mkdir -p "$PORT_STATE_DIR"
    sudo bash -c "cat > $GRE_CONF_FILE" <<EOF
LOCATION=$LOCATION
IP_IRAN=$IP_IRAN
IP_FOREIGN=$IP_FOREIGN
EOF

    install_gre_restore_service() {
        sudo bash -c "cat > $GRE_RESTORE_SCRIPT" <<'GREEOF'
#!/bin/bash
GRE_NAME="vatan-m2"
GRE_CONF_FILE="/etc/vatan-tunnel/gre.conf"
[[ -f "$GRE_CONF_FILE" ]] || exit 0
source "$GRE_CONF_FILE"

# don't recreate if it's already up (e.g. re-run of the unit)
ip link show "$GRE_NAME" >/dev/null 2>&1 && exit 0

sysctl -w net.ipv4.ip_forward=1 >/dev/null

if [[ "$LOCATION" == "1" ]]; then
    ip tunnel add "$GRE_NAME" mode gre local "$IP_IRAN" remote "$IP_FOREIGN" ttl 255
    ip link set "$GRE_NAME" up
    ip addr add 132.168.30.2/30 dev "$GRE_NAME"
    ip link set dev "$GRE_NAME" mtu 1476
    iptables -t nat -C PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2 2>/dev/null || \
        iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2
    iptables -t nat -C PREROUTING -j DNAT --to-destination 132.168.30.1 2>/dev/null || \
        iptables -t nat -A PREROUTING -j DNAT --to-destination 132.168.30.1
    iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -j MASQUERADE
else
    ip tunnel add "$GRE_NAME" mode gre local "$IP_FOREIGN" remote "$IP_IRAN" ttl 255
    ip link set "$GRE_NAME" up
    ip addr add 132.168.30.1/30 dev "$GRE_NAME"
    ip link set dev "$GRE_NAME" mtu 1476
    iptables -C INPUT --proto icmp -j DROP 2>/dev/null || iptables -A INPUT --proto icmp -j DROP
fi
GREEOF
        sudo chmod +x "$GRE_RESTORE_SCRIPT"

        sudo bash -c "cat > $GRE_RESTORE_SERVICE" <<EOF
[Unit]
Description=Vatan GRE tunnel restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$GRE_RESTORE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable vatan-gre-tunnel >/dev/null 2>&1 || true
    }

    if [[ "$LOCATION" == "1" ]]; then
        echo -e "${YELLOW}[*] Running config for IRAN server...${RESET}"
        sudo ip tunnel add "$GRE_NAME" mode gre local "$IP_IRAN" remote "$IP_FOREIGN" ttl 255
        sudo ip link set "$GRE_NAME" up
        sudo ip addr add 132.168.30.2/30 dev "$GRE_NAME"
        sudo ip link set dev "$GRE_NAME" mtu 1476
        sudo sysctl -w net.ipv4.ip_forward=1
        sudo iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2
        sudo iptables -t nat -A PREROUTING -j DNAT --to-destination 132.168.30.1
        sudo iptables -t nat -A POSTROUTING -j MASQUERADE

    elif [[ "$LOCATION" == "2" ]]; then
        echo -e "${YELLOW}[*] Running config for FOREIGN server...${RESET}"
        sudo ip tunnel add "$GRE_NAME" mode gre local "$IP_FOREIGN" remote "$IP_IRAN" ttl 255
        sudo ip link set "$GRE_NAME" up
        sudo ip addr add 132.168.30.1/30 dev "$GRE_NAME"
        sudo ip link set dev "$GRE_NAME" mtu 1476
        sudo iptables -A INPUT --proto icmp -j DROP
    else
        echo -e "${RED}[!] Invalid selection.${RESET}"
        exit 1
    fi

    install_gre_restore_service

    echo -e "${GREEN}[+] Done. GRE tunnel is up (no encryption — max speed) and will auto-restore on reboot.${RESET}"
    echo -e "${CYAN}[i] Check status with option 3.${RESET}"
    echo -e "${YELLOW}[i] Note: this tunnel is unencrypted. Traffic pattern/metadata is visible on the wire (content is plaintext). If you need encryption without the earlier IPsec slowdown, use option 2 (WireGuard) — it's lighter than AES-GCM/IPsec in software and still obfuscated via udp2raw.${RESET}"
fi

# ============================================================
# OPTION 2: WireGuard + udp2raw
# ============================================================
if [[ "$MAIN_CHOICE" == "2" ]]; then

    echo -e "${YELLOW}[*] Installing WireGuard tools if not present...${RESET}"
    if ! command -v wg >/dev/null 2>&1; then
        safe_apt_install wireguard wireguard-tools
    fi

    echo -e "${YELLOW}[*] Tuning kernel network buffers for higher throughput...${RESET}"
    if ! grep -q "vatan-tunnel buffer tuning" /etc/sysctl.conf 2>/dev/null; then
        sudo bash -c "cat >> /etc/sysctl.conf" <<'EOF'

# >>> vatan-tunnel buffer tuning
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=4194304
net.core.wmem_default=4194304
net.ipv4.udp_mem=1000000 2000000 4000000
# <<< vatan-tunnel buffer tuning
EOF
        sudo sysctl -p >/dev/null 2>&1 || true
    fi

    if ! command -v "$UDP2RAW_BIN" >/dev/null 2>&1 && [[ ! -f "$UDP2RAW_BIN" ]]; then
        echo -e "${YELLOW}[*] Downloading udp2raw...${RESET}"
        cd /tmp
        curl -fL -o udp2raw.tar.gz \
            "https://github.com/wangyu-/udp2raw/releases/latest/download/udp2raw_binaries.tar.gz"
        tar -xzf udp2raw.tar.gz
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) BIN_NAME="udp2raw_amd64" ;;
            aarch64) BIN_NAME="udp2raw_arm" ;;
            *) BIN_NAME="udp2raw_amd64" ;;
        esac
        sudo cp "$BIN_NAME" "$UDP2RAW_BIN"
        sudo chmod +x "$UDP2RAW_BIN"
    fi

    read -s -p "Enter a shared password for udp2raw obfuscation (same on both servers): " RAW_PASS
    echo ""
    [[ -z "$RAW_PASS" ]] && { echo -e "${RED}[!] Password cannot be empty.${RESET}"; exit 1; }

    if [[ "$LOCATION" == "1" ]]; then
        WG_LOCAL_TUNNEL_IP="10.20.30.2/30"
        ROLE="client"   # IRAN side connects out through udp2raw client -> FOREIGN
    else
        WG_LOCAL_TUNNEL_IP="10.20.30.1/30"
        ROLE="server"   # FOREIGN side is the udp2raw server (public exposed port)
    fi

    # Default fixed keypairs so both servers auto-match without manual copy/paste.
    # IMPORTANT: these must be TWO DIFFERENT identities (one per role) — using the
    # SAME keypair on both ends makes WireGuard peer with itself, which breaks
    # routing ("Required key not available", bogus sub-ms "pings" that never
    # actually leave the box). Each role gets its own fixed keypair below.
    # WARNING: these pairs are embedded in the script itself, so they are NOT
    # secret if you share/publish this script — anyone with a copy can connect
    # to your tunnel. Fine for a private, non-distributed script; if you publish
    # this on GitHub, choose option "2" below to generate unique keys instead.
    IRAN_DEFAULT_PRIVKEY="CA8Pti8UCmYC3LmNANz/QwpXoF4uOOJNvbgW/Ci0wkk="
    IRAN_DEFAULT_PUBKEY="SElEikHNWRlLX/uDX8cZC/qurO7zxv4Lb0vXjK4HTkI="
    FOREIGN_DEFAULT_PRIVKEY="ANU54l5vsKYNWkQMkgx41DR4cFtcFdiH3YqEkWmypWI="
    FOREIGN_DEFAULT_PUBKEY="/4Wl4ndBdIYCBrJ9OsBwahqHg7AwDndwLJuZZFy/X0I="

    echo "Key mode:"
    echo "1 - Use built-in default keypairs (no copy/paste needed, both servers auto-match)"
    echo "2 - Generate a unique random keypair for this install (more secure, requires manual exchange)"
    read -p "Select [1-2]: " KEY_MODE

    if [[ "$KEY_MODE" == "2" ]]; then
        umask 077
        wg genkey | sudo tee /etc/wireguard/privatekey >/dev/null
        sudo cat /etc/wireguard/privatekey | wg pubkey | sudo tee /etc/wireguard/publickey >/dev/null
        PRIVKEY=$(sudo cat /etc/wireguard/privatekey)
        PUBKEY=$(sudo cat /etc/wireguard/publickey)
        echo -e "${CYAN}[i] Your WireGuard public key: ${PUBKEY}${RESET}"
        echo -e "${YELLOW}[!] You'll need the OTHER server's public key to finish peering.${RESET}"
        read -p "Enter the PEER's WireGuard public key: " PEER_PUBKEY
    else
        sudo mkdir -p /etc/wireguard
        umask 077
        if [[ "$ROLE" == "client" ]]; then
            # IRAN uses the IRAN identity, peers with the FOREIGN identity
            PRIVKEY="$IRAN_DEFAULT_PRIVKEY"
            PUBKEY="$IRAN_DEFAULT_PUBKEY"
            PEER_PUBKEY="$FOREIGN_DEFAULT_PUBKEY"
        else
            # FOREIGN uses the FOREIGN identity, peers with the IRAN identity
            PRIVKEY="$FOREIGN_DEFAULT_PRIVKEY"
            PUBKEY="$FOREIGN_DEFAULT_PUBKEY"
            PEER_PUBKEY="$IRAN_DEFAULT_PUBKEY"
        fi
        echo "$PRIVKEY" | sudo tee /etc/wireguard/privatekey >/dev/null
        echo "$PUBKEY" | sudo tee /etc/wireguard/publickey >/dev/null
        echo -e "${CYAN}[i] Using built-in default keypair for the ${ROLE} role (no manual key exchange needed).${RESET}"
    fi

    sudo mkdir -p /etc/wireguard
    if [[ "$ROLE" == "client" ]]; then
        # IRAN: WireGuard must send its traffic to udp2raw's OWN local relay port,
        # which is DIFFERENT from WireGuard's own ListenPort (they can't share a
        # port — that's what caused "socket bind error" before).
        sudo bash -c "cat > $WG_CONF" <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = $WG_LOCAL_TUNNEL_IP
ListenPort = $WG_LISTEN_PORT
MTU = 1350

[Peer]
PublicKey = $PEER_PUBKEY
AllowedIPs = 10.20.30.0/30
Endpoint = 127.0.0.1:$WG_UDP2RAW_LOCAL_PORT
PersistentKeepalive = 15
EOF
    else
        # FOREIGN: no static Endpoint — it just waits and learns the peer's
        # address dynamically from the first packet udp2raw relays to it
        # locally. Setting one here would just point WireGuard at itself.
        sudo bash -c "cat > $WG_CONF" <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = $WG_LOCAL_TUNNEL_IP
ListenPort = $WG_LISTEN_PORT
MTU = 1350

[Peer]
PublicKey = $PEER_PUBKEY
AllowedIPs = 10.20.30.0/30
PersistentKeepalive = 15
EOF
    fi

    sudo systemctl enable wg-quick@"$WG_IFACE" 2>/dev/null || true
    sudo wg-quick up "$WG_IFACE" || sudo systemctl restart wg-quick@"$WG_IFACE"

    if [[ "$ROLE" == "server" ]]; then
        # FOREIGN: public-facing udp2raw server, forwards raw traffic to local WireGuard port
        sudo bash -c "cat > $UDP2RAW_SERVICE" <<EOF
[Unit]
Description=udp2raw server (vatan tunnel)
After=network.target

[Service]
ExecStart=$UDP2RAW_BIN -s -l0.0.0.0:${UDP2RAW_PORT} -r127.0.0.1:${WG_LISTEN_PORT} -k "$RAW_PASS" --raw-mode faketcp --cipher-mode none --auth-mode none --sock-buf 4096 -a
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    else
        # IRAN: udp2raw client dials out to FOREIGN's public raw port
        sudo bash -c "cat > $UDP2RAW_SERVICE" <<EOF
[Unit]
Description=udp2raw client (vatan tunnel)
After=network.target

[Service]
ExecStart=$UDP2RAW_BIN -c -l127.0.0.1:${WG_UDP2RAW_LOCAL_PORT} -r${IP_FOREIGN}:${UDP2RAW_PORT} -k "$RAW_PASS" --raw-mode faketcp --cipher-mode none --auth-mode none --sock-buf 4096 -a
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable udp2raw-vatan
    sudo systemctl restart udp2raw-vatan

    echo -e "${GREEN}[+] WireGuard + udp2raw configured.${RESET}"
    echo -e "${CYAN}[i] Note: run this script on BOTH servers, exchanging public keys, before the tunnel comes fully up.${RESET}"
    echo -e "${CYAN}[i] Check status with option 3.${RESET}"
fi
