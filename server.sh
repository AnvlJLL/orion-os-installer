#!/usr/bin/env bash
# Standalone bootstrap: also works when bash reads this file from a curl pipe.
set +x
set -euo pipefail
umask 077

TEMPLATE=/opt/orion-os-template
ADMIN_CONFIG=/root/.config/orion
ADMIN_LOG=/var/log/orion-admin.log
REPO_URL=https://github.com/AnvlJLL/orion-os.git
LOG_READY=0

say() {
    printf '%s\n' "$*"
    if [[ $LOG_READY == 1 ]]; then printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$ADMIN_LOG"; fi
}
die() { say "✗ $*" >&2; exit 1; }
root_only() { [[ $EUID == 0 ]] || die 'Run this command as root (sudo).'; }
admin_lock() {
    [[ ! -L /run/orion-admin ]] || die 'Unsafe admin lock directory.'
    install -d -o root -g root -m 700 /run/orion-admin
    exec 9>"/run/orion-admin/$1.lock"
    flock -n 9 || die 'Another admin operation is running.'
}
open_tty() { exec 3<>/dev/tty || die 'An interactive terminal is required.'; }
ask() { printf '%s ' "$1" >&3; IFS= read -r REPLY <&3 || REPLY=''; }
yes_answer() { [[ $REPLY == y || $REPLY == Y ]]; }
init_log() {
    [[ ! -L $ADMIN_LOG ]] || die 'Admin log must not be a symlink.'
    touch "$ADMIN_LOG"
    chown root:root "$ADMIN_LOG"
    chmod 600 "$ADMIN_LOG"
    LOG_READY=1
}
# Never execute root code from a writable mirror (including its Git hooks).
trusted_mirror() {
    [[ -d $TEMPLATE/.git && ! -L $TEMPLATE ]] || die 'Missing or symlinked template mirror; run server setup.'
    [[ $(stat -c %u /opt) == 0 && $(stat -c %a /opt) =~ ^[1357]?[0145][0145]$ ]] || die '/opt must be root-owned and not writable by others.'
    [[ -z $(find "$TEMPLATE" \( ! -user root -o -perm /022 \) -print -quit) ]] || die 'Template must be root-owned and not writable by businesses.'
}
write_askpass() {
    [[ ! -L $ADMIN_CONFIG && ! -L /root/.config ]] || die 'Unsafe root config path.'
    install -d -m 700 "$ADMIN_CONFIG"
    chown root:root "$ADMIN_CONFIG"
    [[ ! -L $ADMIN_CONFIG/github-token && ! -L $ADMIN_CONFIG/git-askpass ]] || die 'Unsafe credential path.'
    cat > "$ADMIN_CONFIG/git-askpass" <<'EOF'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' x-access-token ;;
    *Password*) cat /root/.config/orion/github-token ;;
    *) exit 1 ;;
esac
EOF
    chmod 700 "$ADMIN_CONFIG/git-askpass"
}
read_token() {
    say '→ Create a fine-grained token at https://github.com/settings/personal-access-tokens/new'
    say '→ Resource owner: AnvlJLL; Only select repositories: AnvlJLL/orion-os; Repository permissions: Contents: Read-only (Metadata: Read-only is automatic). No other permissions.'
    printf 'GitHub read token (hidden; Enter keeps an existing token): ' >&3
    local token
    IFS= read -rs token <&3 || token=''
    printf '\n' >&3
    if [[ -n $token ]]; then
        [[ $token =~ ^[A-Za-z0-9_]+$ ]] || die 'Invalid token format.'
        printf '%s\n' "$token" > "$ADMIN_CONFIG/github-token"
        unset token
    fi
    [[ -s $ADMIN_CONFIG/github-token ]] || die 'A single-repo read token is required.'
    chmod 600 "$ADMIN_CONFIG/github-token"
    chown root:root "$ADMIN_CONFIG/github-token"
}
mirror_git() {
    # Never pass tokens to git, credential helpers, remotes, or a logging pipe.
    GIT_ASKPASS="$ADMIN_CONFIG/git-askpass" GIT_TERMINAL_PROMPT=0 \
      git -c credential.helper= -c core.hooksPath=/dev/null "$@" >/dev/null 2>&1
}
refresh_template() {
    [[ -s $ADMIN_CONFIG/github-token ]] || die 'Root read token missing; rerun server setup.'
    if [[ -e $TEMPLATE || -L $TEMPLATE ]]; then
        trusted_mirror
        [[ $(git -C "$TEMPLATE" remote get-url origin) == "$REPO_URL" ]] || die 'Template origin must be the credential-free canonical URL.'
        [[ $(git -C "$TEMPLATE" branch --show-current) == main ]] || die 'Template must be on main.'
        [[ -z $(git -C "$TEMPLATE" status --porcelain) ]] || die 'Template has local changes; resolve them before updating.'
        mirror_git -C "$TEMPLATE" pull --ff-only origin main || die 'Template fast-forward failed; check the root read token and network.'
    else
        # A private staging directory makes interrupted clones safely resumable.
        local staging
        staging=$(mktemp -d /opt/.orion-template.XXXXXXXX)
        if ! mirror_git clone --branch main --single-branch "$REPO_URL" "$staging/repo"; then
            rm -rf -- "$staging"
            die 'Template clone failed; check the root read token and network.'
        fi
        mv "$staging/repo" "$TEMPLATE"
        rmdir "$staging"
    fi
    # Root owns this tree already; never assign shared files to a tenant.
    # Existing provisioner installs a weekly plain git pull. Give that root-only
    # invocation the same askpass, without persisting any token in Git config.
    git -C "$TEMPLATE" config core.askPass "$ADMIN_CONFIG/git-askpass"
    git -C "$TEMPLATE" config credential.helper ''
    # file:// transport crosses uid boundaries. Trust exactly this root-owned
    # mirror for upload-pack; never use safe.directory=* or tenant repositories.
    local safe_path
    for safe_path in "$TEMPLATE" "$TEMPLATE/.git"; do
        if ! git config --system --get-all safe.directory | grep -Fxq "$safe_path"; then
            (umask 022; git config --system --add safe.directory "$safe_path")
        fi
    done
    # Git's atomic config writes can inherit umask 077. Normalize readability
    # only after all mirror writes, without exposing the root credential folder.
    chmod -R a+rX,go-w "$TEMPLATE"
    say '✓ Template mirror is current (main).'
}
tailscale_ssh_connected() {
    # ss omits the state column when a state filter is supplied: peer is field 4.
    ss -tnH state established '( sport = :22 )' | python3 -c '
import ipaddress, sys
network = ipaddress.ip_network("100.64.0.0/10")
found = False
for line in sys.stdin:
    fields = line.split()
    if len(fields) < 4:
        continue
    try:
        peer = ipaddress.ip_address(fields[3].rsplit(":", 1)[0].strip("[]"))
        if isinstance(peer, ipaddress.IPv6Address):
            peer = peer.ipv4_mapped
        found |= peer is not None and peer in network
    except ValueError:
        pass
sys.exit(0 if found else 1)
'
}
lockdown_ssh() {
    local ip="$1"
    say "→ Tailscale IP: $ip. Open a SECOND terminal and connect: ssh root@$ip"
    ask 'Did the Tailscale login work? [y/N]'
    if yes_answer && tailscale_ssh_connected; then
        ufw allow in on tailscale0 to any port 22 proto tcp
        ufw --force delete allow OpenSSH
        write_askpass
        touch "$ADMIN_CONFIG/ssh-locked"
        say '✓ Removed the public OpenSSH rule; inspect other existing SSH allow rules with ufw status.'
    else
        say '→ Public SSH rules left unchanged; connect over Tailscale first, then run it:'
        say 'sudo ufw allow in on tailscale0 to any port 22 proto tcp && sudo ufw --force delete allow OpenSSH'
    fi
    say '→ Recommendation: after proving SSH key login works, disable password login manually in sshd_config. No password settings were changed.'
}
install_node() {
    apt-get install -y gnupg
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
        gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
    chmod 644 /etc/apt/keyrings/nodesource.gpg
    printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' |
        install -m 644 /dev/stdin /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
}
install_uv() {
    # ensurepip is packaged with python3-venv on supported Debian/Ubuntu releases.
    if ! python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then
        apt-get install -y python3-venv
    fi
    [[ ! -L /opt/orion-tools ]] || die 'Unsafe tools venv.'
    if [[ -e /opt/orion-tools ]]; then
        [[ -z $(find /opt/orion-tools \( ! -user root -o -perm /022 \) -print -quit) ]] || die 'Tools venv must be root-owned and not writable by businesses.'
    fi
    install -d -o root -g root -m 755 /opt/orion-tools
    python3 -m venv /opt/orion-tools
    # PyPI release hashes: https://pypi.org/project/uv/0.12.20/#files
    # Binary-only, dependency-free install; never build unverified source as root.
    /opt/orion-tools/bin/pip --isolated install --index-url https://pypi.org/simple \
        --require-hashes --only-binary=:all: --no-deps -r /dev/stdin <<'EOF'
uv==0.12.20 \
    --hash=sha256:d0837cb0ec80f830198e4a0fe86385e2a8ba8846f066acd243a1c15f4d52ca74 \
    --hash=sha256:af3ea78e4080905ca7d29ec9561c2b86b15b18c6637cb3b80f4f2ac50d891309 \
    --hash=sha256:2734cbacd1485b0489f3e403b7080e253dc749f45c6b0fa163e84b60b3aaf9d0 \
    --hash=sha256:91720e0f00173412106d4b9376512a2a5f6e22e7d1dc5aab825cd183e46ced3e \
    --hash=sha256:17d9accf5c9e208bb6ccb1c8c8a7ec7de1ff865aeb33960452e541b0f37a66fb \
    --hash=sha256:a0facee2578926f0aa91f541f3bc206ceb3173b766fc30a4d1fca2b28cc6602c
EOF
    chmod -R a+rX,go-w /opt/orion-tools
    ln -sfn /opt/orion-tools/bin/uv /usr/local/bin/uv
    ln -sfn /opt/orion-tools/bin/uvx /usr/local/bin/uvx
}
install_tailscale() {
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID:${VERSION_CODENAME:-}" in
        ubuntu:jammy|ubuntu:noble|debian:bookworm) ;;
        *) die 'Unsupported Tailscale apt repository.' ;;
    esac
    curl -fsSL "https://pkgs.tailscale.com/stable/$ID/$VERSION_CODENAME.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/$ID/$VERSION_CODENAME.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
    chmod 644 /usr/share/keyrings/tailscale-archive-keyring.gpg /etc/apt/sources.list.d/tailscale.list
    apt-get update
    apt-get install -y tailscale
}
server_plan() {
    say '→ I will install/change: git tmux ufw fail2ban unattended-upgrades curl ca-certificates sudo python3 cron; Node LTS (only if needed); system-wide uv; security updates; firewall allowing OpenSSH (preserving prior confirmed lockdown); Tailscale login; optional SSH lockdown after a second login; root-only GitHub token; template main mirror; orion admin CLI.'
}
preflight() {
    root_only
    [[ $(uname -s) == Linux ]] || die 'Supported systems: Ubuntu 22.04/24.04 or Debian 12.'
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID:$VERSION_ID" in ubuntu:22.04|ubuntu:24.04|debian:12) ;; *) die 'Supported systems: Ubuntu 22.04/24.04 or Debian 12.' ;; esac
    say "✓ OS: $ID $VERSION_ID; running as root."
    local available ram tool
    available=$(df -Pk /opt | awk 'NR==2 {print $4}')
    [[ $available =~ ^[0-9]+$ && $available -ge 10485760 ]] || die 'At least 10 GB of free disk is required in /opt.'
    ram=$(awk '/MemTotal:/ {printf "%.1f", $2/1048576}' /proc/meminfo)
    say "✓ Free disk ≥ 10 GB; RAM: $ram GiB."
    for tool in tailscale node uv tmux git ufw fail2ban-client; do
        if command -v "$tool" >/dev/null; then say "✓ $tool present"; else say "→ $tool missing"; fi
    done
    if command -v node >/dev/null; then say "→ Node version: $(node --version) (minimum 20)"; fi
    if [[ -d $TEMPLATE ]]; then say '✓ Template exists'; else say '→ Template missing'; fi
    command -v curl >/dev/null || die 'curl is needed for the internet check. Install curl and retry.'
    curl -fsSI --connect-timeout 10 --max-time 20 https://github.com >/dev/null || die 'Internet check failed.'
    say '✓ Internet reachable.'
}
server_main() {
    case "${1:-}" in
        --dry-run) server_plan; say '→ Dry-run: no commands, prompts, writes or network requests.'; return ;;
        --refresh-template) root_only; admin_lock server; init_log; write_askpass; refresh_template; return ;;
        '') ;;
        *) die 'Usage: server.sh [--dry-run]' ;;
    esac
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    preflight
    server_plan
    open_tty
    ask 'Continue? [Y/n]'
    [[ -z $REPLY || $REPLY == y || $REPLY == Y ]] || return 0
    init_log
    # Serialize server mutations; read-only preflight is intentionally before this.
    admin_lock server
    say '→ Installing base packages and security updates.'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git tmux ufw fail2ban unattended-upgrades curl ca-certificates sudo python3 cron
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable --now unattended-upgrades
    systemctl enable --now cron
    say '✓ Unattended security upgrades enabled.'
    local major=0 ip
    if command -v node >/dev/null; then major=$(node -p 'process.versions.node.split(".")[0]'); fi
    if (( major < 20 )); then
        if (( major > 0 )); then
            ask "Node $major is too old. Upgrade to Node LTS? [y/N]"
            yes_answer || die 'Node ≥ 20 is required. No Node upgrade performed.'
        fi
        install_node
    fi
    [[ $(node -p 'Number(process.versions.node.split(".")[0]) >= 20') == true ]] || die 'Node ≥ 20 verification failed.'
    say '✓ Node ≥ 20 ready.'
    install_uv
    chmod a+rx /usr/local/bin/uv /usr/local/bin/uvx
    say '✓ System-wide uv ready.'
    ufw default deny incoming
    ufw default allow outgoing
    if [[ -f $ADMIN_CONFIG/ssh-locked ]]; then
        ufw allow in on tailscale0 to any port 22 proto tcp
    else
        ufw allow OpenSSH
    fi
    # Preserve a nonstandard port used by the current SSH connection as well.
    if [[ ${SSH_CONNECTION:-} =~ [[:space:]]([0-9]+)$ && ${BASH_REMATCH[1]} != 22 ]]; then
        ufw allow "${BASH_REMATCH[1]}/tcp"
        say '→ Kept the current nonstandard SSH port open; review it manually after testing Tailscale.'
    fi
    ufw --force enable
    printf '[sshd]\nenabled = true\nbackend = systemd\n' > /etc/fail2ban/jail.d/orion-sshd.local
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    say '✓ Firewall and fail2ban enabled; existing confirmed SSH lockdown preserved.'
    if ! command -v tailscale >/dev/null; then
        install_tailscale
    fi
    say '→ Open this link on your phone or laptop to approve the server.'
    tailscale up <&3 >&3 2>&3
    ip=$(tailscale ip -4) || die 'No Tailscale IPv4 address.'
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'No usable Tailscale IPv4 address.'
    say "✓ Tailscale: $ip"
    lockdown_ssh "$ip"
    write_askpass
    read_token
    refresh_template
    [[ -f $TEMPLATE/installer/orion ]] || die 'Template main does not contain this installer release yet.'
    install -o root -g root -m 755 "$TEMPLATE/installer/orion" /usr/local/sbin/orion
    say '✓ Server ready. Next: sudo orion add-business <name>'
}
# A pipe has BASH_SOURCE unset; a sourced copy is used by the CLI and offline tests.
if [[ ${BASH_SOURCE[0]:-} == "$0" || -z ${BASH_SOURCE[0]:-} ]]; then server_main "$@"; fi
