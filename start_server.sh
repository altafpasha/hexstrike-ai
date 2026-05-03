#!/bin/bash
# ---------------------------------------------------------
# HexStrike Server Launcher
# ---------------------------------------------------------

VENV_DIR="$HOME/.hexstrike/venv"

# Check if the virtual environment exists
if [ ! -d "$VENV_DIR" ]; then
    echo "[!] Virtual environment not found at $VENV_DIR"
    echo "Please run the hexstrike_tools_install.sh script first to set up the environment."
    exit 1
fi

# Activate the virtual environment
echo "[+] Activating HexStrike tools virtual environment..."
source "$VENV_DIR/bin/activate"

# Install server-specific dependencies (flask, aiohttp, fastmcp, etc.)
if [ -f "requirements.txt" ]; then
    echo "[+] Installing MCP server dependencies (aiohttp, flask, mcp, etc.)..."
    pip install -r requirements.txt --upgrade > /dev/null
fi

# Run the MCP server
echo "[+] Starting HexStrike AI MCP Server on port 8888..."
python3 hexstrike_server.py --port 8888
