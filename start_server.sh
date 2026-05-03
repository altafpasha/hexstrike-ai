#!/bin/bash
# ---------------------------------------------------------
# HexStrike Server Launcher
# ---------------------------------------------------------

VENV_DIR="hexstrike-dev"

# Create the virtual environment if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    echo "[+] Creating Python virtual environment in '$VENV_DIR'..."
    python3 -m venv "$VENV_DIR"
    echo "[+] Virtual environment created successfully."
fi

# Activate the virtual environment
echo "[+] Activating virtual environment..."
source "$VENV_DIR/bin/activate"

# Install dependencies if requirements.txt exists
if [ -f "requirements.txt" ]; then
    echo "[+] Checking/installing dependencies from requirements.txt..."
    pip install -r requirements.txt --upgrade > /dev/null
fi

# Run the MCP server
echo "[+] Starting HexStrike AI MCP Server on port 8888..."
python3 hexstrike_server.py --port 8888
