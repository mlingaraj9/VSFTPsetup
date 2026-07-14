#!/usr/bin/env bash
#
# setup_camera_ftp.sh
# Automated vsftpd camera-upload server setup for Ubuntu / Raspberry Pi OS.
# Runs each step sequentially, reports OK / FAIL / SKIP per step, and prints
# a final summary. Idempotent: safe to re-run.
#
# Usage:   sudo ./setup_camera_ftp.sh
# Options: sudo ./setup_camera_ftp.sh --subnet 192.168.44.0/24 --pasv-addr 192.168.44.10
#
set -u

# ---------------------------------------------------------------------------
# Config (override via CLI flags)
# ---------------------------------------------------------------------------
# Directory this script lives in (the git repo checkout) -- used to deploy
# xml_forwarder.py and config.json that sit next to this script.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FTP_USER="cameraftp"
UPLOAD_DIR="/home/${FTP_USER}/upload"
PROCESSED_DIR="${UPLOAD_DIR}/_processed"
FORWARDER_DIR="/home/${FTP_USER}/XML_FORWARDER"
FORWARDER_LOG="/var/log/xml_forwarder.log"
SERVICE_FILE="/etc/systemd/system/xml_forwarder.service"
VSFTPD_CONF="/etc/vsftpd.conf"
CAMERA_SUBNET="192.168.44.0/24"
PASV_MIN=40000
PASV_MAX=40100
PASV_ADDRESS=""          # auto-detected if left empty
CONFIGURE_UFW="ask"      # ask | yes | no

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subnet)    CAMERA_SUBNET="$2"; shift 2 ;;
        --pasv-addr) PASV_ADDRESS="$2"; shift 2 ;;
        --ufw)       CONFIGURE_UFW="$2"; shift 2 ;;   # yes|no
        --user)      FTP_USER="$2"
                     UPLOAD_DIR="/home/${FTP_USER}/upload"
                     PROCESSED_DIR="${UPLOAD_DIR}/_processed"
                     FORWARDER_DIR="/home/${FTP_USER}/XML_FORWARDER"
                     shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -12; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
declare -a RESULTS

step_banner() { echo -e "\n${BLUE}==> STEP $1: $2${NC}"; }
ok()   { echo -e "    ${GREEN}[ OK ]${NC} $1";   RESULTS+=("OK   | $1");  ((PASS_COUNT++)); }
fail() { echo -e "    ${RED}[FAIL]${NC} $1";     RESULTS+=("FAIL | $1");  ((FAIL_COUNT++)); }
skip() { echo -e "    ${YELLOW}[SKIP]${NC} $1";  RESULTS+=("SKIP | $1");  ((SKIP_COUNT++)); }
info() { echo -e "    ${YELLOW}[INFO]${NC} $1"; }

run() {
    # run "description" cmd args...
    local desc="$1"; shift
    if output=$("$@" 2>&1); then
        ok "$desc"
        return 0
    else
        fail "$desc"
        echo "$output" | sed 's/^/           /'
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Step 0: Preconditions
# ---------------------------------------------------------------------------
step_banner 0 "Preconditions"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root: sudo $0${NC}"
    exit 1
fi
ok "Running as root"

if command -v apt-get >/dev/null 2>&1; then
    ok "apt-based system detected"
else
    fail "apt-get not found (this script targets Ubuntu / Raspberry Pi OS)"
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    ok "python3 present ($(python3 --version 2>&1))"
else
    info "python3 not found -- not fatal for FTP setup, but the forwarder will need it"
fi

# Auto-detect PASV address if not supplied
if [[ -z "$PASV_ADDRESS" ]]; then
    PASV_ADDRESS=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    if [[ -n "$PASV_ADDRESS" ]]; then
        ok "Auto-detected local IP for pasv_address: ${PASV_ADDRESS}"
    else
        info "Could not auto-detect local IP; pasv_address will be left blank"
    fi
fi

# ---------------------------------------------------------------------------
# Step 1: Base system check (static IP is informational only)
# ---------------------------------------------------------------------------
step_banner 1 "Base system"
ok "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"
info "Verify this host has a static/reserved IP on the camera LAN (${CAMERA_SUBNET})"

# ---------------------------------------------------------------------------
# Step 2: Install vsftpd
# ---------------------------------------------------------------------------
step_banner 2 "vsftpd installation"
if dpkg -s vsftpd >/dev/null 2>&1; then
    skip "vsftpd already installed ($(dpkg -s vsftpd | awk '/^Version/{print $2}'))"
else
    run "apt update" apt-get update -qq
    run "apt install vsftpd" apt-get install -y -qq vsftpd
fi

# ---------------------------------------------------------------------------
# Step 3: FTP user
# ---------------------------------------------------------------------------
step_banner 3 "FTP user creation (${FTP_USER})"
if id "$FTP_USER" >/dev/null 2>&1; then
    skip "User ${FTP_USER} already exists"
else
    if run "useradd ${FTP_USER}" useradd -m -s /bin/bash "$FTP_USER"; then
        echo -e "    ${YELLOW}Set a password for ${FTP_USER}:${NC}"
        if passwd "$FTP_USER"; then
            ok "Password set for ${FTP_USER}"
        else
            fail "Password not set for ${FTP_USER} (run: sudo passwd ${FTP_USER})"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: Directory structure
# ---------------------------------------------------------------------------
step_banner 4 "Directory structure"
run "mkdir -p ${UPLOAD_DIR}"     mkdir -p "$UPLOAD_DIR"
run "mkdir -p ${PROCESSED_DIR}"  mkdir -p "$PROCESSED_DIR"
run "chown -R ${FTP_USER}:${FTP_USER} /home/${FTP_USER}" chown -R "${FTP_USER}:${FTP_USER}" "/home/${FTP_USER}"
run "chmod 755 /home/${FTP_USER}" chmod 755 "/home/${FTP_USER}"
run "chmod 775 upload dirs"      chmod 775 "$UPLOAD_DIR" "$PROCESSED_DIR"

# ---------------------------------------------------------------------------
# Step 5: vsftpd configuration
# ---------------------------------------------------------------------------
step_banner 5 "vsftpd configuration (${VSFTPD_CONF})"

if [[ -f "$VSFTPD_CONF" ]]; then
    BACKUP="${VSFTPD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    run "Backup existing config -> ${BACKUP}" cp "$VSFTPD_CONF" "$BACKUP"
fi

if cat > "$VSFTPD_CONF" <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=YES
local_root=${UPLOAD_DIR}
pasv_enable=YES
pasv_min_port=${PASV_MIN}
pasv_max_port=${PASV_MAX}
pasv_address=${PASV_ADDRESS}
use_localtime=YES
xferlog_enable=YES
log_ftp_protocol=YES
EOF
then
    ok "Wrote ${VSFTPD_CONF}"
else
    fail "Could not write ${VSFTPD_CONF}"
fi

run "systemctl restart vsftpd" systemctl restart vsftpd
run "systemctl enable vsftpd"  systemctl enable vsftpd

if systemctl is-active --quiet vsftpd; then
    ok "vsftpd service is active"
else
    fail "vsftpd is not running -- check: journalctl -u vsftpd -n 30"
fi

# Confirm port 21 is listening
if ss -ltn 2>/dev/null | grep -q ':21 '; then
    ok "vsftpd listening on port 21"
else
    fail "Nothing listening on port 21"
fi

# ---------------------------------------------------------------------------
# Step 6: Firewall (UFW, optional)
# ---------------------------------------------------------------------------
step_banner 6 "Firewall (UFW)"
if ! command -v ufw >/dev/null 2>&1; then
    skip "ufw not installed -- skipping firewall rules"
else
    DO_UFW="no"
    case "$CONFIGURE_UFW" in
        yes) DO_UFW="yes" ;;
        no)  DO_UFW="no" ;;
        ask)
            read -rp "    Configure UFW rules for ${CAMERA_SUBNET}? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] && DO_UFW="yes"
            ;;
    esac
    if [[ "$DO_UFW" == "yes" ]]; then
        run "Allow FTP control (21/tcp) from ${CAMERA_SUBNET}" \
            ufw allow from "$CAMERA_SUBNET" to any port 21 proto tcp
        run "Allow PASV range (${PASV_MIN}:${PASV_MAX}/tcp) from ${CAMERA_SUBNET}" \
            ufw allow from "$CAMERA_SUBNET" to any port "${PASV_MIN}:${PASV_MAX}" proto tcp
    else
        skip "UFW rule configuration skipped"
    fi
fi

# ---------------------------------------------------------------------------
# Step 7: Validate FTP upload (local loopback test)
# ---------------------------------------------------------------------------
step_banner 7 "FTP validation"
if [[ ! -f /var/log/vsftpd.log ]]; then
    touch /var/log/vsftpd.log && ok "Created /var/log/vsftpd.log" || info "vsftpd.log will appear after first transfer"
else
    ok "/var/log/vsftpd.log exists"
fi
info "Live-watch transfers with: sudo tail -f /var/log/vsftpd.log"
info "Manual test from another host: ftp ${PASV_ADDRESS:-<this-host-ip>} (user: ${FTP_USER})"

# ---------------------------------------------------------------------------
# Step 8: XML forwarder directory
# ---------------------------------------------------------------------------
step_banner 8 "XML forwarder directory"
run "mkdir -p ${FORWARDER_DIR}" mkdir -p "$FORWARDER_DIR"
run "chown -R ${FTP_USER}:${FTP_USER} ${FORWARDER_DIR}" chown -R "${FTP_USER}:${FTP_USER}" "$FORWARDER_DIR"

# ---------------------------------------------------------------------------
# Step 9: Python dependencies
# ---------------------------------------------------------------------------
step_banner 9 "Python dependencies (requests, pytz)"
if command -v pip3 >/dev/null 2>&1; then
    run "pip3 install requests pytz" pip3 install requests pytz --break-system-packages
else
    fail "pip3 not found -- install dependencies manually"
fi

# Verify the modules actually import
for mod in requests pytz; do
    if python3 -c "import ${mod}" 2>/dev/null; then
        ok "python3 can import ${mod}"
    else
        fail "python3 cannot import ${mod}"
    fi
done

# ---------------------------------------------------------------------------
# Step 10: Log file setup
# ---------------------------------------------------------------------------
step_banner 10 "Log file setup (${FORWARDER_LOG})"
run "touch ${FORWARDER_LOG}"  touch "$FORWARDER_LOG"
run "chown ${FTP_USER}:${FTP_USER} ${FORWARDER_LOG}" chown "${FTP_USER}:${FTP_USER}" "$FORWARDER_LOG"
run "chmod 664 ${FORWARDER_LOG}" chmod 664 "$FORWARDER_LOG"

# ---------------------------------------------------------------------------
# Step 11: Deploy forwarder files from repo (xml_forwarder.py, config.json)
# ---------------------------------------------------------------------------
step_banner 11 "Deploy forwarder files from ${REPO_DIR}"

FORWARDER_SCRIPT="${FORWARDER_DIR}/xml_forwarder.py"
FORWARDER_CONFIG="${FORWARDER_DIR}/config.json"

if [[ -f "${REPO_DIR}/xml_forwarder.py" ]]; then
    run "Copy xml_forwarder.py -> ${FORWARDER_DIR}" \
        install -o "$FTP_USER" -g "$FTP_USER" -m 755 \
        "${REPO_DIR}/xml_forwarder.py" "$FORWARDER_SCRIPT"
else
    fail "xml_forwarder.py not found in ${REPO_DIR}"
fi

if [[ -f "${REPO_DIR}/config.json" ]]; then
    if [[ -f "$FORWARDER_CONFIG" ]]; then
        CFG_BACKUP="${FORWARDER_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        run "Backup existing config.json -> ${CFG_BACKUP}" cp "$FORWARDER_CONFIG" "$CFG_BACKUP"
    fi
    run "Copy config.json -> ${FORWARDER_DIR}" \
        install -o "$FTP_USER" -g "$FTP_USER" -m 644 \
        "${REPO_DIR}/config.json" "$FORWARDER_CONFIG"
    # Validate it is real JSON before letting the service loose on it
    if python3 -c "import json; json.load(open('${FORWARDER_CONFIG}'))" 2>/dev/null; then
        ok "config.json is valid JSON"
    else
        fail "config.json is NOT valid JSON -- service will crash-loop until fixed"
    fi
else
    fail "config.json not found in ${REPO_DIR}"
fi

# ---------------------------------------------------------------------------
# Step 12: systemd service (xml_forwarder.service)
# ---------------------------------------------------------------------------
step_banner 12 "systemd service (${SERVICE_FILE})"

if [[ -f "$SERVICE_FILE" ]]; then
    SVC_BACKUP="${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    run "Backup existing unit -> ${SVC_BACKUP}" cp "$SERVICE_FILE" "$SVC_BACKUP"
fi

if cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XML Forwarder (FTP XML -> JSON -> HTTP endpoints)
After=network.target

[Service]
User=${FTP_USER}
Group=${FTP_USER}
ExecStart=/usr/bin/python3 ${FORWARDER_SCRIPT}
Restart=always
RestartSec=5
WorkingDirectory=${FORWARDER_DIR}

[Install]
WantedBy=multi-user.target
EOF
then
    ok "Wrote ${SERVICE_FILE}"
else
    fail "Could not write ${SERVICE_FILE}"
fi

run "systemctl daemon-reload" systemctl daemon-reload

# Enable BOTH services for boot persistence
run "systemctl enable vsftpd (start on boot)" systemctl enable vsftpd
run "systemctl enable xml_forwarder (start on boot)" systemctl enable xml_forwarder.service

if [[ -f "$FORWARDER_SCRIPT" && -f "$FORWARDER_CONFIG" ]]; then
    run "systemctl restart xml_forwarder.service" systemctl restart xml_forwarder.service
    sleep 2
    if systemctl is-active --quiet xml_forwarder.service; then
        ok "xml_forwarder.service is active"
    else
        fail "xml_forwarder.service failed to stay running -- check: journalctl -u xml_forwarder -n 30"
    fi
else
    skip "Service NOT started: forwarder files missing (see Step 11 failures)"
fi

info "Watch FTP traffic:      sudo tail -f /var/log/vsftpd.log"
info "Watch forwarder:        sudo tail -f ${FORWARDER_LOG}"
info "Service status:         systemctl status xml_forwarder vsftpd"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "\n${BLUE}================= SUMMARY =================${NC}"
for r in "${RESULTS[@]}"; do
    case "$r" in
        OK*)   echo -e "  ${GREEN}${r}${NC}" ;;
        FAIL*) echo -e "  ${RED}${r}${NC}" ;;
        SKIP*) echo -e "  ${YELLOW}${r}${NC}" ;;
    esac
done
echo -e "${BLUE}-------------------------------------------${NC}"
echo -e "  ${GREEN}Passed: ${PASS_COUNT}${NC}   ${RED}Failed: ${FAIL_COUNT}${NC}   ${YELLOW}Skipped: ${SKIP_COUNT}${NC}"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "\n${RED}Setup completed WITH ERRORS. Review the FAIL items above.${NC}"
    exit 1
else
    echo -e "\n${GREEN}Setup completed successfully.${NC}"
    echo "Point the camera's FTP target at ${PASV_ADDRESS:-<this-host-ip>}:21, user '${FTP_USER}'."
    exit 0
fi
