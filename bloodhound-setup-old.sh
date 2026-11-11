#!/usr/bin/env bash
# ==============================================================================
# BloodHound Community Edition (CE) Auto-Setup Script
#
# Official Documentation:
#   https://bloodhound.specterops.io/get-started/quickstart/community-edition-quickstart
# GitHub Repository:
#   https://github.com/SpecterOps/bloodhound-cli
#
# Description:
#   - Verifies and installs all system prerequisites (Docker, Docker Compose v2,
#     wget, curl, tar, xdg-utils, and hardware checks).
#   - Downloads and extracts BloodHound CLI via:
#       wget https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/bloodhound-cli-linux-amd64.tar.gz
#       tar -xvzf bloodhound-cli-linux-amd64.tar.gz
#   - Cleans up temporary archives and stale symlinks.
#   - Creates system links in /usr/local/bin and /usr/bin for:
#       * bloodhound-cli  (CLI administration & container management)
#       * bloodhound-gui  (Graphical interface launcher & browser opener)
#       * bloodhound      (Unified command for both CLI and GUI)
#   - Asks the user: "Do you want graphical install?", and if confirmed,
#     proceeds to execute './bloodhound-cli install' to deploy the Web UI.
# ==============================================================================
set -euo pipefail

# ---------- Color & Logging Helpers ----------
C_RESET='\033[0m'
C_BLUE='\033[1;34m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_CYAN='\033[1;36m'

log()  { printf "${C_BLUE}[*]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[+]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*"; }
die()  { printf "${C_RED}[x]${C_RESET} %s\n" "$*" >&2; exit 1; }

# ---------- Command Line Arguments ----------
AUTO_YES=false
INSTALL_DIR="/opt/bloodhound-cli"

for arg in "$@"; do
  case "$arg" in
    -y|--yes)
      AUTO_YES=true
      shift
      ;;
    -h|--help)
      echo "Usage: sudo $0 [-y|--yes] [-h|--help]"
      echo
      echo "Options:"
      echo "  -y, --yes    Non-interactive mode (automatically answer yes to all prompts)"
      echo "  -h, --help   Show this help message"
      exit 0
      ;;
  esac
done

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

# Detect non-root invoking user (for permissions, Docker group, and home configs)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
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
  ok "CPU Cores: ${CPU_CORES} (meets recommendation)"
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
  COMPOSE_INSTALLED=false
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y docker-compose-plugin 2>/dev/null && COMPOSE_INSTALLED=true || true
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

ok "All prerequisites installed and verified successfully!"

# ---------- Download & Extract BloodHound CLI ----------
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

BH_TARBALL="bloodhound-cli-linux-${BH_ARCH}.tar.gz"
BH_URL="https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/${BH_TARBALL}"

log "Downloading BloodHound CLI (${BH_ARCH}) from:"
echo "    $BH_URL"

# Remove any old archive before downloading
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
ok "Archive cleaned up successfully"

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
  echo "[!] Docker is not currently running. Attempting to start service..."
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

# 4. Optional Desktop application shortcut (for GUI desktop environments like Kali / Ubuntu)
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

  echo
  ok "BloodHound CE Graphical Installation completed successfully!"
  echo
  echo -e "${C_GREEN}──────────────────────────────────────────────────────────────────────${C_RESET}"
  echo "  Access the BloodHound Graphical Web UI at:"
  echo -e "    ${C_CYAN}http://127.0.0.1:8080/ui/login${C_RESET}"
  echo
  echo "  Retrieve your initial generated administrator password anytime with:"
  echo -e "    ${C_YELLOW}bloodhound-cli config get default_password${C_RESET}"
  echo
  echo "  Terminal commands accessible from ANYWHERE:"
  echo "    bloodhound-gui         # Launch Graphical Web UI in browser"
  echo "    bloodhound-cli         # Execute BloodHound CLI commands"
  echo "    bloodhound             # Unified command (runs GUI or CLI)"
  echo
  echo "  Useful container management commands:"
  echo "    bloodhound-cli up      # Start BloodHound containers"
  echo "    bloodhound-cli down    # Stop BloodHound containers"
  echo "    bloodhound-cli logs    # Inspect container service logs"
  echo "    bloodhound-cli running # View status of running services"
  echo -e "${C_GREEN}──────────────────────────────────────────────────────────────────────${C_RESET}"
  echo

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
  echo "When you are ready to proceed with the graphical install, simply run:"
  echo "    bloodhound-cli install"
  echo "or launch the GUI helper directly:"
  echo "    bloodhound-gui"
  echo
fi
