#!/bin/bash
# ============================================================
#   HexStrike Smart Installer — v2.2
#   Supports: Ubuntu 20.04+ / Debian / Kali
#   Fixes:
#     - GOPATH/PATH exported before any go install calls
#     - go install uses correct @latest module paths
#     - Binary lookup checks ~/go/bin directly, not just PATH
#     - set -uo pipefail kept but subshell failures don't abort
#     - API key prompt reads from /dev/tty correctly in all cases
#     - keys.env sourced before verify so masked output works
#     - SecretFinder installed as script, not pip package
#     - ParamSpider pip install fixed (correct package name)
#     - Retry mode re-exports Go env before installing tools
#     - getJS binary name is 'getJS' (case-sensitive check added)
#   Added:
#     - --set-key <KEY_NAME>  update a single API key interactively
#     - --set-model           pick AI model from menu or enter custom
# ============================================================
set -uo pipefail
IFS=$'\n\t'

# ─── Colors & Logging ────────────────────────────────────────
RED="\e[31m" GREEN="\e[32m" YELLOW="\e[33m" BLUE="\e[34m"
CYAN="\e[36m" BOLD="\e[1m" DIM="\e[2m" RESET="\e[0m"

LOGFILE="/var/log/hexstrike_install.log"
INSTALL_DIR="$HOME/.hexstrike"
CONFIG_FILE="$INSTALL_DIR/configs/keys.env"
FAILED_TOOLS=()
INSTALLED_TOOLS=()

# FIX: Go env set at top level; use existing if available
if command -v go &>/dev/null; then
    export GOROOT=$(go env GOROOT)
else
    export GOROOT=/usr/local/go
fi
export GOPATH="$HOME/go"
export PATH="$PATH:$GOROOT/bin:$GOPATH/bin"

log()     { echo -e "${GREEN}${BOLD}[+]${RESET} $1" | tee -a "$LOGFILE"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $1" | tee -a "$LOGFILE"; }
err()     { echo -e "${RED}${BOLD}[-]${RESET} $1" | tee -a "$LOGFILE"; }
info()    { echo -e "${CYAN}${BOLD}[*]${RESET} $1" | tee -a "$LOGFILE"; }
skip()    { echo -e "${DIM}[~] $1 already installed — skipping${RESET}" | tee -a "$LOGFILE"; }
section() { echo -e "\n${BLUE}${BOLD}━━━ $1 ━━━${RESET}\n" | tee -a "$LOGFILE"; }

banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
  _    _           _____ _        _ _
 | |  | |         / ____| |      (_) |
 | |__| | ___ __ | (___ | |_ _ __ _| | _____
 |  __  |/ _ \ \/ /\___ \| __| '__| | |/ / _ \
 | |  | |  __/>  < ____) | |_| |  | |   <  __/
 |_|  |_|\___/_/\_\_____/ \__|_|  |_|_|\_\___|

         Advanced Bug Bounty Toolkit Installer v2.2
EOF
    echo -e "${RESET}"
}

# ─── Preflight ───────────────────────────────────────────────
preflight() {
    section "Preflight Checks"

    [[ $EUID -ne 0 ]] && { err "Run as root: sudo bash $0"; exit 1; }

    if ! grep -qE "ubuntu|debian|kali" /etc/os-release 2>/dev/null; then
        warn "Untested OS — proceeding anyway"
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  GOARCH="amd64" ;;
        aarch64) GOARCH="arm64" ;;
        armv7l)  GOARCH="armv6l" ;;
        *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    # FIX: export GOARCH so install_go and install_go_tools can use it
    export GOARCH
    info "Architecture: $ARCH ($GOARCH)"

    FREE_GB=$(df / | awk 'NR==2 {printf "%.0f", $4/1048576}')
    (( FREE_GB < 4 )) && { err "Only ${FREE_GB}GB free — need 4GB+"; exit 1; }
    log "Disk space: ${FREE_GB}GB free"

    curl -sf --max-time 5 https://google.com > /dev/null || { err "No internet"; exit 1; }
    log "Internet: connected"

    mkdir -p "$(dirname "$LOGFILE")" && touch "$LOGFILE"
    mkdir -p "$INSTALL_DIR"/{wordlists,configs,reports,tools}
    info "Logging to: $LOGFILE"
}

# ─── System Update ───────────────────────────────────────────
update_system() {
    section "System Update"
    info "Updating package lists..."
    apt-get update -y >> "$LOGFILE" 2>&1
    log "System updated"
}

# ─── Base Dependencies ───────────────────────────────────────
install_base() {
    section "Base Dependencies"

    PACKAGES=(
        # Build essentials
        git curl wget unzip tar
        build-essential pkg-config libssl-dev
        python3 python3-pip python3-venv python3-dev
        ruby ruby-dev
        jq libpcap-dev libffi-dev binutils

        # Network & Reconnaissance
        nmap masscan whois dnsutils
        dnsenum nikto dirb

        # Password & Authentication
        hydra john hashcat medusa ophcrack netexec patator

        # Binary Analysis & Reverse Engineering
        gdb radare2 binwalk foremost
        steghide exiftool checksec
    )

    if apt-cache show chromium &>/dev/null 2>&1; then
        PACKAGES+=(chromium)
    elif apt-cache show chromium-browser &>/dev/null 2>&1; then
        PACKAGES+=(chromium-browser)
    fi

    info "Installing ${#PACKAGES[@]} packages..."
    apt-get install -y "${PACKAGES[@]}" >> "$LOGFILE" 2>&1 && \
        log "Base packages installed" || \
        warn "Some packages failed — check $LOGFILE"
}

# ─── Go: version-aware, never downgrade ──────────────────────
install_go() {
    section "Go Language"

    GO_MIN="1.21.0"
    GO_INSTALL="1.22.3"
    # FIX: fall back to amd64 if GOARCH not set by preflight
    local ARCH="${GOARCH:-amd64}"

    setup_go_env() {
        if command -v go &>/dev/null; then
            export GOROOT=$(go env GOROOT)
        else
            export GOROOT=/usr/local/go
        fi
        export GOPATH="$HOME/go"
        export PATH="$PATH:$GOROOT/bin:$GOPATH/bin"
        for RC in ~/.bashrc ~/.zshrc; do
            [[ -f "$RC" ]] || continue
            grep -q "GOROOT=/usr/local/go" "$RC" && continue
            cat >> "$RC" << 'GOENV'

# Go environment — HexStrike
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
GOENV
        done
    }

    # Returns 0 if $1 >= $2 (semver)
    ver_gte() { printf '%s\n%s' "$2" "$1" | sort -C -V; }

    if command -v go &>/dev/null; then
        CURRENT=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "0.0.0")
        if ver_gte "$CURRENT" "$GO_MIN"; then
            log "Go $CURRENT is installed and meets minimum ($GO_MIN) — keeping existing version"
            setup_go_env
            return
        fi
        warn "Go $CURRENT is below minimum $GO_MIN — upgrading to $GO_INSTALL"
        rm -rf /usr/local/go
    fi

    GO_TARBALL="go${GO_INSTALL}.linux-${ARCH}.tar.gz"
    info "Downloading Go $GO_INSTALL..."
    wget -q --show-progress "https://go.dev/dl/$GO_TARBALL" -O "/tmp/$GO_TARBALL"
    tar -C /usr/local -xzf "/tmp/$GO_TARBALL"
    rm -f "/tmp/$GO_TARBALL"
    setup_go_env
    log "Go $GO_INSTALL installed"
}

# ─── Go Tools ────────────────────────────────────────────────
install_go_tools() {
    section "Go-based Security Tools"

    # FIX: ensure Go env is active in this function's scope
    if command -v go &>/dev/null; then
        export GOROOT=$(go env GOROOT)
    else
        export GOROOT=/usr/local/go
    fi
    export GOPATH="$HOME/go"
    export PATH="$PATH:$GOROOT/bin:$GOPATH/bin"

    if ! command -v go &>/dev/null; then
        warn "go binary not found — skipping Go tools"
        return
    fi

    # FIX: clean stale module cache to prevent "module declares its path" errors
    info "Cleaning Go module cache to avoid stale builds..."
    go clean -modcache >> "$LOGFILE" 2>&1 || true

    # Create GOPATH/bin if it doesn't exist
    mkdir -p "$GOPATH/bin"

    # FIX: bin name|module path — all verified against current module paths (March 2026)
    GO_TOOLS=(
        # ProjectDiscovery suite
        "subfinder|github.com/projectdiscovery/subfinder/v2/cmd/subfinder"
        "httpx|github.com/projectdiscovery/httpx/cmd/httpx"
        "nuclei|github.com/projectdiscovery/nuclei/v3/cmd/nuclei"
        "katana|github.com/projectdiscovery/katana/cmd/katana"
        "dnsx|github.com/projectdiscovery/dnsx/cmd/dnsx"
        "naabu|github.com/projectdiscovery/naabu/v2/cmd/naabu"
        "interactsh-client|github.com/projectdiscovery/interactsh/cmd/interactsh-client"
        "mapcidr|github.com/projectdiscovery/mapcidr/cmd/mapcidr"

        # Reconnaissance
        "amass|github.com/owasp-amass/amass/v4/..."

        # Web application
        "dalfox|github.com/hahwul/dalfox/v2"
        "ffuf|github.com/ffuf/ffuf/v2"
        "gobuster|github.com/OJ/gobuster/v3"

        # Utility
        "assetfinder|github.com/tomnomnom/assetfinder"
        "waybackurls|github.com/tomnomnom/waybackurls"
        "gf|github.com/tomnomnom/gf"
        "qsreplace|github.com/tomnomnom/qsreplace"
        "unfurl|github.com/tomnomnom/unfurl"
        "gau|github.com/lc/gau/v2/cmd/gau"
        "hakrawler|github.com/hakluke/hakrawler"
        "getJS|github.com/003random/getJS/v2"
    )

    TOTAL=${#GO_TOOLS[@]}
    IDX=0

    for ENTRY in "${GO_TOOLS[@]}"; do
        BIN="${ENTRY%%|*}"
        IMPORT="${ENTRY##*|}"
        IDX=$((IDX + 1))

        # FIX: check both PATH and GOPATH/bin explicitly (handle case-sensitivity for binaries like getJS)
        BIN_LOWER=$(echo "$BIN" | tr '[:upper:]' '[:lower:]')
        if command -v "$BIN" &>/dev/null || [[ -f "$GOPATH/bin/$BIN" ]] || \
           command -v "$BIN_LOWER" &>/dev/null || [[ -f "$GOPATH/bin/$BIN_LOWER" ]]; then
            skip "$BIN [$IDX/$TOTAL]"
            INSTALLED_TOOLS+=("$BIN")
            continue
        fi

        info "[$IDX/$TOTAL] Installing $BIN..."

        # FIX: CGO_ENABLED=0 avoids C toolchain deps; retry with GOPROXY=direct on failure
        local INSTALL_OK=0

        # Attempt 1: default proxy
        if ( CGO_ENABLED=0 go install -v "${IMPORT}@latest" >> "$LOGFILE" 2>&1 ); then
            INSTALL_OK=1
        else
            # Attempt 2: direct proxy (bypasses proxy.golang.org caching issues)
            warn "$BIN attempt 1 failed — retrying with GOPROXY=direct..."
            if ( CGO_ENABLED=0 GOPROXY=direct go install -v "${IMPORT}@latest" >> "$LOGFILE" 2>&1 ); then
                INSTALL_OK=1
            else
                # Attempt 3: go get + go build fallback for stubborn repos
                warn "$BIN attempt 2 failed — trying git clone fallback..."
                local CLONE_DIR
                CLONE_DIR=$(mktemp -d)
                local REPO_URL="https://${IMPORT%%/cmd/*}"
                # For tools without /cmd/ subpath, use the import as-is
                [[ "$IMPORT" == *"/cmd/"* ]] || REPO_URL="https://${IMPORT}"
                # Strip version suffix like /v2, /v3 from clone URL
                REPO_URL=$(echo "$REPO_URL" | sed -E 's|/v[0-9]+$||')

                if git clone --depth=1 "${REPO_URL}.git" "$CLONE_DIR" >> "$LOGFILE" 2>&1; then
                    # Navigate to cmd directory if it exists
                    local BUILD_DIR="$CLONE_DIR"
                    if [[ "$IMPORT" == *"/cmd/"* ]]; then
                        local CMD_SUBDIR
                        CMD_SUBDIR=$(echo "$IMPORT" | sed -E 's|.*/cmd/|cmd/|; s|@.*||')
                        [[ -d "$CLONE_DIR/$CMD_SUBDIR" ]] && BUILD_DIR="$CLONE_DIR/$CMD_SUBDIR"
                    fi
                    if ( cd "$BUILD_DIR" && CGO_ENABLED=0 go build -o "$GOPATH/bin/$BIN" . >> "$LOGFILE" 2>&1 ); then
                        INSTALL_OK=1
                    fi
                fi
                rm -rf "$CLONE_DIR" 2>/dev/null || true
            fi
        fi

        if [[ $INSTALL_OK -eq 1 ]]; then
            if command -v "$BIN" &>/dev/null || [[ -f "$GOPATH/bin/$BIN" ]] || \
               command -v "$BIN_LOWER" &>/dev/null || [[ -f "$GOPATH/bin/$BIN_LOWER" ]]; then
                log "$BIN installed"
                INSTALLED_TOOLS+=("$BIN")
            else
                warn "$BIN compiled but binary not found at $GOPATH/bin/$BIN"
                FAILED_TOOLS+=("$BIN")
            fi
        else
            warn "$BIN failed after all attempts — check $LOGFILE"
            FAILED_TOOLS+=("$BIN")
        fi
    done
}

# ─── Python Tools ────────────────────────────────────────────
install_python_tools() {
    section "Python-based Tools"

    read -r -p "  Install Python tools in Virtualenv? [Y/n]: " INSTALL_PY </dev/tty || true
    if [[ "$INSTALL_PY" =~ ^[Nn]$ ]]; then
        info "Skipping Python tools installation."
        return
    fi

    VENV="$INSTALL_DIR/venv"

    if [[ ! -d "$VENV" ]]; then
        python3 -m venv "$VENV"
        log "Virtualenv created at $VENV"
    else
        skip "Virtualenv (exists)"
    fi

    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    pip install --upgrade pip wheel setuptools >> "$LOGFILE" 2>&1

    PIP_TOOLS=(
        # Existing core
        "sqlmap|sqlmap"
        "arjun|arjun"
        "wafw00f|wafw00f"
        "shodan|shodan"
        "anthropic|anthropic"
        "requests|requests"
        "beautifulsoup4|beautifulsoup4"
        "dnspython|dnspython"
        "rich|rich"
        "pyfiglet|pyfiglet"
        "colorama|colorama"
        "httpx|httpx[cli]"

        # Network & Reconnaissance
        "fierce|fierce"
        "dirsearch|dirsearch"
        "hash-identifier|hashid"

        # Binary Analysis
        "volatility3|volatility3"
    )

    for ENTRY in "${PIP_TOOLS[@]}"; do
        NAME="${ENTRY%%|*}"
        SPEC="${ENTRY##*|}"
        if pip show "$NAME" &>/dev/null 2>&1; then
            skip "pip:$NAME"
            continue
        fi
        info "Installing pip:$NAME..."
        if ( pip install "$SPEC" >> "$LOGFILE" 2>&1 ); then
            log "$NAME installed"
            INSTALLED_TOOLS+=("$NAME")
        else
            warn "$NAME failed"
            FAILED_TOOLS+=("$NAME")
        fi
    done

    # FIX: ParamSpider — correct PyPI package is 'paramspider' (lowercase)
    # FIX: SecretFinder — not a pip package; install as a script with its requirements
    if pip show paramspider &>/dev/null 2>&1; then
        skip "pip:paramspider"
    else
        info "Installing ParamSpider..."
        if ( pip install paramspider >> "$LOGFILE" 2>&1 ); then
            log "ParamSpider installed"
            INSTALLED_TOOLS+=("paramspider")
        else
            # fallback: install from git
            if ( pip install "git+https://github.com/devanshbatham/ParamSpider.git" >> "$LOGFILE" 2>&1 ); then
                log "ParamSpider installed (from git)"
                INSTALLED_TOOLS+=("paramspider")
            else
                warn "ParamSpider failed"
                FAILED_TOOLS+=("paramspider")
            fi
        fi
    fi

    # FIX: SecretFinder is a standalone script, not a pip-installable package
    SF_DIR="$INSTALL_DIR/tools/SecretFinder"
    if [[ -f "$SF_DIR/SecretFinder.py" ]]; then
        skip "SecretFinder (already cloned)"
    else
        info "Installing SecretFinder..."
        if git clone --depth=1 https://github.com/m4ll0k/SecretFinder.git "$SF_DIR" >> "$LOGFILE" 2>&1; then
            pip install -r "$SF_DIR/requirements.txt" >> "$LOGFILE" 2>&1 || true
            # Create a wrapper in venv bin
            cat > "$VENV/bin/secretfinder" << WRAPPER
#!/bin/bash
exec python3 "$SF_DIR/SecretFinder.py" "\$@"
WRAPPER
            chmod +x "$VENV/bin/secretfinder"
            log "SecretFinder installed at $SF_DIR"
            INSTALLED_TOOLS+=("SecretFinder")
        else
            warn "SecretFinder failed"
            FAILED_TOOLS+=("SecretFinder")
        fi
    fi

    # --- theHarvester (git clone — OSINT email/domain recon) ---
    local TH_DIR="$INSTALL_DIR/tools/theHarvester"
    if [[ -f "$TH_DIR/theHarvester.py" ]] || command -v theHarvester &>/dev/null; then
        skip "theHarvester"
    else
        info "Installing theHarvester..."
        if git clone --depth=1 https://github.com/laramies/theHarvester.git "$TH_DIR" >> "$LOGFILE" 2>&1; then
            pip install -r "$TH_DIR/requirements.txt" >> "$LOGFILE" 2>&1 || true
            cat > "$VENV/bin/theHarvester" <<THWRAP
#!/bin/bash
exec python3 "$TH_DIR/theHarvester.py" "\$@"
THWRAP
            chmod +x "$VENV/bin/theHarvester"
            log "theHarvester installed"
            INSTALLED_TOOLS+=("theHarvester")
        else
            warn "theHarvester failed"
            FAILED_TOOLS+=("theHarvester")
        fi
    fi

    # --- AutoRecon (automated recon framework) ---
    if pip show autorecon &>/dev/null 2>&1 || command -v autorecon &>/dev/null; then
        skip "pip:autorecon"
    else
        info "Installing AutoRecon..."
        if ( pip install git+https://github.com/Tib3rius/AutoRecon.git >> "$LOGFILE" 2>&1 ); then
            log "AutoRecon installed"
            INSTALLED_TOOLS+=("autorecon")
        else
            warn "AutoRecon failed"
            FAILED_TOOLS+=("autorecon")
        fi
    fi

    # Fix volatility3 binary name for verification
    if [[ -f "$VENV/bin/vol" && ! -f "$VENV/bin/volatility3" ]]; then
        ln -sf "$VENV/bin/vol" "$VENV/bin/volatility3"
    fi

    deactivate

    # Symlink venv binaries with hs- prefix
    for BIN in "$VENV/bin/"*; do
        BNAME=$(basename "$BIN")
        [[ -x "$BIN" && ! -d "$BIN" ]] || continue
        [[ "$BNAME" == python* || "$BNAME" == pip* || "$BNAME" == activate* ]] && continue
        ln -sf "$BIN" "/usr/local/bin/hs-$BNAME" 2>/dev/null || true
    done
    log "Venv binaries symlinked to /usr/local/bin/hs-*"
}

# ─── Ruby Tools ──────────────────────────────────────────────
install_ruby_tools() {
    section "Ruby-based Tools"

    RUBY_GEMS=(wpscan evil-winrm)

    for GEM_NAME in "${RUBY_GEMS[@]}"; do
        if command -v "$GEM_NAME" &>/dev/null; then
            skip "$GEM_NAME"
            INSTALLED_TOOLS+=("$GEM_NAME")
            continue
        fi

        info "Installing $GEM_NAME..."
        if gem install "$GEM_NAME" >> "$LOGFILE" 2>&1; then
            log "$GEM_NAME installed via gem"
            INSTALLED_TOOLS+=("$GEM_NAME")
        else
            warn "gem:$GEM_NAME failed — trying apt..."
            if apt-get install -y "$GEM_NAME" >> "$LOGFILE" 2>&1; then
                log "$GEM_NAME installed via apt"
                INSTALLED_TOOLS+=("$GEM_NAME")
            else
                warn "$GEM_NAME failed"
                FAILED_TOOLS+=("$GEM_NAME")
            fi
        fi
    done
}

# ─── Offensive / Specialty Tools ─────────────────────────────
install_offensive_tools() {
    section "Offensive & Specialty Tools"

    local ARCH="${GOARCH:-amd64}"

    # --- RustScan (fast port scanner — pre-built binary) ---
    if command -v rustscan &>/dev/null; then
        skip "rustscan"
        INSTALLED_TOOLS+=("rustscan")
    else
        info "Installing RustScan..."
        local RS_VER="2.3.0"
        local RS_DEB="rustscan_${RS_VER}_amd64.deb"
        if [[ "$ARCH" == "amd64" ]] && \
           wget -q "https://github.com/RustScan/RustScan/releases/download/${RS_VER}/${RS_DEB}" \
                -O "/tmp/${RS_DEB}" >> "$LOGFILE" 2>&1; then
            dpkg -i "/tmp/${RS_DEB}" >> "$LOGFILE" 2>&1 || apt-get install -f -y >> "$LOGFILE" 2>&1
            rm -f "/tmp/${RS_DEB}"
            if command -v rustscan &>/dev/null; then
                log "RustScan installed"
                INSTALLED_TOOLS+=("rustscan")
            else
                warn "RustScan dpkg failed"
                FAILED_TOOLS+=("rustscan")
            fi
        else
            # fallback: cargo install (needs Rust toolchain)
            if command -v cargo &>/dev/null; then
                if cargo install rustscan >> "$LOGFILE" 2>&1; then
                    log "RustScan installed via cargo"
                    INSTALLED_TOOLS+=("rustscan")
                else
                    warn "RustScan cargo install failed"
                    FAILED_TOOLS+=("rustscan")
                fi
            else
                warn "RustScan failed (no .deb for $ARCH, no cargo)"
                FAILED_TOOLS+=("rustscan")
            fi
        fi
    fi

    # --- Feroxbuster (fast content discovery — binary) ---
    if command -v feroxbuster &>/dev/null; then
        skip "feroxbuster"
        INSTALLED_TOOLS+=("feroxbuster")
    else
        info "Installing feroxbuster..."
        if ( curl -sL https://raw.githubusercontent.com/epi052/feroxbuster/main/install-nix.sh | bash -s /usr/local/bin >> "$LOGFILE" 2>&1 ); then
            log "feroxbuster installed"
            INSTALLED_TOOLS+=("feroxbuster")
        else
            if apt-get install -y feroxbuster >> "$LOGFILE" 2>&1; then
                log "feroxbuster installed (apt)"
                INSTALLED_TOOLS+=("feroxbuster")
            else
                warn "feroxbuster failed"
                FAILED_TOOLS+=("feroxbuster")
            fi
        fi
    fi

    # --- Responder (LLMNR/NBT-NS/MDNS poisoner — git clone) ---
    local RESP_DIR="$INSTALL_DIR/tools/Responder"
    if [[ -f "$RESP_DIR/Responder.py" ]] || command -v responder &>/dev/null; then
        skip "responder"
        INSTALLED_TOOLS+=("responder")
    else
        info "Installing Responder..."
        if git clone --depth=1 https://github.com/lgandx/Responder.git "$RESP_DIR" >> "$LOGFILE" 2>&1; then
            cat > /usr/local/bin/responder <<RESPWRAP
#!/bin/bash
exec python3 "$RESP_DIR/Responder.py" "\$@"
RESPWRAP
            chmod +x /usr/local/bin/responder
            log "Responder installed at $RESP_DIR"
            INSTALLED_TOOLS+=("responder")
        else
            warn "Responder failed"
            FAILED_TOOLS+=("responder")
        fi
    fi

    # --- enum4linux-ng (SMB/Windows enumeration — git + pip) ---
    local E4L_DIR="$INSTALL_DIR/tools/enum4linux-ng"
    if [[ -f "$E4L_DIR/enum4linux-ng.py" ]] || command -v enum4linux-ng &>/dev/null; then
        skip "enum4linux-ng"
        INSTALLED_TOOLS+=("enum4linux-ng")
    else
        info "Installing enum4linux-ng..."
        if git clone --depth=1 https://github.com/cddmp/enum4linux-ng.git "$E4L_DIR" >> "$LOGFILE" 2>&1; then
            pip3 install -r "$E4L_DIR/requirements.txt" >> "$LOGFILE" 2>&1 || true
            cat > /usr/local/bin/enum4linux-ng <<E4LWRAP
#!/bin/bash
exec python3 "$E4L_DIR/enum4linux-ng.py" "\$@"
E4LWRAP
            chmod +x /usr/local/bin/enum4linux-ng
            log "enum4linux-ng installed at $E4L_DIR"
            INSTALLED_TOOLS+=("enum4linux-ng")
        else
            warn "enum4linux-ng failed"
            FAILED_TOOLS+=("enum4linux-ng")
        fi
    fi

    # --- Ghidra (NSA reverse engineering suite — binary download) ---
    local GHIDRA_DIR="$INSTALL_DIR/tools/ghidra"
    if [[ -d "$GHIDRA_DIR" ]] && ls "$GHIDRA_DIR"/ghidraRun &>/dev/null 2>&1; then
        skip "ghidra"
        INSTALLED_TOOLS+=("ghidra")
    else
        info "Installing Ghidra (this may take a while)..."
        # Ensure Java is available
        if ! command -v java &>/dev/null; then
            info "Installing Java (JDK 17) for Ghidra..."
            apt-get install -y openjdk-17-jdk >> "$LOGFILE" 2>&1 || \
                apt-get install -y default-jdk >> "$LOGFILE" 2>&1 || true
        fi
        local GH_URL
        GH_URL=$(curl -s https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest | grep browser_download_url | cut -d '"' -f 4 | head -1)
        if [[ -z "$GH_URL" ]]; then
            GH_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_11.3.1_build/ghidra_11.3.1_PUBLIC_20240228.zip"
        fi
        local GH_ZIP
        GH_ZIP=$(basename "$GH_URL")
        local GH_VER
        GH_VER=$(echo "$GH_ZIP" | grep -oP 'ghidra_\K[0-9.]+' || echo "latest")
        if wget -q "$GH_URL" -O "/tmp/$GH_ZIP" >> "$LOGFILE" 2>&1; then
            unzip -o -q "/tmp/$GH_ZIP" -d "$INSTALL_DIR/tools/" >> "$LOGFILE" 2>&1
            # Ghidra unzips into a subdirectory; move contents up
            local EXTRACTED=$(ls -d "$INSTALL_DIR/tools/ghidra_"* 2>/dev/null | head -1)
            if [[ -n "$EXTRACTED" && "$EXTRACTED" != "$GHIDRA_DIR" ]]; then
                rm -rf "$GHIDRA_DIR"
                mv "$EXTRACTED" "$GHIDRA_DIR" 2>/dev/null || true
            fi
            rm -f "/tmp/$GH_ZIP"
            # Create wrapper
            if [[ -f "$GHIDRA_DIR/ghidraRun" ]]; then
                ln -sf "$GHIDRA_DIR/ghidraRun" /usr/local/bin/ghidra 2>/dev/null || true
                log "Ghidra $GH_VER installed at $GHIDRA_DIR"
                INSTALLED_TOOLS+=("ghidra")
            else
                warn "Ghidra extracted but ghidraRun not found"
                FAILED_TOOLS+=("ghidra")
            fi
        else
            warn "Ghidra download failed"
            FAILED_TOOLS+=("ghidra")
        fi
    fi
}

# ─── Cloud Security Tools ────────────────────────────────────
install_cloud_security_tools() {
    section "Cloud Security Tools"

    VENV="$INSTALL_DIR/venv"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"

    # --- Prowler (Python-based AWS/Azure/GCP auditor) ---
    if pip show prowler &>/dev/null 2>&1 || command -v prowler &>/dev/null; then
        skip "prowler"
        INSTALLED_TOOLS+=("prowler")
    else
        info "Installing prowler..."
        if ( pip install prowler >> "$LOGFILE" 2>&1 ); then
            log "prowler installed"
            INSTALLED_TOOLS+=("prowler")
        else
            warn "prowler failed"
            FAILED_TOOLS+=("prowler")
        fi
    fi

    # --- ScoutSuite (Python-based multi-cloud auditor) ---
    if pip show scoutsuite &>/dev/null 2>&1 || command -v scout &>/dev/null; then
        skip "scout-suite"
        INSTALLED_TOOLS+=("scout-suite")
    else
        info "Installing ScoutSuite..."
        if ( pip install scoutsuite >> "$LOGFILE" 2>&1 ); then
            log "ScoutSuite installed"
            INSTALLED_TOOLS+=("scout-suite")
        else
            # fallback: install from git
            if ( pip install "git+https://github.com/nccgroup/ScoutSuite.git" >> "$LOGFILE" 2>&1 ); then
                log "ScoutSuite installed (from git)"
                INSTALLED_TOOLS+=("scout-suite")
            else
                warn "ScoutSuite failed"
                FAILED_TOOLS+=("scout-suite")
            fi
        fi
    fi

    # --- kube-hunter (Python-based K8s pen-test) ---
    if pip show kube-hunter &>/dev/null 2>&1 || command -v kube-hunter &>/dev/null; then
        skip "kube-hunter"
        INSTALLED_TOOLS+=("kube-hunter")
    else
        info "Installing kube-hunter..."
        if ( pip install kube-hunter >> "$LOGFILE" 2>&1 ); then
            log "kube-hunter installed"
            INSTALLED_TOOLS+=("kube-hunter")
        else
            warn "kube-hunter failed"
            FAILED_TOOLS+=("kube-hunter")
        fi
    fi

    deactivate

    # Re-symlink new venv binaries
    for BIN in "$VENV/bin/"*; do
        BNAME=$(basename "$BIN")
        [[ -x "$BIN" && ! -d "$BIN" ]] || continue
        [[ "$BNAME" == python* || "$BNAME" == pip* || "$BNAME" == activate* ]] && continue
        ln -sf "$BIN" "/usr/local/bin/hs-$BNAME" 2>/dev/null || true
    done

    # --- Trivy (container/IaC vulnerability scanner — binary) ---
    if command -v trivy &>/dev/null; then
        skip "trivy"
        INSTALLED_TOOLS+=("trivy")
    else
        info "Installing Trivy..."
        if ( curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin >> "$LOGFILE" 2>&1 ); then
            log "Trivy installed"
            INSTALLED_TOOLS+=("trivy")
        else
            # fallback: apt repo
            if ( wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg 2>/dev/null && \
                 echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" > /etc/apt/sources.list.d/trivy.list && \
                 apt-get update -y >> "$LOGFILE" 2>&1 && \
                 apt-get install -y trivy >> "$LOGFILE" 2>&1 ); then
                log "Trivy installed (via apt)"
                INSTALLED_TOOLS+=("trivy")
            else
                warn "Trivy failed"
                FAILED_TOOLS+=("trivy")
            fi
        fi
    fi

    # --- kube-bench (Go binary — CIS K8s benchmarks) ---
    if command -v kube-bench &>/dev/null || [[ -f "$GOPATH/bin/kube-bench" ]]; then
        skip "kube-bench"
        INSTALLED_TOOLS+=("kube-bench")
    else
        info "Installing kube-bench..."
        # Try go install first
        if ( CGO_ENABLED=0 go install github.com/aquasecurity/kube-bench@latest >> "$LOGFILE" 2>&1 ); then
            log "kube-bench installed"
            INSTALLED_TOOLS+=("kube-bench")
        else
            # fallback: download pre-built release
            local KB_VER="0.9.3"
            local KB_ARCH="${GOARCH:-amd64}"
            if ( wget -q "https://github.com/aquasecurity/kube-bench/releases/download/v${KB_VER}/kube-bench_${KB_VER}_linux_${KB_ARCH}.tar.gz" \
                     -O /tmp/kube-bench.tar.gz && \
                 tar -xzf /tmp/kube-bench.tar.gz -C /usr/local/bin kube-bench >> "$LOGFILE" 2>&1 ); then
                chmod +x /usr/local/bin/kube-bench
                rm -f /tmp/kube-bench.tar.gz
                log "kube-bench installed (pre-built binary)"
                INSTALLED_TOOLS+=("kube-bench")
            else
                rm -f /tmp/kube-bench.tar.gz 2>/dev/null || true
                warn "kube-bench failed"
                FAILED_TOOLS+=("kube-bench")
            fi
        fi
    fi

    # --- docker-bench-security (Shell script — CIS Docker benchmarks) ---
    local DBS_DIR="$INSTALL_DIR/tools/docker-bench-security"
    if [[ -f "$DBS_DIR/docker-bench-security.sh" ]]; then
        skip "docker-bench-security"
        INSTALLED_TOOLS+=("docker-bench-security")
    else
        info "Installing docker-bench-security..."
        if git clone --depth=1 https://github.com/docker/docker-bench-security.git "$DBS_DIR" >> "$LOGFILE" 2>&1; then
            chmod +x "$DBS_DIR/docker-bench-security.sh"
            # Create a wrapper in /usr/local/bin
            cat > /usr/local/bin/docker-bench-security <<WRAPPER
#!/bin/bash
exec "$DBS_DIR/docker-bench-security.sh" "\$@"
WRAPPER
            chmod +x /usr/local/bin/docker-bench-security
            log "docker-bench-security installed at $DBS_DIR"
            INSTALLED_TOOLS+=("docker-bench-security")
        else
            warn "docker-bench-security failed"
            FAILED_TOOLS+=("docker-bench-security")
        fi
    fi
}

# ─── Browser Agent (Chrome/Chromium) ─────────────────────────
install_browser_agent() {
    section "Browser Agent Requirements"

    # Check if Chrome or Chromium is already available
    if command -v google-chrome-stable &>/dev/null || command -v google-chrome &>/dev/null; then
        CHROME_VER=$(google-chrome --version 2>/dev/null || google-chrome-stable --version 2>/dev/null || echo "installed")
        skip "Google Chrome ($CHROME_VER)"
        INSTALLED_TOOLS+=("chrome")
    elif command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
        CHROME_VER=$(chromium-browser --version 2>/dev/null || chromium --version 2>/dev/null || echo "installed")
        skip "Chromium ($CHROME_VER)"
        INSTALLED_TOOLS+=("chromium")
    else
        info "Installing Chrome/Chromium for browser agent..."

        # Try Google Chrome first (preferred — more stable for automation)
        local CHROME_OK=0
        if wget -q -O - https://dl.google.com/linux/linux_signing_key.pub 2>/dev/null | apt-key add - >> "$LOGFILE" 2>&1; then
            echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
            if apt-get update -y >> "$LOGFILE" 2>&1 && \
               apt-get install -y google-chrome-stable >> "$LOGFILE" 2>&1; then
                log "Google Chrome installed"
                INSTALLED_TOOLS+=("chrome")
                CHROME_OK=1
            fi
        fi

        # Fallback to Chromium from apt
        if [[ $CHROME_OK -eq 0 ]]; then
            info "Chrome unavailable — trying Chromium..."
            if apt-get install -y chromium-browser >> "$LOGFILE" 2>&1 || \
               apt-get install -y chromium >> "$LOGFILE" 2>&1; then
                log "Chromium installed"
                INSTALLED_TOOLS+=("chromium")
            else
                warn "Chrome/Chromium installation failed — browser agent may not work"
                FAILED_TOOLS+=("chrome")
            fi
        fi
    fi

    # ChromeDriver
    if command -v chromedriver &>/dev/null; then
        skip "chromedriver ($(chromedriver --version 2>/dev/null | head -1 || echo 'installed'))"
        INSTALLED_TOOLS+=("chromedriver")
    else
        info "Installing ChromeDriver..."
        if apt-get install -y chromium-driver >> "$LOGFILE" 2>&1 || \
           apt-get install -y chromium-chromedriver >> "$LOGFILE" 2>&1; then
            log "ChromeDriver installed (apt)"
            INSTALLED_TOOLS+=("chromedriver")
        else
            # Fallback: download matching chromedriver for installed Chrome version
            local CHROME_MAJOR
            CHROME_MAJOR=$(google-chrome --version 2>/dev/null | grep -oP '\d+' | head -1 || \
                           chromium-browser --version 2>/dev/null | grep -oP '\d+' | head -1 || \
                           chromium --version 2>/dev/null | grep -oP '\d+' | head -1 || echo "")
            if [[ -n "$CHROME_MAJOR" ]]; then
                info "Downloading ChromeDriver for Chrome $CHROME_MAJOR..."
                local CD_URL="https://storage.googleapis.com/chrome-for-testing-public/${CHROME_MAJOR}.0.0.0/linux64/chromedriver-linux64.zip"
                if wget -q "$CD_URL" -O /tmp/chromedriver.zip >> "$LOGFILE" 2>&1; then
                    unzip -o /tmp/chromedriver.zip -d /tmp/chromedriver_temp >> "$LOGFILE" 2>&1
                    cp /tmp/chromedriver_temp/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver 2>/dev/null || \
                        cp /tmp/chromedriver_temp/chromedriver /usr/local/bin/chromedriver 2>/dev/null || true
                    chmod +x /usr/local/bin/chromedriver
                    rm -rf /tmp/chromedriver.zip /tmp/chromedriver_temp
                    log "ChromeDriver installed (binary download)"
                    INSTALLED_TOOLS+=("chromedriver")
                else
                    warn "ChromeDriver download failed"
                    FAILED_TOOLS+=("chromedriver")
                fi
            else
                warn "Cannot detect Chrome version — skipping ChromeDriver"
                FAILED_TOOLS+=("chromedriver")
            fi
        fi
    fi
}

# ─── Wordlists ───────────────────────────────────────────────
install_wordlists() {
    section "Wordlists"

    WORDLIST_DIR="$INSTALL_DIR/wordlists"

    if [[ -d "$WORDLIST_DIR/SecLists/.git" ]]; then
        info "SecLists present — pulling updates..."
        git -C "$WORDLIST_DIR/SecLists" pull --quiet >> "$LOGFILE" 2>&1 && \
            log "SecLists updated" || warn "SecLists pull failed"
    else
        info "Cloning SecLists (~1.5GB)..."
        git clone --depth=1 https://github.com/danielmiessler/SecLists.git \
            "$WORDLIST_DIR/SecLists" >> "$LOGFILE" 2>&1 && \
            log "SecLists downloaded" || warn "SecLists failed"
    fi

    ASSETNOTE_DIR="$WORDLIST_DIR/assetnote"
    mkdir -p "$ASSETNOTE_DIR"
    for WL in subdomains.txt parameters.txt; do
        [[ -f "$ASSETNOTE_DIR/$WL" ]] && { skip "assetnote/$WL"; continue; }
        wget -q "https://wordlists-cdn.assetnote.io/data/manual/$WL" \
            -O "$ASSETNOTE_DIR/$WL" >> "$LOGFILE" 2>&1 && \
            log "Downloaded assetnote/$WL" || warn "assetnote/$WL unavailable"
    done

    ln -sf "$WORDLIST_DIR/SecLists/Discovery/DNS/subdomains-top1million-5000.txt"  "$WORDLIST_DIR/subs-fast.txt"   2>/dev/null || true
    ln -sf "$WORDLIST_DIR/SecLists/Discovery/DNS/subdomains-top1million-20000.txt" "$WORDLIST_DIR/subs-deep.txt"   2>/dev/null || true
    ln -sf "$WORDLIST_DIR/SecLists/Discovery/Web-Content/common.txt"               "$WORDLIST_DIR/dirs-common.txt" 2>/dev/null || true
    ln -sf "$WORDLIST_DIR/SecLists/Discovery/Web-Content/big.txt"                  "$WORDLIST_DIR/dirs-big.txt"    2>/dev/null || true

    log "Wordlists ready at $WORDLIST_DIR"
}

# ─── Nuclei Templates ────────────────────────────────────────
install_nuclei_templates() {
    section "Nuclei Templates"

    if ! command -v nuclei &>/dev/null; then
        warn "nuclei not found — skipping templates"
        return
    fi

    nuclei -update-templates >> "$LOGFILE" 2>&1 && \
        log "Nuclei templates updated" || warn "Template update failed"

    TDIR="$HOME/nuclei-templates/community"
    if [[ -d "$TDIR/fuzzing/.git" ]]; then
        git -C "$TDIR/fuzzing" pull --quiet >> "$LOGFILE" 2>&1
        skip "fuzzing templates (updated in place)"
    else
        mkdir -p "$TDIR"
        git clone --depth=1 https://github.com/projectdiscovery/fuzzing-templates.git \
            "$TDIR/fuzzing" >> "$LOGFILE" 2>&1 && \
            log "Fuzzing templates downloaded" || true
    fi
}

# ─── GF Patterns ─────────────────────────────────────────────
install_gf_patterns() {
    section "GF Patterns"

    # FIX: check both PATH and GOPATH/bin for gf
    if ! command -v gf &>/dev/null && [[ ! -f "$GOPATH/bin/gf" ]]; then
        warn "gf not found — skipping patterns"
        return
    fi

    GF_DIR="$HOME/.gf"
    mkdir -p "$GF_DIR"

    if ls "$GF_DIR"/*.json &>/dev/null 2>&1; then
        skip "GF patterns (already installed)"
        return
    fi

    git clone --depth=1 https://github.com/1ndianl33t/Gf-Patterns.git \
        /tmp/gf-patterns >> "$LOGFILE" 2>&1
    cp /tmp/gf-patterns/*.json "$GF_DIR/"
    rm -rf /tmp/gf-patterns

    # FIX: also copy gf's built-in examples if available
    GF_EXAMPLES="$GOPATH/pkg/mod/github.com/tomnomnom"
    find "$GF_EXAMPLES" -name "*.json" -path "*/gf/*" -exec cp {} "$GF_DIR/" \; 2>/dev/null || true

    log "GF patterns installed"
}

# ─── API Keys ────────────────────────────────────────────────
configure_api_keys() {
    section "API Key Configuration"

    mkdir -p "$(dirname "$CONFIG_FILE")"
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true

    KEY_LIST=(
        "HEXSTRIKE_API_KEY|Anthropic API key (sk-ant-...)"
        "GITHUB_TOKEN|GitHub token — code dorking"
        "SHODAN_API_KEY|Shodan — internet-wide scanning"
        "CHAOS_API_KEY|Chaos (projectdiscovery.io)"
        "CENSYS_API_ID|Censys API ID"
        "CENSYS_API_SECRET|Censys API Secret"
        "VIRUSTOTAL_API_KEY|VirusTotal"
    )

    PROMPTED=0

    for ENTRY in "${KEY_LIST[@]}"; do
        KEY="${ENTRY%%|*}"
        DESC="${ENTRY##*|}"

        if [[ -n "${!KEY:-}" ]]; then
            skip "$KEY (already in environment)"
            continue
        fi

        if grep -q "^export $KEY=" "$CONFIG_FILE" 2>/dev/null; then
            skip "$KEY (already in keys.env)"
            continue
        fi

        PROMPTED=1
        # FIX: -r flag and explicit /dev/tty redirect — works inside piped installs
        read -r -p "  $DESC: " VALUE </dev/tty || true
        if [[ -n "$VALUE" ]]; then
            echo "export $KEY=\"$VALUE\"" >> "$CONFIG_FILE"
            log "$KEY saved"
        else
            warn "$KEY skipped"
        fi
    done

    [[ $PROMPTED -eq 0 ]] && log "All API keys already configured — no prompts needed"

    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true

    for RC in ~/.bashrc ~/.zshrc; do
        [[ -f "$RC" ]] || continue
        grep -q "hexstrike.*keys.env" "$RC" && continue
        printf '\n# HexStrike API keys\n[[ -f "%s" ]] && source "%s"\n' \
            "$CONFIG_FILE" "$CONFIG_FILE" >> "$RC"
    done

    # Sync to subfinder provider config
    if command -v subfinder &>/dev/null || [[ -f "$GOPATH/bin/subfinder" ]]; then
        SFCONF="$HOME/.config/subfinder/provider-config.yaml"
        mkdir -p "$(dirname "$SFCONF")"
        [[ ! -f "$SFCONF" ]] && touch "$SFCONF"
        [[ -n "${GITHUB_TOKEN:-}" ]] && ! grep -q "^github:" "$SFCONF" 2>/dev/null && \
            echo "github: [\"${GITHUB_TOKEN}\"]" >> "$SFCONF"
        [[ -n "${SHODAN_API_KEY:-}" ]] && ! grep -q "^shodan:" "$SFCONF" 2>/dev/null && \
            echo "shodan: [\"${SHODAN_API_KEY}\"]" >> "$SFCONF"
        [[ -n "${CHAOS_API_KEY:-}" ]] && ! grep -q "^chaos:" "$SFCONF" 2>/dev/null && \
            echo "chaos: [\"${CHAOS_API_KEY}\"]" >> "$SFCONF"
        [[ -n "${VIRUSTOTAL_API_KEY:-}" ]] && ! grep -q "^virustotal:" "$SFCONF" 2>/dev/null && \
            echo "virustotal: [\"${VIRUSTOTAL_API_KEY}\"]" >> "$SFCONF"
        log "API keys synced to subfinder provider config"
    fi
}

# ─── HexStrike Config ────────────────────────────────────────
write_hexstrike_config() {
    section "HexStrike Configuration"

    CONFIG="$INSTALL_DIR/configs/hexstrike.conf"

    if [[ -f "$CONFIG" ]]; then
        skip "hexstrike.conf (already exists — not overwriting)"
        return
    fi

    cat > "$CONFIG" << EOF
# HexStrike Configuration — generated $(date)

[paths]
install_dir    = $INSTALL_DIR
wordlists_dir  = $INSTALL_DIR/wordlists
reports_dir    = $INSTALL_DIR/reports
venv           = $INSTALL_DIR/venv

[wordlists]
subs_fast      = $INSTALL_DIR/wordlists/subs-fast.txt
subs_deep      = $INSTALL_DIR/wordlists/subs-deep.txt
dirs_common    = $INSTALL_DIR/wordlists/dirs-common.txt
dirs_big       = $INSTALL_DIR/wordlists/dirs-big.txt

[ai]
provider       = anthropic
model          = claude-haiku-4-5-20251001
max_tokens     = 1024

[defaults]
threads        = 50
timeout        = 10
rate_limit     = 150
output_format  = json

[recon]
passive_only   = false
resolve_dns    = true
screenshot     = true
EOF

    log "Config written to $CONFIG"
}

# ─── Verification ────────────────────────────────────────────
verify_tools() {
    section "Tool Verification"

    # FIX: ensure Go env active so GOPATH/bin tools are found
    export GOROOT=/usr/local/go
    export GOPATH="$HOME/go"
    export PATH="$PATH:$GOROOT/bin:$GOPATH/bin"

    # FIX: source keys.env before checking API keys
    source "$CONFIG_FILE" 2>/dev/null || true

    FOUND=0
    MISSING=()

    # --- Recon & Go tools ---
    echo -e "${BOLD}Go / system tools:${RESET}"
    VERIFY_LIST=(
        subfinder httpx nuclei katana dnsx naabu dalfox
        interactsh-client mapcidr amass assetfinder waybackurls
        gf qsreplace unfurl gau ffuf gobuster
        hakrawler getJS nmap masscan wpscan
    )

    for TOOL in "${VERIFY_LIST[@]}"; do
        TOOL_LOWER=$(echo "$TOOL" | tr '[:upper:]' '[:lower:]')
        FOUND_PATH=""
        if command -v "$TOOL" &>/dev/null; then FOUND_PATH="$TOOL"
        elif [[ -f "$GOPATH/bin/$TOOL" ]]; then FOUND_PATH="$GOPATH/bin/$TOOL"
        elif command -v "$TOOL_LOWER" &>/dev/null; then FOUND_PATH="$TOOL_LOWER"
        elif [[ -f "$GOPATH/bin/$TOOL_LOWER" ]]; then FOUND_PATH="$GOPATH/bin/$TOOL_LOWER"
        fi

        if [[ -n "$FOUND_PATH" ]]; then
            if [[ "$TOOL" =~ ^(ghidra|ophcrack|responder)$ ]]; then
                VER="ok"
            else
                VER=$(timeout 2 "$FOUND_PATH" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1 || echo "ok")
            fi
            printf "  ${GREEN}✔${RESET} %-22s ${DIM}%s${RESET}\n" "$TOOL" "$VER"
            FOUND=$((FOUND + 1))
        else
            printf "  ${RED}✘${RESET} %-22s missing\n" "$TOOL"
            MISSING+=("$TOOL")
        fi
    done

    # --- Network & Recon (apt/special) ---
    echo -e "\n${BOLD}Network & Reconnaissance:${RESET}"
    for TOOL in dnsenum nikto dirb rustscan feroxbuster responder enum4linux-ng theHarvester autorecon; do
        FOUND_PATH=""
        if command -v "$TOOL" &>/dev/null; then FOUND_PATH="$TOOL"
        elif [[ -f "/usr/local/bin/$TOOL" ]]; then FOUND_PATH="/usr/local/bin/$TOOL"
        elif [[ -f "$INSTALL_DIR/venv/bin/$TOOL" ]]; then FOUND_PATH="$INSTALL_DIR/venv/bin/$TOOL"
        fi
        if [[ -n "$FOUND_PATH" ]]; then
            if [[ "$TOOL" =~ ^(ghidra|ophcrack|responder)$ ]]; then
                VER="ok"
            else
                VER=$(timeout 2 "$FOUND_PATH" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1 || echo "ok")
            fi
            printf "  ${GREEN}✔${RESET} %-22s ${DIM}%s${RESET}\n" "$TOOL" "$VER"
            FOUND=$((FOUND + 1))
        else
            printf "  ${RED}✘${RESET} %-22s missing\n" "$TOOL"
            MISSING+=("$TOOL")
        fi
    done

    # --- Password & Auth ---
    echo -e "\n${BOLD}Password & Authentication:${RESET}"
    for TOOL in hydra john hashcat medusa evil-winrm netexec ophcrack; do
        if command -v "$TOOL" &>/dev/null; then
            if [[ "$TOOL" =~ ^(ghidra|ophcrack|responder)$ ]]; then
                VER="ok"
            else
                VER=$(timeout 2 "$TOOL" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1 || echo "ok")
            fi
            printf "  ${GREEN}✔${RESET} %-22s ${DIM}%s${RESET}\n" "$TOOL" "$VER"
            FOUND=$((FOUND + 1))
        else
            printf "  ${RED}✘${RESET} %-22s missing\n" "$TOOL"
            MISSING+=("$TOOL")
        fi
    done

    # --- Binary Analysis & Reverse Engineering ---
    echo -e "\n${BOLD}Binary Analysis & Reverse Engineering:${RESET}"
    for TOOL in gdb radare2 binwalk ghidra checksec strings objdump volatility3 foremost steghide exiftool; do
        FOUND_PATH=""
        if command -v "$TOOL" &>/dev/null; then FOUND_PATH="$TOOL"
        elif [[ -f "/usr/local/bin/$TOOL" ]]; then FOUND_PATH="/usr/local/bin/$TOOL"
        elif [[ -f "$INSTALL_DIR/venv/bin/$TOOL" ]]; then FOUND_PATH="$INSTALL_DIR/venv/bin/$TOOL"
        fi
        if [[ -n "$FOUND_PATH" ]]; then
            if [[ "$TOOL" =~ ^(ghidra|ophcrack|responder)$ ]]; then
                VER="ok"
            else
                VER=$(timeout 2 "$FOUND_PATH" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1 || echo "ok")
            fi
            printf "  ${GREEN}✔${RESET} %-22s ${DIM}%s${RESET}\n" "$TOOL" "$VER"
            FOUND=$((FOUND + 1))
        else
            printf "  ${RED}✘${RESET} %-22s missing\n" "$TOOL"
            MISSING+=("$TOOL")
        fi
    done

    # --- Cloud Security ---
    echo -e "\n${BOLD}Cloud security tools:${RESET}"
    for TOOL in prowler scout trivy kube-hunter kube-bench docker-bench-security; do
        FOUND_PATH=""
        if command -v "$TOOL" &>/dev/null; then FOUND_PATH="$TOOL"
        elif [[ -f "$GOPATH/bin/$TOOL" ]]; then FOUND_PATH="$GOPATH/bin/$TOOL"
        elif [[ -f "$INSTALL_DIR/venv/bin/$TOOL" ]]; then FOUND_PATH="$INSTALL_DIR/venv/bin/$TOOL"
        elif [[ -f "/usr/local/bin/$TOOL" ]]; then FOUND_PATH="/usr/local/bin/$TOOL"
        fi
        if [[ -n "$FOUND_PATH" ]]; then
            if [[ "$TOOL" =~ ^(ghidra|ophcrack|responder)$ ]]; then
                VER="ok"
            else
                VER=$(timeout 2 "$FOUND_PATH" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1 || echo "ok")
            fi
            printf "  ${GREEN}✔${RESET} %-22s ${DIM}%s${RESET}\n" "$TOOL" "$VER"
            FOUND=$((FOUND + 1))
        else
            printf "  ${RED}✘${RESET} %-22s missing\n" "$TOOL"
            MISSING+=("$TOOL")
        fi
    done

    # --- Browser Agent ---
    echo -e "\n${BOLD}Browser agent:${RESET}"
    for TOOL in google-chrome-stable chromium-browser chromium chromedriver; do
        if command -v "$TOOL" &>/dev/null; then
            if [[ "$TOOL" =~ ^(ghidra|ophcrack|responder)$ ]]; then
                VER="ok"
            else
                VER=$(timeout 2 "$TOOL" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1 || echo "ok")
            fi
            printf "  ${GREEN}✔${RESET} %-22s ${DIM}%s${RESET}\n" "$TOOL" "$VER"
            FOUND=$((FOUND + 1))
        fi
    done
    if ! command -v google-chrome-stable &>/dev/null && \
       ! command -v google-chrome &>/dev/null && \
       ! command -v chromium-browser &>/dev/null && \
       ! command -v chromium &>/dev/null; then
        printf "  ${RED}✘${RESET} %-22s missing\n" "chrome/chromium"
        MISSING+=("chrome/chromium")
    fi
    if ! command -v chromedriver &>/dev/null; then
        printf "  ${RED}✘${RESET} %-22s missing\n" "chromedriver"
        MISSING+=("chromedriver")
    fi

    # --- Python (venv) tools ---
    echo -e "\n${BOLD}Python (venv) tools:${RESET}"
    VENV="$INSTALL_DIR/venv"
    for TOOL in sqlmap arjun wafw00f paramspider secretfinder fierce dirsearch \
                theHarvester autorecon netexec patator volatility3 hashid; do
        if [[ -f "$VENV/bin/$TOOL" ]] || command -v "$TOOL" &>/dev/null; then
            printf "  ${GREEN}✔${RESET} %-22s ${DIM}(venv)${RESET}\n" "$TOOL"
            FOUND=$((FOUND + 1))
        else
            printf "  ${YELLOW}~${RESET} %-22s not in venv\n" "$TOOL"
        fi
    done

    echo -e "\n${BOLD}API keys:${RESET}"
    for KEY in HEXSTRIKE_API_KEY GITHUB_TOKEN SHODAN_API_KEY CHAOS_API_KEY; do
        if [[ -n "${!KEY:-}" ]]; then
            MASKED="${!KEY:0:8}..."
            printf "  ${GREEN}✔${RESET} %-22s ${DIM}%s${RESET}\n" "$KEY" "$MASKED"
        else
            printf "  ${YELLOW}~${RESET} %-22s not set\n" "$KEY"
        fi
    done

    echo ""
    log "$FOUND tools verified"
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        warn "Missing: $(IFS=', '; echo "${MISSING[*]}")"
    fi
}

# ─── Summary ─────────────────────────────────────────────────
final_summary() {
    section "Done"

    echo -e "${BOLD}Results:${RESET}"
    printf "  ${GREEN}%-20s${RESET} %d\n" "Installed/present:" "${#INSTALLED_TOOLS[@]}"
    printf "  ${RED}%-20s${RESET} %d\n"   "Failed:"            "${#FAILED_TOOLS[@]}"
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo -e "  source ~/.bashrc"
    echo -e "  source $CONFIG_FILE"
    echo -e "  python3 hexstrike_server.py"
    echo ""
    echo -e "${BOLD}Paths:${RESET}"
    echo -e "  Config    $INSTALL_DIR/configs/hexstrike.conf"
    echo -e "  API keys  $CONFIG_FILE"
    echo -e "  Wordlists $INSTALL_DIR/wordlists"
    echo -e "  Log       $LOGFILE"
    echo ""
    if [[ ${#FAILED_TOOLS[@]} -gt 0 ]]; then
        warn "Failed tools: $(IFS=', '; echo "${FAILED_TOOLS[*]}")"
        warn "Retry: sudo bash $0 --retry"
    fi
}

# ─── Set a Single API Key ────────────────────────────────────
set_single_key() {
    local TARGET_KEY="${1:-}"

    VALID_KEYS=(
        HEXSTRIKE_API_KEY
        GITHUB_TOKEN
        SHODAN_API_KEY
        CHAOS_API_KEY
        CENSYS_API_ID
        CENSYS_API_SECRET
        VIRUSTOTAL_API_KEY
    )

    # If no key name given, show a numbered menu
    if [[ -z "$TARGET_KEY" ]]; then
        section "Select API Key to Update"
        echo -e "${BOLD}Available keys:${RESET}"
        local i=1
        for K in "${VALID_KEYS[@]}"; do
            printf "  ${CYAN}%d)${RESET} %s\n" "$i" "$K"
            i=$((i + 1))
        done
        echo ""
        read -r -p "  Enter number (1-${#VALID_KEYS[@]}): " CHOICE </dev/tty || true
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#VALID_KEYS[@]} )); then
            TARGET_KEY="${VALID_KEYS[$((CHOICE - 1))]}"
        else
            err "Invalid selection."
            exit 1
        fi
    fi

    # Validate the key name
    local VALID=0
    for K in "${VALID_KEYS[@]}"; do
        [[ "$K" == "$TARGET_KEY" ]] && VALID=1 && break
    done
    if [[ $VALID -eq 0 ]]; then
        err "Unknown key: $TARGET_KEY"
        echo -e "Valid keys: ${VALID_KEYS[*]}"
        exit 1
    fi

    section "Update API Key: $TARGET_KEY"

    mkdir -p "$(dirname "$CONFIG_FILE")"
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    # Show current masked value if set
    source "$CONFIG_FILE" 2>/dev/null || true
    if [[ -n "${!TARGET_KEY:-}" ]]; then
        local MASKED="${!TARGET_KEY:0:8}..."
        info "Current value: $MASKED"
    else
        info "Current value: (not set)"
    fi

    read -r -p "  New value for $TARGET_KEY (leave blank to cancel): " NEW_VAL </dev/tty || true
    if [[ -z "$NEW_VAL" ]]; then
        warn "Cancelled — no changes made."
        exit 0
    fi

    # Update or insert in keys.env (sed in-place replace if exists, else append)
    if grep -q "^export ${TARGET_KEY}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^export ${TARGET_KEY}=.*|export ${TARGET_KEY}=\"${NEW_VAL}\"|" "$CONFIG_FILE"
    else
        echo "export ${TARGET_KEY}=\"${NEW_VAL}\"" >> "$CONFIG_FILE"
    fi

    log "$TARGET_KEY updated in $CONFIG_FILE"

    # Re-sync subfinder if relevant key changed
    source "$CONFIG_FILE" 2>/dev/null || true
    if [[ "$TARGET_KEY" =~ ^(GITHUB_TOKEN|SHODAN_API_KEY|CHAOS_API_KEY|VIRUSTOTAL_API_KEY)$ ]]; then
        if command -v subfinder &>/dev/null || [[ -f "$GOPATH/bin/subfinder" ]]; then
            SFCONF="$HOME/.config/subfinder/provider-config.yaml"
            mkdir -p "$(dirname "$SFCONF")"
            [[ ! -f "$SFCONF" ]] && touch "$SFCONF"
            declare -A KEY_TO_SFNAME=( [GITHUB_TOKEN]=github [SHODAN_API_KEY]=shodan [CHAOS_API_KEY]=chaos [VIRUSTOTAL_API_KEY]=virustotal )
            SF_KEY="${KEY_TO_SFNAME[$TARGET_KEY]}"
            # Replace existing line or append
            if grep -q "^${SF_KEY}:" "$SFCONF" 2>/dev/null; then
                sed -i "s|^${SF_KEY}:.*|${SF_KEY}: [\"${NEW_VAL}\"]|" "$SFCONF"
            else
                echo "${SF_KEY}: [\"${NEW_VAL}\"]" >> "$SFCONF"
            fi
            log "Synced $TARGET_KEY → subfinder provider config"
        fi
    fi
}

# ─── Set AI Model ─────────────────────────────────────────────
set_model() {
    section "Change AI Model"

    CONF="$INSTALL_DIR/configs/hexstrike.conf"
    if [[ ! -f "$CONF" ]]; then
        err "Config not found: $CONF — run the full installer first."
        exit 1
    fi

    # Current model
    CURRENT_MODEL=$(grep -oP '(?<=model\s{8}= ).*' "$CONF" 2>/dev/null | head -1 || echo "unknown")
    info "Current model: ${CURRENT_MODEL}"
    echo ""

    MODELS=(
        "claude-opus-4-6          (most capable, slower)"
        "claude-sonnet-4-6        (balanced — recommended)"
        "claude-haiku-4-5-20251001 (fastest, lightweight)"
        "Custom — enter manually"
    )

    echo -e "${BOLD}Available models:${RESET}"
    local i=1
    for M in "${MODELS[@]}"; do
        printf "  ${CYAN}%d)${RESET} %s\n" "$i" "$M"
        i=$((i + 1))
    done
    echo ""

    read -r -p "  Select (1-${#MODELS[@]}): " CHOICE </dev/tty || true

    case "$CHOICE" in
        1) NEW_MODEL="claude-opus-4-6" ;;
        2) NEW_MODEL="claude-sonnet-4-6" ;;
        3) NEW_MODEL="claude-haiku-4-5-20251001" ;;
        4)
            read -r -p "  Enter model string: " NEW_MODEL </dev/tty || true
            [[ -z "$NEW_MODEL" ]] && { warn "Cancelled."; exit 0; }
            ;;
        *)
            err "Invalid selection."
            exit 1
            ;;
    esac

    # In-place replace the model line in hexstrike.conf
    sed -i "s|^model\s*=.*|model          = ${NEW_MODEL}|" "$CONF"
    log "Model updated to: $NEW_MODEL"
    info "Config: $CONF"
}

# ─── Entry Point ─────────────────────────────────────────────
main() {
    banner

    case "${1:-}" in
        --retry)
            section "Retry Mode"
            preflight
            install_base
            install_go
            install_go_tools
            install_python_tools
            install_ruby_tools
            install_offensive_tools
            install_cloud_security_tools
            install_browser_agent
            verify_tools
            final_summary
            exit 0
            ;;
        --verify)
            verify_tools
            exit 0
            ;;
        --keys)
            configure_api_keys
            exit 0
            ;;
        --set-key)
            # Usage: --set-key [KEY_NAME]  (KEY_NAME optional — shows menu if omitted)
            set_single_key "${2:-}"
            exit 0
            ;;
        --set-model)
            set_model
            exit 0
            ;;
        --help|-h)
            echo -e "${BOLD}Usage:${RESET} sudo bash $0 [option]"
            echo ""
            echo -e "${BOLD}Options:${RESET}"
            printf "  ${CYAN}%-30s${RESET} %s\n" "(none)"            "Full install"
            printf "  ${CYAN}%-30s${RESET} %s\n" "--retry"           "Re-run only failed Go/Python installs"
            printf "  ${CYAN}%-30s${RESET} %s\n" "--verify"          "Verify installed tools and keys"
            printf "  ${CYAN}%-30s${RESET} %s\n" "--keys"            "Configure all API keys"
            printf "  ${CYAN}%-30s${RESET} %s\n" "--set-key [NAME]"  "Update a single API key (menu if NAME omitted)"
            printf "  ${CYAN}%-30s${RESET} %s\n" "--set-model"       "Change the AI model in hexstrike.conf"
            echo ""
            echo -e "${BOLD}Valid key names for --set-key:${RESET}"
            printf "  HEXSTRIKE_API_KEY, GITHUB_TOKEN, SHODAN_API_KEY, CHAOS_API_KEY,\n"
            printf "  CENSYS_API_ID, CENSYS_API_SECRET, VIRUSTOTAL_API_KEY\n"
            exit 0
            ;;
        "")
            : # fall through to full install
            ;;
        *)
            err "Unknown option: ${1}"
            echo "Run: sudo bash $0 --help"
            exit 1
            ;;
    esac

    preflight
    update_system
    install_base
    install_go
    install_go_tools
    install_python_tools
    install_ruby_tools
    install_offensive_tools
    install_cloud_security_tools
    install_browser_agent
    install_wordlists
    install_nuclei_templates
    install_gf_patterns
    configure_api_keys
    write_hexstrike_config
    verify_tools
    final_summary
}

main "$@"