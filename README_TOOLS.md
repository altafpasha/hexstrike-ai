# HexStrike

```
  _    _           _____ _        _ _
 | |  | |         / ____| |      (_) |
 | |__| | ___ __ | (___ | |_ _ __ _| | _____
 |  __  |/ _ \ \/ /\___ \| __| '__| | |/ / _ \
 | |  | |  __/>  < ____) | |_| |  | |   <  __/
 |_|  |_|\___/_/\_\_____/ \__|_|  |_|_|\_\___|
```

**Advanced Bug Bounty Toolkit — v2.2**

HexStrike is a one-shot installer and configuration manager for a full bug bounty / VAPT toolkit. It installs, verifies, and manages 30+ security tools across Go, Python, and Ruby, sets up wordlists, configures API keys, and integrates an Anthropic Claude AI backend — all from a single script.

---

## Table of Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [What Gets Installed](#what-gets-installed)
- [CLI Reference](#cli-reference)
- [API Key Management](#api-key-management)
- [AI Model Configuration](#ai-model-configuration)
- [File Layout](#file-layout)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Ubuntu 20.04+, Debian, or Kali Linux |
| Architecture | x86_64 (amd64), aarch64 (arm64), armv7l |
| Privileges | Must run as root (`sudo`) |
| Disk space | 4 GB free minimum (SecLists alone is ~1.5 GB) |
| Internet | Required throughout install |

Go 1.21.0 or higher is required. If Go is already installed and meets the minimum, it is kept as-is. If it's below the minimum, it is upgraded automatically to 1.22.3.

---

## Quick Start

```bash
git clone https://github.com/youruser/hexstrike-ai.git
cd hexstrike-ai
sudo bash hexstrike_install.sh
```

After install completes:

```bash
source ~/.bashrc
source ~/.hexstrike/configs/keys.env
python3 hexstrike_server.py
```

---

## What Gets Installed

### Go Tools (19)

| Tool | Purpose |
|---|---|
| subfinder | Passive subdomain enumeration |
| httpx | HTTP probing and fingerprinting |
| nuclei | Template-based vulnerability scanning |
| katana | Web crawler and JS endpoint discovery |
| dnsx | DNS resolution and brute-forcing |
| naabu | Fast port scanner |
| interactsh-client | Out-of-band interaction detection (SSRF, XXE, etc.) |
| mapcidr | CIDR/IP range manipulation |
| dalfox | XSS scanning and parameter analysis |
| assetfinder | Subdomain discovery via certificate transparency |
| waybackurls | Pull URLs from the Wayback Machine |
| gf | Pattern-based parameter grep (SQLi, XSS, SSRF, etc.) |
| qsreplace | Query string value replacer for fuzzing pipelines |
| unfurl | URL component extraction and analysis |
| gau | Fetch known URLs from AlienVault, Wayback, and Common Crawl |
| ffuf | Web fuzzer |
| gobuster | Directory and DNS brute-forcing |
| hakrawler | Fast web crawler |
| getJS | JavaScript file discovery |

### Python Tools (venv-isolated)

| Tool | Purpose |
|---|---|
| sqlmap | Automated SQL injection |
| arjun | HTTP parameter discovery |
| wafw00f | WAF detection and fingerprinting |
| shodan | Shodan API client |
| paramspider | Parameter mining from web archives |
| SecretFinder | JS secret/key extraction |
| anthropic | Claude AI SDK (powers HexStrike AI features) |
| httpx | Python async HTTP client |
| requests / beautifulsoup4 / dnspython | Supporting libraries |

All Python tools are isolated inside `~/.hexstrike/venv` and symlinked to `/usr/local/bin/hs-<toolname>` for easy access.

### System Tools (apt)

nmap, masscan, whois, dnsutils, chromium, jq, libpcap, build-essential, Ruby + WPScan

### Wordlists

| List | Location |
|---|---|
| SecLists (full) | `~/.hexstrike/wordlists/SecLists/` |
| Assetnote subdomains | `~/.hexstrike/wordlists/assetnote/subdomains.txt` |
| Assetnote parameters | `~/.hexstrike/wordlists/assetnote/parameters.txt` |
| subs-fast.txt | Symlink → SecLists top 5k subdomains |
| subs-deep.txt | Symlink → SecLists top 20k subdomains |
| dirs-common.txt | Symlink → SecLists common.txt |
| dirs-big.txt | Symlink → SecLists big.txt |

### Nuclei Templates

- Official nuclei templates (auto-updated via `nuclei -update-templates`)
- ProjectDiscovery fuzzing templates

### GF Patterns

Installed to `~/.gf/` — covers: XSS, SQLi, SSRF, open redirect, RCE, LFI, IDOR, debug params.

---

## CLI Reference

```
sudo bash hexstrike_install.sh [option]
```

| Option | Description |
|---|---|
| *(none)* | Full install — runs all stages in sequence |
| `--retry` | Re-attempt only failed Go and Python tool installs |
| `--verify` | Check which tools and API keys are present without installing anything |
| `--keys` | Walk through all API keys and prompt for any that are missing |
| `--set-key [NAME]` | Update a single API key. Shows a numbered menu if NAME is omitted |
| `--set-model` | Interactively change the AI model used by HexStrike |
| `--help` / `-h` | Print usage reference |

### Examples

```bash
# First-time full install
sudo bash hexstrike_install.sh

# Something failed — retry just the broken tools
sudo bash hexstrike_install.sh --retry

# Rotate your Shodan key without touching anything else
sudo bash hexstrike_install.sh --set-key SHODAN_API_KEY

# Pick from a menu of keys to update
sudo bash hexstrike_install.sh --set-key

# Switch to a faster model
sudo bash hexstrike_install.sh --set-model

# Check what's installed after a partial run
sudo bash hexstrike_install.sh --verify
```

---

## API Key Management

API keys are stored in `~/.hexstrike/configs/keys.env` (chmod 600) and sourced automatically in `~/.bashrc` / `~/.zshrc` after install.

### Supported Keys

| Variable | Used By |
|---|---|
| `HEXSTRIKE_API_KEY` | Anthropic Claude AI (required for AI features) |
| `GITHUB_TOKEN` | subfinder GitHub source, code dorking |
| `SHODAN_API_KEY` | Shodan passive recon, subfinder |
| `CHAOS_API_KEY` | ProjectDiscovery Chaos dataset |
| `CENSYS_API_ID` | Censys internet-wide scanning |
| `CENSYS_API_SECRET` | Censys internet-wide scanning |
| `VIRUSTOTAL_API_KEY` | VirusTotal passive DNS, subfinder |

Keys relevant to subfinder (`GITHUB_TOKEN`, `SHODAN_API_KEY`, `CHAOS_API_KEY`, `VIRUSTOTAL_API_KEY`) are automatically synced to `~/.config/subfinder/provider-config.yaml` when set or updated.

### Updating a Single Key

```bash
# By name — no prompts, straight to update
sudo bash hexstrike_install.sh --set-key GITHUB_TOKEN

# Interactive menu — pick from numbered list
sudo bash hexstrike_install.sh --set-key
```

The current masked value is shown before prompting. Leave the input blank to cancel without making changes.

---

## AI Model Configuration

HexStrike uses Anthropic Claude as its AI backend. The active model is stored in `~/.hexstrike/configs/hexstrike.conf` under `[ai]`.

```bash
sudo bash hexstrike_install.sh --set-model
```

```
1) claude-opus-4-6           (most capable, slower)
2) claude-sonnet-4-6         (balanced — recommended)
3) claude-haiku-4-5-20251001 (fastest, lightweight)
4) Custom — enter manually
```

Select a number or enter a custom model string. The config is updated in-place — no reinstall needed.

---

## File Layout

```
~/.hexstrike/
├── configs/
│   ├── hexstrike.conf      # Main config (paths, AI model, defaults)
│   └── keys.env            # API keys (chmod 600, sourced at login)
├── wordlists/
│   ├── SecLists/           # Full SecLists repo
│   ├── assetnote/          # Assetnote subdomains + parameters
│   ├── subs-fast.txt       # Symlink → top 5k subs
│   ├── subs-deep.txt       # Symlink → top 20k subs
│   ├── dirs-common.txt     # Symlink → common.txt
│   └── dirs-big.txt        # Symlink → big.txt
├── reports/                # Scan output directory
├── tools/
│   └── SecretFinder/       # Cloned SecretFinder repo
└── venv/                   # Python virtualenv

~/go/bin/                   # All Go tool binaries
/usr/local/bin/hs-*         # Venv tool symlinks
/var/log/hexstrike_install.log   # Full install log
```

---

## Configuration

`~/.hexstrike/configs/hexstrike.conf` is generated on first install and never overwritten by subsequent runs. Edit it directly to change defaults.

```ini
[paths]
install_dir    = /root/.hexstrike
wordlists_dir  = /root/.hexstrike/wordlists
reports_dir    = /root/.hexstrike/reports
venv           = /root/.hexstrike/venv

[wordlists]
subs_fast      = /root/.hexstrike/wordlists/subs-fast.txt
subs_deep      = /root/.hexstrike/wordlists/subs-deep.txt
dirs_common    = /root/.hexstrike/wordlists/dirs-common.txt
dirs_big       = /root/.hexstrike/wordlists/dirs-big.txt

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
```

---

## Troubleshooting

**Go tools fail to install**

The most common cause is the Go binary path not being active in the current shell session. Fix by exporting manually before retrying:

```bash
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
sudo bash hexstrike_install.sh --retry
```

**Tools installed but showing missing in --verify**

The binaries are in `~/go/bin/` but not on `PATH` in the current session. Run `source ~/.bashrc` and then `--verify` again.

**Check what failed and why**

```bash
cat /var/log/hexstrike_install.log | grep -A5 "<toolname>"
```

**SecLists pull fails**

If git pull fails due to conflicts, remove and re-clone:

```bash
rm -rf ~/.hexstrike/wordlists/SecLists
sudo bash hexstrike_install.sh  # will re-clone on next run
```

**API keys not loading in new shells**

Confirm the source line was added to your RC file:

```bash
grep hexstrike ~/.bashrc
# Should show: [[ -f "~/.hexstrike/configs/keys.env" ]] && source "..."
```

If missing, add it manually:

```bash
echo 'source ~/.hexstrike/configs/keys.env' >> ~/.bashrc
```

---

## Legal

HexStrike is intended for authorized security testing only. Always obtain explicit written permission before scanning any target. The authors accept no liability for unauthorized or illegal use.