#!/bin/bash
# macOS bash 3.2; also supports: curl -fsSL <url> | bash
set -uo pipefail

dry_run=${ORION_INSTALLER_DRY_RUN:-0}
check=${ORION_INSTALLER_CHECK:-0}
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        --check) check=1 ;;
        *) printf '✗ Unknown option: %s. Next: use --dry-run or --check.\n' "$arg"; exit 1 ;;
    esac
done
log_path="$HOME/orion-installer.log"
logging=0
report=''
all_good=1
step='Read installer configuration'
next='Download a fresh copy of the installer and try again.'

redact() {
    local line
    local sed_buffer=-u
    [ "$(uname -s)" != Darwin ] || sed_buffer=-l
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "${ORION_OS_UPDATE_TOKEN:-}" ]; then line=${line//"$ORION_OS_UPDATE_TOKEN"/[REDACTED]}; fi
        printf '%s\n' "$line"
    done | sed "$sed_buffer" -E \
        -e 's#(https?://)[^/[:space:]@]+@#\1[REDACTED]@#g' \
        -e 's/(gh[pousr]_[[:alnum:]_]+|github_pat_[[:alnum:]_]+|sk-[[:alnum:]_-]+)/[REDACTED]/g' \
        -e 's/([Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Aa]uthorization|[Bb]earer)([ :=]+)[^[:space:]]+/\1\2[REDACTED]/g'
}
say() {
    local safe
    safe=$(printf '%s\n' "$*" | redact)
    printf '%s\n' "$safe"
    if [ "$logging" = 1 ]; then printf '%s\n' "$safe" >> "$log_path"
    else report="$report$safe
"; fi
}
note() { say "→ $*"; }
mark() {
    if [ "$1" = 1 ]; then say "✓ $2"; else say "✗ $2"; all_good=0; fi
}
start_log() {
    if [ "$dry_run" != 1 ] && [ "$check" != 1 ] && [ "$logging" != 1 ]; then
        if (umask 077; printf '%s' "$report" > "$log_path"); then logging=1; fi
    fi
}
fail() {
    local code=${3:-1}
    start_log
    say "✗ $step failed. $1"
    note "$2"
    if [ "$logging" = 1 ]; then note "Log: $log_path"; fi
    exit "$code"
}
ask() {
    [ "${ORION_INSTALLER_YES:-0}" = 1 ] && return 0
    local answer
    printf '%s ' "$1"
    [ "$logging" != 1 ] || printf '%s\n' "$1" >> "$log_path"
    if [ -t 0 ]; then IFS= read -r answer || fail 'No answer was available.' 'Run in Terminal or set ORION_INSTALLER_YES=1.'
    else IFS= read -r answer < /dev/tty || fail 'No console was available.' 'Run in Terminal or set ORION_INSTALLER_YES=1.'; fi
    case "$answer" in ''|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}
has() { command -v "$1" >/dev/null 2>&1; }
# Children of curl | bash must not consume the remaining installer source as input.
# Reconnect interactive setup/auth to the controlling terminal when one exists.
with_console() {
    if [ -t 0 ]; then "$@"
    elif (: < /dev/tty) 2>/dev/null; then "$@" < /dev/tty
    else "$@" < /dev/null; fi
}
run() {
    # Native tools retain their stdin (for authentication and post-clone setup).
    with_console "$@" 2>&1 | redact | tee -a "$log_path"
    local code=${PIPESTATUS[0]}
    [ "$code" -eq 0 ] || fail 'The command could not complete; access, connectivity, or a dependency may be missing.' "$next" "$code"
}
run_interactive() {
    printf '%s\n' "$step started" | redact >> "$log_path"
    local code=0
    with_console "$@" || code=$?
    printf '%s\n' "$step finished, exit code $code" | redact >> "$log_path"
    [ "$code" -eq 0 ] || fail 'The command could not complete; access, connectivity, or a dependency may be missing.' "$next" "$code"
}
plan() { local rendered; printf -v rendered '%q ' "$@"; note "$rendered"; }
python_ok() {
    if has uv; then
        uv python find --no-python-downloads 3.10 >/dev/null 2>&1 && return 0
        uv python find --no-python-downloads '>=3.10' >/dev/null 2>&1 && return 0
    fi
    local py
    for py in python3 python; do
        if [ "$(command -v "$py")" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
        if has "$py" && "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

if [ "$(uname -s)" != Darwin ]; then
    step='OS check'
    fail 'This installer is for macOS only.' 'On Windows, use installer/install.ps1.'
fi

# JXA is supplied by macOS, so parsing JSON needs neither Node nor Python.
# Keep this pure JavaScript parser testable with Node on non-macOS hosts.
config_parser=$(cat <<'JAVASCRIPT'
function run(argv) {
    var c = JSON.parse(argv[0]);
    var keys = ['product_name', 'repo_url', 'ref', 'install_dir_name', 'profile'];
    keys.forEach(function(k) {
        if (typeof c[k] !== 'string' || !c[k].trim() || /[\r\n]/.test(c[k])) throw Error('Invalid configuration field: ' + k);
    });
    if (!Array.isArray(c.layers)) throw Error('layers must be an array');
    if (/[\/\\]/.test(c.install_dir_name) || c.install_dir_name === '.' || c.install_dir_name === '..') throw Error('Invalid install_dir_name');
    if (!/^https:\/\/[^\s\/@?#]+\//.test(c.repo_url) || /[@?#]/.test(c.repo_url)) throw Error('repo_url must be HTTPS without credentials or query parameters');
    if (/^-/.test(c.ref)) throw Error('Invalid repository ref');
    return keys.map(function(k) { return c[k]; }).concat([JSON.stringify(c.layers)]).join('\n');
}
JAVASCRIPT
)
# Only the offline fallback contains product identity; keep it in sync with JSON.
defaults='{"product_name":"Orion-OS","repo_url":"https://github.com/AnvlJLL/orion-os.git","ref":"main","install_dir_name":"orion-os","profile":"default","layers":[]}'
json=''
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [ -f "$script_dir/installer.json" ]; then json=$(cat "$script_dir/installer.json"); fi
fi
if [ -z "$json" ] && [ -n "${ORION_INSTALLER_BASE_URL:-}" ]; then
    json=$(curl -fsSL --connect-timeout 5 --max-time 10 "${ORION_INSTALLER_BASE_URL%/}/installer.json" 2>/dev/null) || json=''
fi
if [ -z "$json" ]; then note 'installer.json unavailable; using embedded defaults.'; json=$defaults; fi
config=$(osascript -l JavaScript -e "$config_parser" "$json" 2>/dev/null) || fail 'installer.json is invalid.' 'Correct installer.json or download a fresh copy.'
{
    IFS= read -r product_name
    IFS= read -r repo_url
    IFS= read -r ref
    IFS= read -r install_dir_name
    IFS= read -r profile
    IFS= read -r layers
} <<< "$config"
# profile/layers are carried in config; the existing post-clone flow owns setup.
: "$profile" "$layers"
install_dir=${ORION_INSTALL_DIR:-"$HOME/$install_dir_name"}
case "$install_dir" in /*) ;; *) install_dir="$PWD/$install_dir" ;; esac
note "$product_name installer - $ref"
mark 1 "OS: macOS $(sw_vers -productVersion)"
online=0; curl -fsSI --connect-timeout 5 --max-time 8 https://github.com >/dev/null 2>&1 && online=1
mark "$online" 'Internet: github.com'
# Discover an existing Homebrew even in a new shell whose PATH has not loaded it.
if ! has brew; then
    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$brew_bin" ]; then export PATH="$(dirname "$brew_bin"):$PATH"; break; fi
    done
fi
brew_ok=0; has brew && brew_ok=1; mark "$brew_ok" 'Package manager: Homebrew (installable)'
git_ok=0
# Apple's /usr/bin/git shim can open the developer-tools installer; a pre-flight
# must not trigger that installation before consent.
if [ "$(command -v git)" != /usr/bin/git ] || xcode-select -p >/dev/null 2>&1; then
    git --version >/dev/null 2>&1 && git_ok=1
fi
mark "$git_ok" 'git'
node_version=$(node --version 2>/dev/null) || node_version=''
node_major=${node_version#v}; node_major=${node_major%%.*}
node_ok=0
case "$node_major" in ''|*[!0-9]*) ;; *) [ "$node_major" -ge 20 ] && node_ok=1 ;; esac
mark "$node_ok" "Node (20 or newer): $node_version"
uv_ok=0; uv --version >/dev/null 2>&1 && uv_ok=1; mark "$uv_ok" 'uv'
py_ok=0; python_ok && py_ok=1; mark "$py_ok" 'Python (3.10 or newer)'
claude_ok=0; claude --version >/dev/null 2>&1 && claude_ok=1; mark "$claude_ok" 'Claude Code'
disk_path=$install_dir
while [ ! -e "$disk_path" ] && [ "$disk_path" != / ]; do disk_path=$(dirname "$disk_path"); done
free_kb=$(df -Pk "$disk_path" 2>/dev/null | awk 'NR==2 {print $4}')
disk_ok=0
case "$free_kb" in ''|*[!0-9]*) ;; *) [ "$free_kb" -ge 2097152 ] && disk_ok=1 ;; esac
mark "$disk_ok" 'Free disk space: at least 2 GB'
exists=0; reuse=0; directory_ok=1
if [ -e "$install_dir" ] || [ -L "$install_dir" ]; then
    exists=1
    if [ "$git_ok" = 1 ] && [ -e "$install_dir/.git" ]; then
        origin=$(git -C "$install_dir" remote get-url origin 2>/dev/null) || origin=''
        [ "${origin%/}" = "${repo_url%/}" ] && reuse=1
    fi
    if [ "$reuse" = 1 ]; then mark 1 "Install directory: matching clone, will resume at $install_dir"
    else directory_ok=0; mark 0 "Install directory: already exists and is not a matching clone: $install_dir"; fi
else mark 1 "Install directory: available at $install_dir"; fi
missing=()
[ "$brew_ok" = 1 ] || missing+=('Homebrew')
[ "$git_ok" = 1 ] || missing+=('Git')
[ "$node_ok" = 1 ] || missing+=('Node')
[ "$uv_ok" = 1 ] || missing+=('uv')
[ "$py_ok" = 1 ] || missing+=('Python 3.12 (side by side)')
[ "$claude_ok" = 1 ] || missing+=('Claude Code')
list='nothing'
if [ "${#missing[@]}" -gt 0 ]; then printf -v list '%s, ' "${missing[@]}"; list=${list%, }; fi
say "I will install: $list. Nothing else on your computer will change."
if [ "$check" = 1 ]; then [ "$all_good" = 1 ] && exit 0; exit 1; fi
if [ "$dry_run" = 1 ]; then
    [ "$directory_ok" = 1 ] || note 'Blocked: choose an empty install directory; no commands will run.'
    [ "$brew_ok" = 1 ] || note '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" (may ask for your Mac password)'
    [ "$git_ok" = 1 ] || plan brew install git
    if [ "$node_ok" != 1 ]; then
        [ -z "$node_version" ] || note 'Ask permission before upgrading existing Node.'
        if [ -n "$node_version" ] && brew list --versions node >/dev/null 2>&1; then plan brew upgrade node; else plan brew install node; fi
    fi
    [ "$uv_ok" = 1 ] || plan brew install uv
    [ "$py_ok" = 1 ] || plan uv python install 3.12
    [ "$claude_ok" = 1 ] || note 'curl -fsSL https://claude.ai/install.sh | bash'
    if [ "$exists" != 1 ]; then
        plan git clone --branch "$ref" "$repo_url" "$install_dir"
        note 'Only if GitHub authentication fails:'
        has gh || plan brew install gh
        plan gh auth login --web --git-protocol https
        plan gh auth setup-git
        plan git clone --branch "$ref" "$repo_url" "$install_dir"
    fi
    note "In $install_dir: bash scripts/orion-bootstrap.sh"
    plan open -a Terminal "$install_dir"
    note 'Type claude in the new Terminal window.'
    exit 0
fi
start_log
[ "$logging" = 1 ] || fail 'The log file could not be written.' 'Make your home directory writable and rerun.'
step='Pre-flight check'
[ "$directory_ok" = 1 ] || fail 'The install path is occupied or its origin could not be verified; it has not been touched.' 'Set ORION_INSTALL_DIR to a new empty path and rerun.'
[ "$online" = 1 ] || fail 'GitHub could not be reached.' 'Connect to the internet and rerun.'
[ "$disk_ok" = 1 ] || fail 'The target drive needs at least 2 GB free.' 'Free 2 GB on the target drive and rerun.'
ask 'Continue? [Y/n]' || { note 'Cancelled; no dependencies or install files changed.'; exit 0; }
if [ -n "$node_version" ] && [ "$node_ok" != 1 ]; then
    note "You have Node $node_version; $product_name needs 20 or newer. Upgrading may affect other programs that use Node."
    ask 'Upgrade now? [Y/n]' || fail 'The existing Node version is too old.' 'Install Node 20 or newer yourself, then rerun.'
fi
if [ "$brew_ok" != 1 ]; then
    step='Install Homebrew'; next='Run the official installer at https://brew.sh, then rerun.'
    note 'Installing Homebrew; it may ask for your Mac password.'
    brew_script=$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh) || fail 'The Homebrew installer could not be downloaded.' "$next"
    run_interactive /bin/bash -c "$brew_script"
    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$brew_bin" ]; then export PATH="$(dirname "$brew_bin"):$PATH"; break; fi
    done
fi
step='Install dependencies'; next='Run brew doctor, resolve its reported issue, then rerun.'
[ "$git_ok" = 1 ] || run brew install git
if [ "$node_ok" != 1 ]; then
    if [ -n "$node_version" ] && brew list --versions node >/dev/null 2>&1; then run brew upgrade node; else run brew install node; fi
    # A version manager may still shadow Homebrew Node; use the installed binary
    # for this session only. Do not rewrite the user's shell configuration.
    brew_prefix=$(brew --prefix) || fail 'Homebrew did not report its location.' "$next"
    export PATH="$brew_prefix/bin:$PATH"
fi
[ "$uv_ok" = 1 ] || run brew install uv
if [ "$py_ok" != 1 ]; then
    step='Install Python 3.12 alongside system Python'; next='Run uv python install 3.12, then rerun.'
    run uv python install 3.12
fi
if [ "$claude_ok" != 1 ]; then
    step='Install Claude Code'; next='Run curl -fsSL https://claude.ai/install.sh | bash, then rerun.'
    claude_script=$(curl -fsSL https://claude.ai/install.sh) || fail 'The Claude Code installer could not be downloaded.' "$next"
    run bash -c "$claude_script"
    export PATH="$HOME/.local/bin:$PATH"
fi
hash -r
step='Verify dependencies'; next='Open a new Terminal window and rerun the installer.'
if ! git --version >/dev/null 2>&1 || ! uv --version >/dev/null 2>&1 || ! python_ok || ! claude --version >/dev/null 2>&1; then
    fail 'An installed tool is not available on PATH yet.' "$next"
fi
node_version=$(node --version 2>/dev/null) || node_version=''
node_major=${node_version#v}; node_major=${node_major%%.*}
case "$node_major" in ''|*[!0-9]*) fail 'Node 20 or newer is not available.' "$next" ;; esac
[ "$node_major" -ge 20 ] || fail 'An older Node still takes precedence on PATH.' 'Open Terminal with Node 20 or newer on PATH, then rerun.'
if [ "$reuse" != 1 ]; then
    # Probe access without a terminal prompt: a bare git clone would ask for a
    # username/password, which GitHub rejects, and strand a first-time user.
    if ! GIT_TERMINAL_PROMPT=0 git ls-remote "$repo_url" HEAD >/dev/null 2>&1; then
        note 'A browser window will open to sign in to GitHub. This happens once.'
        step='Sign in to GitHub'; next='Run gh auth login --web --git-protocol https in Terminal, then rerun.'
        has gh || run brew install gh
        run_interactive gh auth login --web --git-protocol https
        run_interactive gh auth setup-git
        GIT_TERMINAL_PROMPT=0 git ls-remote "$repo_url" HEAD >/dev/null 2>&1 \
            || fail 'GitHub sign-in worked but this account cannot see the repository.' 'Accept the repository invitation in GitHub (check your email), then rerun.'
    fi
    step='Download the code'; next='Accept the repository invitation in GitHub, then rerun.'
    run_interactive env GIT_TERMINAL_PROMPT=0 git clone --branch "$ref" "$repo_url" "$install_dir"
fi
step='Run post-clone setup'; next='Rerun this installer to resume post-clone setup.'
cd "$install_dir" || fail 'The install directory could not be opened.' "$next"
run_interactive bash scripts/orion-bootstrap.sh
note "Done. Opening Claude Code in $install_dir - type hello to begin."
step='Open Terminal'; next="Open Terminal in $install_dir and type claude."
run open -a Terminal "$install_dir"
note 'Type claude in the new Terminal window, then type hello.'
