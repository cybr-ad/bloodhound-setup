#!/usr/bin/env bash
# ==============================================================================
# BloodHound Community Edition (CE) Auto-Setup & Management Script
#
# Official Documentation:
#   https://bloodhound.specterops.io/get-started/quickstart/community-edition-quickstart
# GitHub Repository:
#   https://github.com/SpecterOps/bloodhound-cli
#
# Description:
#   - Verifies and installs all system prerequisites (Docker, Docker Compose v2,
#     wget, curl, tar, xdg-utils, hardware resources, and port checks).
#   - Downloads and extracts BloodHound CLI via:
#       wget https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/bloodhound-cli-linux-amd64.tar.gz
#       tar -xvzf bloodhound-cli-linux-amd64.tar.gz
#   - Cleans up temporary archives and stale symlinks.
#   - Creates system links in /usr/local/bin and /usr/bin for:
#       * bloodhound-cli  (CLI administration & container management)
#       * bloodhound-gui  (Graphical interface launcher & browser opener)
#       * bloodhound      (Unified command for both CLI and GUI)
#   - Asks user: "You want graphical install?", and if confirmed,
#     proceeds to execute './bloodhound-cli install' to deploy the Web UI.
#   - Displays an interactive usage guide with practical example commands.
#   - Supports '--uninstall' to completely remove BloodHound, containers,
#     database volumes, configurations, and system links from the system.
# ==============================================================================
set -euo pipefail

# ---------- Color & Logging Helpers ----------
C_RESET='\033[0m'
C_BLUE='\033[1;34m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_CYAN='\033[1;36m'
C_BOLD='\033[1m'

log()  { printf "${C_BLUE}[*]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[+]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*"; }
die()  { printf "${C_RED}[x]${C_RESET} %s\n" "$*" >&2; exit 1; }

INSTALL_DIR="/opt/bloodhound-cli"
AUTO_YES=false
ACTION="install"

# Detect non-root invoking user (for permissions, Docker group, and home configs)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# ---------- Parse Command Line Arguments ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      AUTO_YES=true
      shift
      ;;
    -u|--uninstall)
      ACTION="uninstall"
      shift
      ;;
    -s|--status)
      ACTION="status"
      shift
      ;;
    -h|--help)
      echo -e "${C_BOLD}BloodHound Community Edition (CE) Setup & Management Script${C_RESET}"
      echo
      echo -e "Official Quickstart: ${C_CYAN}https://bloodhound.specterops.io/get-started/quickstart/community-edition-quickstart${C_RESET}"
      echo
      echo -e "${C_BOLD}Usage:${C_RESET} sudo $0 [OPTIONS]"
      echo
      echo -e "${C_BOLD}Options:${C_RESET}"
      echo "  -y, --yes          Non-interactive mode (automatically confirm all prompts)"
      echo "  -u, --uninstall    Completely remove BloodHound CE, containers, volumes, configs & links"
      echo "  -s, --status       Check the status of BloodHound CE containers, services, and URL"
      echo "  -h, --help         Show this help message and exit"
      echo
      echo -e "${C_BOLD}Examples:${C_RESET}"
      echo "  sudo $0                 # Standard interactive installation"
      echo "  sudo $0 -y              # Unattended / non-interactive installation"
      echo "  sudo $0 --status        # Check service health and credentials"
      echo "  sudo $0 --uninstall     # Full removal of BloodHound CE"
      exit 0
      ;;
    *)
      warn "Unknown option: $1 (use --help to see available options)"
      shift
      ;;
  esac
done

# ==============================================================================
# FUNCTION: Complete Uninstallation
# ==============================================================================
do_uninstall() {
  echo -e "${C_RED}"
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║             BLOODHOUND CE COMPLETE UNINSTALLATION                    ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo -e "${C_RESET}"

  if [[ $EUID -ne 0 ]]; then
    die "Uninstallation requires root privileges. Please run with sudo: sudo $0 --uninstall"
  fi

  warn "This will completely remove BloodHound CE from your system:"
  echo "  1. Stop and remove all BloodHound Docker containers"
  echo "  2. Permanently delete all database volumes (Neo4j, PostgreSQL, data)"
  echo "  3. Remove installation directory: $INSTALL_DIR"
  echo "  4. Remove system symlinks (/usr/local/bin/bloodhound* & /usr/bin/bloodhound*)"
  echo "  5. Remove user configuration files (~/.config/bloodhound)"
  echo "  6. Remove desktop application shortcuts"
  echo

  if [[ "$AUTO_YES" != "true" ]]; then
    read -r -p "Are you sure you want to completely uninstall BloodHound CE? [y/N]: " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]; then
      log "Uninstallation aborted by user. Nothing was removed."
      exit 0
    fi
  fi

  log "Stopping and tearing down BloodHound containers..."
  if command -v bloodhound-cli &>/dev/null; then
    bloodhound-cli down -v 2>/dev/null || bloodhound-cli down 2>/dev/null || true
  fi

  # Stop and remove any matching containers
  CONTAINERS=$(docker ps -a --format '{{.ID}} {{.Names}}' 2>/dev/null | grep -E "bloodhound|neo4j|postgres" | awk '{print $1}' || true)
  if [[ -n "$CONTAINERS" ]]; then
    log "Removing lingering BloodHound containers..."
    docker rm -f $CONTAINERS 2>/dev/null || true
    ok "Containers removed"
  fi

  # Remove Docker volumes associated with BloodHound
  VOLUMES=$(docker volume ls -q 2>/dev/null | grep -E "bloodhound" || true)
  if [[ -n "$VOLUMES" ]]; then
    log "Removing BloodHound Docker persistent volumes..."
    docker volume rm -f $VOLUMES 2>/dev/null || true
    ok "Docker volumes removed"
  fi

  # Remove custom network if still present
  docker network rm bloodhound_default 2>/dev/null || true

  # Remove binary installation directory
  if [[ -d "$INSTALL_DIR" ]]; then
    log "Removing installation directory ($INSTALL_DIR)..."
    rm -rf "$INSTALL_DIR"
    ok "Directory removed: $INSTALL_DIR"
  fi

  # Remove system links and wrappers
  log "Removing system commands and symlinks..."
  rm -f /usr/local/bin/bloodhound-cli /usr/bin/bloodhound-cli
  rm -f /usr/local/bin/bloodhound-gui /usr/bin/bloodhound-gui
  rm -f /usr/local/bin/bloodhound /usr/bin/bloodhound
  ok "System links removed"

  # Remove desktop shortcuts
  log "Removing desktop application shortcuts..."
  rm -f /usr/share/applications/bloodhound.desktop
  rm -f "$REAL_HOME/Desktop/bloodhound.desktop"
  ok "Desktop shortcuts removed"

  # Remove configuration directories
  log "Removing configuration directories..."
  rm -rf /root/.config/bloodhound
  rm -rf "$REAL_HOME/.config/bloodhound"
  ok "Configurations removed (~/.config/bloodhound)"

  echo
  ok "BloodHound CE has been completely uninstalled from your system."
  echo "Docker Engine and other system packages remain untouched."
  exit 0
}

# ==============================================================================
# FUNCTION: Status Check
# ==============================================================================
do_status() {
  echo -e "${C_CYAN}"
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║                  BLOODHOUND CE STATUS CHECK                          ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo -e "${C_RESET}"

  if ! command -v docker &>/dev/null; then
    die "Docker is not installed on this system."
  fi

  if ! docker info &>/dev/null; then
    warn "Docker daemon is not running."
  else
    ok "Docker daemon is running: $(docker --version)"
  fi

  echo
  log "Checking container status:"
  BH_CONTAINERS=$(docker ps -a --filter "name=bloodhound" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)
  if [[ -n "$BH_CONTAINERS" && "$BH_CONTAINERS" != *"NAMES"* ]]; then
    echo "$BH_CONTAINERS"
  else
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E "bloodhound|neo4j|postgres" || warn "No BloodHound containers found."
  fi

  echo
  log "Checking Web UI endpoint (http://127.0.0.1:8080)..."
  if curl -s -I -m 3 http://127.0.0.1:8080/ui/login 2>/dev/null | grep -q "200\|302\|301"; then
    ok "BloodHound Web UI is reachable at: http://127.0.0.1:8080/ui/login"
  else
    warn "BloodHound Web UI is not reachable on port 8080."
    echo "  Start containers with: bloodhound-cli up"
  fi

  echo
  log "Stored Admin Password:"
  if command -v bloodhound-cli &>/dev/null; then
    PWD_VAL=$(bloodhound-cli config get default_password 2>/dev/null || true)
    if [[ -n "$PWD_VAL" ]]; then
      echo -e "  Username : ${C_BOLD}admin${C_RESET}"
      echo -e "  Password : ${C_YELLOW}${PWD_VAL}${C_RESET}"
    else
      echo "  Password not stored in current user's config (~/.config/bloodhound)."
    fi
  else
    warn "bloodhound-cli binary not found in PATH."
  fi
  exit 0
}

# ==============================================================================
# FUNCTION: Post-Installation Usage & Example Commands Guide
# ==============================================================================
print_usage_guide() {
  local default_pwd="$1"

  echo
  echo -e "${C_GREEN}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_GREEN}║               HOW TO USE BLOODHOUND CE (QUICK GUIDE)                 ║${C_RESET}"
  echo -e "${C_GREEN}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
  echo
  echo -e "${C_BOLD}1. ACCESS THE GRAPHICAL WEB UI${C_RESET}"
  echo "   From any terminal, launch the graphical interface:"
  echo -e "     ${C_CYAN}bloodhound-gui${C_RESET}     # Automatically checks containers & opens browser"
  echo -e "     ${C_CYAN}bloodhound${C_RESET}         # Unified shortcut (opens GUI when run without args)"
  echo
  echo "   Or open in any web browser directly:"
  echo -e "     ${C_CYAN}http://127.0.0.1:8080/ui/login${C_RESET}"
  echo
  echo "   Default Login Credentials:"
  echo -e "     Username : ${C_BOLD}admin${C_RESET}"
  if [[ -n "$default_pwd" ]]; then
    echo -e "     Password : ${C_YELLOW}${default_pwd}${C_RESET}"
  else
    echo -e "     Password : Run '${C_YELLOW}bloodhound-cli config get default_password${C_RESET}'"
  fi
  echo "   (Note: BloodHound will prompt you to change this password on first login)."
  echo
  echo -e "${C_BOLD}2. SERVICE & CONTAINER MANAGEMENT COMMANDS${C_RESET}"
  echo "   Manage your BloodHound instance from ANY terminal directory:"
  echo -e "     ${C_CYAN}bloodhound-cli running${C_RESET}        # Check status of Neo4j, Postgres & App"
  echo -e "     ${C_CYAN}bloodhound-cli logs -f${C_RESET}        # Follow real-time service logs"
  echo -e "     ${C_CYAN}bloodhound-cli up${C_RESET}             # Start BloodHound containers"
  echo -e "     ${C_CYAN}bloodhound-cli down${C_RESET}           # Stop BloodHound containers"
  echo -e "     ${C_CYAN}bloodhound-cli resetpwd${C_RESET}       # Reset administrator password"
  echo
  echo -e "${C_BOLD}3. COLLECTING ACTIVE DIRECTORY & AZURE DATA${C_RESET}"
  echo "   Collect environment data to visualize attack paths:"
  echo
  echo "   [Active Directory with SharpHound (Windows)]"
  echo "     SharpHound.exe -c All --zipfilename DomainData.zip"
  echo
  echo "   [Active Directory with bloodhound-python (Linux)]"
  echo "     bloodhound-python -d domain.local -u user -p 'Pass123' -gc dc.domain.local -c All -ns 10.0.0.1"
  echo
  echo "   [Azure / Microsoft Entra ID with AzureHound]"
  echo "     azurehound -u \"user@tenant.onmicrosoft.com\" -p \"Pass123\" --tenant \"TENANT_ID\" list -o azure.json"
  echo
  echo -e "${C_BOLD}4. INGESTING DATA INTO BLOODHOUND CE${C_RESET}"
  echo "   1. Open the UI at http://127.0.0.1:8080/ui/login"
  echo "   2. Click the 'Administration' gear icon or the Upload icon on the right side."
  echo "   3. Drag and drop your SharpHound .zip or AzureHound .json files into the File Ingest window."
  echo "   4. Once ingestion completes, explore attack paths in the 'Explore' tab."
  echo
  echo -e "${C_BOLD}5. UNINSTALLATION COMMAND${C_RESET}"
  echo "   To completely remove BloodHound, databases, and links at any time:"
  echo -e "     ${C_RED}sudo $0 --uninstall${C_RESET}"
  echo
  echo -e "${C_CYAN}Official Documentation: https://bloodhound.specterops.io/get-started/quickstart/community-edition-quickstart${C_RESET}"
  echo -e "${C_GREEN}──────────────────────────────────────────────────────────────────────${C_RESET}"
  echo
}

# Check if uninstallation was requested
if [[ "$ACTION" == "uninstall" ]]; then
  do_uninstall
fi

# Check if status check was requested
if [[ "$ACTION" == "status" ]]; then
  do_status
fi

# ==============================================================================
# INSTALLATION WORKFLOW
# ==============================================================================
echo -e "${C_CYAN}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║          BloodHound Community Edition (CE) Auto-Setup                ║"
echo "║   Official: https://bloodhound.specterops.io/get-started/quickstart  ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${C_RESET}"

# ---------- Check Root Privileges ----------
if [[ $EUID -ne 0 ]]; then
  die "This script requires root privileges to install system packages and configure Docker. Please run with sudo: sudo $0"
fi

log "Running as root on behalf of user: ${REAL_USER}"

# ---------- Architecture Detection ----------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)   BH_ARCH="amd64" ;;
  aarch64|arm64)  BH_ARCH="arm64" ;;
  *)              die "Unsupported architecture: $ARCH (BloodHound CLI supports amd64 and arm64)" ;;
esac
ok "Architecture detected: $ARCH (using BloodHound CLI binary: ${BH_ARCH})"

# ---------- Hardware Resources Check ----------
# Recommendations per official docs: >= 4 CPU cores, >= 8 GB RAM, >= 10 GB disk
log "Checking hardware resource recommendations..."

CPU_CORES=$(nproc 2>/dev/null || echo 1)
MEM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
DISK_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/[^0-9]/,"",$4); print $4}' || echo 0)

if [[ "$CPU_CORES" -lt 4 ]]; then
  warn "Detected ${CPU_CORES} CPU core(s). BloodHound recommends at least 4 cores for optimal performance."
else
  ok "CPU Cores: ${CPU_CORES} (meets recommendation: >= 4)"
fi

if [[ "$MEM_GB" -lt 8 ]]; then
  warn "Detected only ~${MEM_GB}GB RAM (${MEM_MB}MB). BloodHound CE recommends at least 8GB RAM."
  warn "Low memory can cause Neo4j graph analysis to exit with Out-Of-Memory (exit code 137)."
else
  ok "RAM: ${MEM_GB}GB (meets recommendation: >= 8GB)"
fi

if [[ -n "$DISK_GB" && "$DISK_GB" -lt 10 ]]; then
  warn "Detected only ${DISK_GB}GB free disk space on /. BloodHound recommends at least 10GB free space."
else
  ok "Free Disk Space: ${DISK_GB}GB (meets recommendation: >= 10GB)"
fi

# ---------- Check Port 8080 Availability ----------
log "Checking port 8080 availability..."
PORT_8080_IN_USE=false
if command -v ss &>/dev/null; then
  if ss -tuln 2>/dev/null | grep -q ':8080 '; then
    PORT_8080_IN_USE=true
  fi
elif command -v netstat &>/dev/null; then
  if netstat -tuln 2>/dev/null | grep -q ':8080 '; then
    PORT_8080_IN_USE=true
  fi
fi

if [[ "$PORT_8080_IN_USE" == "true" ]]; then
  warn "Port 8080 is currently occupied by another process!"
  warn "BloodHound CE Web UI binds to 8080 by default. If another service uses it, containers may fail to bind."
else
  ok "Port 8080 is available for BloodHound Web UI"
fi

# ---------- System Package Manager Helper ----------
install_packages() {
  local pkgs=("$@")
  log "Installing required system packages: ${pkgs[*]}..."

  if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y "${pkgs[@]}"
  elif command -v dnf &>/dev/null; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum &>/dev/null; then
    yum install -y "${pkgs[@]}"
  elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm "${pkgs[@]}"
  elif command -v zypper &>/dev/null; then
    zypper --non-interactive install "${pkgs[@]}"
  else
    die "Supported package manager not found (apt-get, dnf, yum, pacman, zypper). Please install ${pkgs[*]} manually."
  fi
}

# ---------- Check Essential Utility Prerequisites ----------
log "Checking essential utility prerequisites (wget, curl, tar, xdg-utils)..."
MISSING_UTILS=()
for util in wget curl tar; do
  if ! command -v "$util" &>/dev/null; then
    MISSING_UTILS+=("$util")
  fi
done

# Check xdg-utils (provides xdg-open for GUI browser launching)
if ! command -v xdg-open &>/dev/null; then
  MISSING_UTILS+=("xdg-utils")
fi

if [[ ${#MISSING_UTILS[@]} -gt 0 ]]; then
  install_packages "${MISSING_UTILS[@]}"
fi
ok "Essential utilities verified (wget, curl, tar, xdg-utils)"

# ---------- Check & Install Docker Engine ----------
log "Checking Docker Engine prerequisite..."
if ! command -v docker &>/dev/null; then
  log "Docker not found. Installing Docker Engine..."
  if command -v apt-get &>/dev/null; then
    install_packages docker.io
  elif command -v dnf &>/dev/null; then
    install_packages docker
  elif command -v pacman &>/dev/null; then
    install_packages docker
  else
    log "Using official Docker automated convenience installer..."
    curl -fsSL https://get.docker.com | sh
  fi
else
  ok "Docker is already installed: $(docker --version)"
fi

# Ensure Docker service is enabled and started
log "Ensuring Docker daemon is active..."
if command -v systemctl &>/dev/null; then
  systemctl enable --now docker 2>/dev/null || true
elif command -v service &>/dev/null; then
  service docker start 2>/dev/null || true
fi

# Verify Docker daemon is responding
if ! docker info &>/dev/null; then
  warn "Docker daemon is not responding immediately. Attempting to start service..."
  systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
  sleep 2
  if ! docker info &>/dev/null; then
    die "Docker daemon failed to start. Please verify your Docker service configuration."
  fi
fi
ok "Docker daemon is active and responding"

# Add invoking user to docker group if not root
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
  if getent group docker &>/dev/null; then
    usermod -aG docker "$REAL_USER" 2>/dev/null || true
    ok "Added user '${REAL_USER}' to the 'docker' group"
  fi
fi

# ---------- Check & Install Docker Compose Plugin (v2) ----------
log "Checking Docker Compose v2 plugin prerequisite..."
if docker compose version &>/dev/null; then
  ok "Docker Compose plugin is active: $(docker compose version --short 2>/dev/null || docker compose version)"
else
  warn "Docker Compose v2 plugin is missing. Installing Docker Compose plugin..."

  # Attempt package manager install first
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y docker-compose-plugin 2>/dev/null || true
  fi

  if ! docker compose version &>/dev/null; then
    log "Downloading Docker Compose plugin directly from official GitHub releases..."
    COMPOSE_ARCH="x86_64"
    [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && COMPOSE_ARCH="aarch64"

    mkdir -p /usr/local/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins
    COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}"

    curl -SL "$COMPOSE_URL" -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    cp -f /usr/local/lib/docker/cli-plugins/docker-compose /usr/libexec/docker/cli-plugins/docker-compose 2>/dev/null || true
  fi

  if docker compose version &>/dev/null; then
    ok "Docker Compose plugin installed successfully: $(docker compose version --short 2>/dev/null || docker compose version)"
  else
    die "Docker Compose v2 plugin could not be verified. Please install the Docker Compose plugin manually."
  fi
fi

ok "All prerequisites verified and installed successfully!"

# ---------- Download & Extract BloodHound CLI ----------
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

BH_TARBALL="bloodhound-cli-linux-${BH_ARCH}.tar.gz"
BH_URL="https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/${BH_TARBALL}"

log "Downloading BloodHound CLI (${BH_ARCH}) via:"
echo "    $BH_URL"

# Remove any previous tarball before downloading
rm -f "$INSTALL_DIR/$BH_TARBALL"

if wget --help 2>&1 | grep -q '\--show-progress'; then
  wget -q --show-progress "$BH_URL" -O "$INSTALL_DIR/$BH_TARBALL"
else
  wget "$BH_URL" -O "$INSTALL_DIR/$BH_TARBALL"
fi
ok "Downloaded $BH_TARBALL"

log "Extracting $BH_TARBALL..."
tar -xvzf "$INSTALL_DIR/$BH_TARBALL" -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/bloodhound-cli"
ok "Extracted BloodHound CLI binary to: $INSTALL_DIR/bloodhound-cli"

# Remove downloaded archive to free up space
log "Removing downloaded archive $BH_TARBALL..."
rm -f "$INSTALL_DIR/$BH_TARBALL"
ok "Cleaned up $BH_TARBALL"

# ---------- Setup System Links (CLI & GUI Commands) ----------
log "Configuring system-wide access so CLI and GUI can be run from ANY terminal directory..."

# Remove any existing or broken symlinks
rm -f /usr/local/bin/bloodhound-cli /usr/bin/bloodhound-cli
rm -f /usr/local/bin/bloodhound-gui /usr/bin/bloodhound-gui
rm -f /usr/local/bin/bloodhound /usr/bin/bloodhound

# 1. System links for bloodhound-cli
ln -sf "$INSTALL_DIR/bloodhound-cli" /usr/local/bin/bloodhound-cli
ln -sf "$INSTALL_DIR/bloodhound-cli" /usr/bin/bloodhound-cli
ok "System link created: 'bloodhound-cli' -> /usr/local/bin/bloodhound-cli"

# 2. System script for bloodhound-gui (opens graphical web UI & handles containers)
cat << 'EOF' > /usr/local/bin/bloodhound-gui
#!/usr/bin/env bash
# ==============================================================================
# BloodHound CE Graphical Interface Launcher
# Official Documentation: https://bloodhound.specterops.io/get-started/quickstart/community-edition-quickstart
# ==============================================================================
UI_URL="http://127.0.0.1:8080/ui/login"

echo "[*] BloodHound Community Edition - Graphical Interface Launcher"

# Check if bloodhound-cli is available
if ! command -v bloodhound-cli &>/dev/null; then
  echo "[x] Error: bloodhound-cli not found in system PATH." >&2
  exit 1
fi

# Check Docker status
if ! docker info &>/dev/null; then
  echo "[!] Docker daemon is not running. Attempting to start service..."
  if command -v systemctl &>/dev/null; then
    sudo systemctl start docker 2>/dev/null || true
  elif command -v service &>/dev/null; then
    sudo service docker start 2>/dev/null || true
  fi
fi

# Check if BloodHound containers are running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "bloodhound|neo4j|postgres"; then
  echo "[*] BloodHound containers are not running."
  read -r -p "Do you want to start BloodHound containers now? [Y/n]: " START_ANSWER
  START_ANSWER="${START_ANSWER:-y}"
  if [[ "$START_ANSWER" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]; then
    echo "[*] Starting containers via bloodhound-cli up..."
    bloodhound-cli up || bloodhound-cli install
  else
    echo "[!] Cannot open graphical UI while containers are stopped."
    echo "    Start them anytime with: bloodhound-cli up"
    exit 1
  fi
fi

echo "[+] BloodHound Web UI URL: $UI_URL"

# Retrieve default admin password if available in configuration
DEFAULT_PWD=$(bloodhound-cli config get default_password 2>/dev/null || true)
if [[ -n "$DEFAULT_PWD" ]]; then
  echo "──────────────────────────────────────────────────────────────"
  echo "  Default Admin Credentials:"
  echo "    Username : admin"
  echo "    Password : $DEFAULT_PWD"
  echo "──────────────────────────────────────────────────────────────"
fi

# Check if a display/GUI environment is available to launch browser
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
  echo "[*] Opening BloodHound Graphical Web UI in default browser..."
  if command -v xdg-open &>/dev/null; then
    xdg-open "$UI_URL" &>/dev/null &
  elif command -v sensible-browser &>/dev/null; then
    sensible-browser "$UI_URL" &>/dev/null &
  elif command -v firefox &>/dev/null; then
    firefox "$UI_URL" &>/dev/null &
  elif command -v google-chrome &>/dev/null; then
    google-chrome "$UI_URL" &>/dev/null &
  elif command -v chromium &>/dev/null; then
    chromium "$UI_URL" &>/dev/null &
  else
    echo "[!] No web browser launcher found. Please open $UI_URL in your browser."
  fi
else
  echo "[*] No active GUI desktop detected (terminal/SSH session)."
  echo "    Open the following URL in a browser on your workstation:"
  echo "    $UI_URL"
fi
EOF
chmod +x /usr/local/bin/bloodhound-gui
ln -sf /usr/local/bin/bloodhound-gui /usr/bin/bloodhound-gui
ok "System link created: 'bloodhound-gui' -> /usr/local/bin/bloodhound-gui"

# 3. Unified 'bloodhound' command wrapper
cat << 'EOF' > /usr/local/bin/bloodhound
#!/usr/bin/env bash
# Unified BloodHound Launcher (CLI or GUI)
if [[ $# -eq 0 ]] || [[ "$1" == "gui" ]] || [[ "$1" == "--gui" ]] || [[ "$1" == "-g" ]] || [[ "$1" == "ui" ]]; then
  exec bloodhound-gui
else
  exec bloodhound-cli "$@"
fi
EOF
chmod +x /usr/local/bin/bloodhound
ln -sf /usr/local/bin/bloodhound /usr/bin/bloodhound
ok "System link created: 'bloodhound' -> /usr/local/bin/bloodhound (unified CLI/GUI launcher)"

# 4. Desktop application shortcut (for GUI desktop environments like Kali / Ubuntu)
mkdir -p /usr/share/applications
cat << 'EOF' > /usr/share/applications/bloodhound.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=BloodHound Community Edition
Comment=BloodHound Active Directory & Azure Attack Path Management
Exec=bloodhound-gui
Icon=bloodhound
Terminal=true
Categories=Security;Network;System;
EOF
chmod 644 /usr/share/applications/bloodhound.desktop

if [[ -d "$REAL_HOME/Desktop" ]]; then
  cp /usr/share/applications/bloodhound.desktop "$REAL_HOME/Desktop/"
  chown "$REAL_USER:$REAL_USER" "$REAL_HOME/Desktop/bloodhound.desktop" 2>/dev/null || true
  chmod +x "$REAL_HOME/Desktop/bloodhound.desktop" 2>/dev/null || true
fi

# ---------- Prompt User for Graphical Install ----------
echo
echo -e "${C_CYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
echo -e "${C_CYAN}                  GRAPHICAL INSTALLATION PROMPT                       ${C_RESET}"
echo -e "${C_CYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
echo "BloodHound Community Edition features a modern Graphical Web UI"
echo "powered by containerized services (Neo4j, PostgreSQL, & BloodHound App)."
echo
echo "Proceeding with graphical install runs: ./bloodhound-cli install"
echo "This will pull container images, set up databases, and generate admin credentials."
echo
echo "Official Quickstart Documentation:"
echo "  https://bloodhound.specterops.io/get-started/quickstart/community-edition-quickstart"
echo -e "${C_CYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
echo

if [[ "$AUTO_YES" == "true" ]]; then
  PROCEED_INSTALL="y"
  log "Auto-confirm mode enabled (-y). Proceeding with graphical install..."
else
  read -r -p "You want graphical install? [Y/n]: " PROCEED_INSTALL
  PROCEED_INSTALL="${PROCEED_INSTALL:-y}"
fi

DEFAULT_GENERATED_PWD=""

if [[ "$PROCEED_INSTALL" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]; then
  log "Proceeding to './bloodhound-cli install'..."
  cd "$INSTALL_DIR"
  ./bloodhound-cli install

  # Sync generated BloodHound configuration to the non-root user's home directory
  if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    if [[ -d "/root/.config/bloodhound" ]]; then
      mkdir -p "$REAL_HOME/.config"
      cp -r /root/.config/bloodhound "$REAL_HOME/.config/"
      chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/bloodhound"
      log "Synchronized BloodHound configuration to: $REAL_HOME/.config/bloodhound"
    fi
  fi

  DEFAULT_GENERATED_PWD=$(bloodhound-cli config get default_password 2>/dev/null || true)
  ok "BloodHound CE Graphical Installation completed successfully!"

  # Print detailed usage guide with example commands
  print_usage_guide "$DEFAULT_GENERATED_PWD"

  # Ask if user wants to open the GUI browser right now (if display exists)
  if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    if [[ "$AUTO_YES" == "true" ]]; then
      OPEN_NOW="y"
    else
      read -r -p "Would you like to open the BloodHound GUI in your browser right now? [Y/n]: " OPEN_NOW
      OPEN_NOW="${OPEN_NOW:-y}"
    fi

    if [[ "$OPEN_NOW" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]; then
      bloodhound-gui
    fi
  fi
else
  warn "Skipped './bloodhound-cli install' container deployment."
  echo
  echo "BloodHound CLI binary and system links have been installed."
  print_usage_guide ""
fi
