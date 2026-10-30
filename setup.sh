#!/usr/bin/env bash
# =============================================================================
#  Debian 13 (trixie) VPS bootstrap
#  - system update + base tools
#  - hostname / timezone
#  - sudo user with SSH keys
#  - SSH hardening (key-only, no root) — only if keys are present (no lockout)
#  - UFW firewall, fail2ban, unattended security upgrades, swap
#  - Docker Engine + Compose plugin from the official Docker repo
#
#  One-liner (run as root):
#    curl -fsSL https://YOUR-URL/setup.sh | bash
#  With a sudo user + key-only SSH later:
#    curl -fsSL https://YOUR-URL/setup.sh | NEW_USER=alice GH_USER=yourgithub SSH_HARDEN=1 bash
#
#  All settings are environment variables (see CONFIG below). Safe to re-run.
# =============================================================================
set -Eeuo pipefail

# ------------------------------- CONFIG -------------------------------------
NEW_USER="${NEW_USER:-}"                  # sudo user to create (empty = skip)
SSH_KEY="${SSH_KEY:-}"                    # public key(s), newline-separated
GH_USER="${GH_USER:-}"                    # also pull keys from github.com/<user>.keys
SSH_PORT="${SSH_PORT:-22}"
SSH_HARDEN="${SSH_HARDEN:-0}"             # 1 = key-only + no root login (needs keys)
HOSTNAME_NEW="${HOSTNAME_NEW:-}"          # empty = keep current
TIMEZONE="${TIMEZONE:-UTC}"
SWAP_SIZE="${SWAP_SIZE:-auto}"            # e.g. 2G | 0 (skip) | auto (= RAM, max 4G)
SUDO_NOPASSWD="${SUDO_NOPASSWD:-1}"       # key-only users have no password
ENABLE_UFW="${ENABLE_UFW:-1}"
UFW_ALLOW="${UFW_ALLOW:-80/tcp 443/tcp}"  # extra ports to open (space-separated)
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-1}"
ENABLE_AUTO_UPDATES="${ENABLE_AUTO_UPDATES:-1}"
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
FORCE="${FORCE:-0}"                       # 1 = run even if not Debian 13
# -----------------------------------------------------------------------------

LOG=/var/log/vps-setup.log
export DEBIAN_FRONTEND=noninteractive

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
step() { echo -e "\n${c_b}${c_g}==>${c_0}${c_b} $*${c_0}"; }
warn() { echo -e "${c_y}[warn]${c_0} $*"; }
die()  { echo -e "${c_r}[error]${c_0} $*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND (see $LOG)"' ERR

[[ $EUID -eq 0 ]] || die "run as root (e.g. pipe into 'sudo bash')"
exec > >(tee -a "$LOG") 2>&1

# ------------------------------ PRE-FLIGHT -----------------------------------
. /etc/os-release
if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]; then
  [[ "$FORCE" == 1 ]] || die "expected Debian 13 (trixie), got ${PRETTY_NAME:-unknown}. Set FORCE=1 to override."
  warn "not Debian 13 — continuing because FORCE=1"
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT > 0 && SSH_PORT < 65536 )) || die "invalid SSH_PORT"
if [[ -n "$NEW_USER" && ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then die "invalid NEW_USER"; fi

# ------------------------------ PACKAGES -------------------------------------
step "Updating system"
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade

step "Installing base packages"
apt-get install -y -q --no-install-recommends \
  ca-certificates curl wget gnupg sudo git vim nano tmux htop jq unzip rsync \
  ncdu bash-completion dnsutils net-tools lsof openssh-server \
  ufw fail2ban python3-systemd unattended-upgrades apt-listchanges \
  $EXTRA_PACKAGES

# --------------------------- HOSTNAME / TIME ---------------------------------
if [[ -n "$HOSTNAME_NEW" ]]; then
  step "Setting hostname: $HOSTNAME_NEW"
  hostnamectl set-hostname "$HOSTNAME_NEW"
  grep -qE "^127\.0\.1\.1\s" /etc/hosts \
    && sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1\t$HOSTNAME_NEW/" /etc/hosts \
    || echo -e "127.0.1.1\t$HOSTNAME_NEW" >> /etc/hosts
fi
step "Setting timezone: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true 2>/dev/null || true

# ------------------------------- USER ----------------------------------------
LOGIN_USER=root
if [[ -n "$NEW_USER" ]]; then
  step "Creating user: $NEW_USER"
  id "$NEW_USER" &>/dev/null || useradd -m -s /bin/bash "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
  if [[ "$SUDO_NOPASSWD" == 1 ]]; then
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$NEW_USER"
    chmod 440 "/etc/sudoers.d/90-$NEW_USER"
    visudo -cf "/etc/sudoers.d/90-$NEW_USER" >/dev/null
  fi
  LOGIN_USER="$NEW_USER"
fi

step "Installing SSH keys for $LOGIN_USER"
HOME_DIR=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
AUTH="$HOME_DIR/.ssh/authorized_keys"
install -d -m 700 -o "$LOGIN_USER" -g "$LOGIN_USER" "$HOME_DIR/.ssh"
touch "$AUTH"
keys=""
[[ -n "$SSH_KEY" ]] && keys+="$SSH_KEY"$'\n'
if [[ -n "$GH_USER" ]]; then
  gh=$(curl -fsSL "https://github.com/$GH_USER.keys" || true)
  [[ -n "$gh" ]] && keys+="$gh"$'\n' || warn "no keys found for GitHub user $GH_USER"
fi
# Most VPS providers inject your key into root — reuse it for the new user.
if [[ "$LOGIN_USER" != root && -s /root/.ssh/authorized_keys ]]; then
  keys+="$(cat /root/.ssh/authorized_keys)"$'\n'
fi
while IFS= read -r k; do
  [[ "$k" =~ ^(ssh-|ecdsa-|sk-) ]] || continue
  grep -qxF "$k" "$AUTH" || echo "$k" >> "$AUTH"
done <<< "$keys"
chown "$LOGIN_USER:$LOGIN_USER" "$AUTH"; chmod 600 "$AUTH"
HAS_KEYS=0; grep -qE '^(ssh-|ecdsa-|sk-)' "$AUTH" && HAS_KEYS=1
[[ $HAS_KEYS == 1 ]] && echo "  $(grep -cE '^(ssh-|ecdsa-|sk-)' "$AUTH") key(s) in $AUTH"

# ------------------------------ FIREWALL -------------------------------------
# Open the (possibly new) SSH port BEFORE touching sshd.
if [[ "$ENABLE_UFW" == 1 ]]; then
  step "Configuring UFW"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "$SSH_PORT/tcp" comment ssh >/dev/null
  for p in $UFW_ALLOW; do ufw allow "$p" >/dev/null; done
  ufw --force enable
  ufw status verbose
fi

# -------------------------------- SSH ----------------------------------------
step "Hardening SSH"
# 00- prefix: sshd uses the first value it sees, so this wins over cloud-init's 50-*.conf
CONF=/etc/ssh/sshd_config.d/00-hardening.conf
{
  echo "# managed by vps-setup"
  echo "Port $SSH_PORT"
  echo "X11Forwarding no"
  echo "MaxAuthTries 4"
  echo "LoginGraceTime 30"
  echo "ClientAliveInterval 300"
  echo "ClientAliveCountMax 2"
  if [[ "$SSH_HARDEN" != 1 ]]; then
    : # leave password / root login settings untouched
  elif [[ $HAS_KEYS == 1 ]]; then
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
    echo "PubkeyAuthentication yes"
    if [[ "$LOGIN_USER" != root ]]; then
      echo "PermitRootLogin no"
    else
      echo "PermitRootLogin prohibit-password"
    fi
  else
    warn "No SSH keys installed — leaving password login ENABLED to avoid lockout."
  fi
} > "$CONF"
sshd -t
if systemctl is-active --quiet ssh.socket; then   # socket activation ignores Port
  systemctl disable --now ssh.socket
  systemctl enable ssh.service
fi
systemctl restart ssh

# ------------------------------ FAIL2BAN -------------------------------------
if [[ "$ENABLE_FAIL2BAN" == 1 ]]; then
  step "Configuring fail2ban"
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
banaction = ufw

[sshd]
enabled = true
port    = $SSH_PORT
EOF
  [[ "$ENABLE_UFW" == 1 ]] || sed -i '/^banaction/d' /etc/fail2ban/jail.local
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
fi

# -------------------------- AUTO SECURITY UPDATES ----------------------------
if [[ "$ENABLE_AUTO_UPDATES" == 1 ]]; then
  step "Enabling unattended security upgrades"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
fi

# -------------------------------- SWAP ---------------------------------------
if [[ "$SWAP_SIZE" != 0 ]] && ! swapon --show | grep -q .; then
  if [[ "$SWAP_SIZE" == auto ]]; then
    mem_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
    SWAP_SIZE="$(( mem_mb < 4096 ? mem_mb : 4096 ))M"
  fi
  step "Creating ${SWAP_SIZE} swapfile"
  fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE%[MG]}" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  sysctl -q -p /etc/sysctl.d/99-swappiness.conf
fi

# ------------------------------- DOCKER --------------------------------------
if [[ "$INSTALL_DOCKER" == 1 ]]; then
  step "Installing Docker (official repo)"
  for p in docker.io docker-doc docker-compose podman-docker containerd runc; do
    dpkg -s "$p" &>/dev/null && apt-get remove -y -q "$p" || true
  done
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Log rotation so container logs don't fill the disk
  install -d /etc/docker
  [[ -f /etc/docker/daemon.json ]] || cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
  systemctl enable --now docker containerd >/dev/null 2>&1
  systemctl restart docker
  [[ "$LOGIN_USER" != root ]] && usermod -aG docker "$LOGIN_USER"
  docker --version; docker compose version
fi

# ------------------------------- CLEANUP -------------------------------------
apt-get autoremove -y -q >/dev/null
apt-get clean

# ------------------------------- SUMMARY -------------------------------------
IP=$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
step "Done!"
cat <<EOF
  Host:      $(hostname)  ($IP)
  Login:     ssh ${SSH_PORT:+-p $SSH_PORT }${LOGIN_USER}@${IP}
  Password auth: $([[ $SSH_HARDEN == 1 && $HAS_KEYS == 1 ]] && echo disabled || echo "unchanged")
  Root login:    $([[ $SSH_HARDEN == 1 && $HAS_KEYS == 1 && $LOGIN_USER != root ]] && echo disabled || echo "unchanged")
  Firewall:  $([[ $ENABLE_UFW == 1 ]] && echo "ufw on (ssh $SSH_PORT, $UFW_ALLOW)" || echo off)
  Docker:    $([[ $INSTALL_DOCKER == 1 ]] && docker --version | cut -d, -f1 || echo skipped)
  Log:       $LOG

  ${c_y}Keep this session open and test the new login in a second terminal first.${c_0}
  ${c_y}Note: ports published by Docker (-p) bypass UFW. Bind to 127.0.0.1 or use a reverse proxy.${c_0}
EOF
[[ -f /var/run/reboot-required ]] && warn "A reboot is required (kernel update): run 'reboot'"
exit 0
