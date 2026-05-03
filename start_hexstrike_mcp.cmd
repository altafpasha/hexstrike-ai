@echo off
REM start_hexstrike_mcp.cmd
REM Wrapper script for HexStrike MCP - Silenced for MCP protocol purity

REM 1. Start the autossh tunnel completely detached in the background
REM All output redirected to nul to prevent stdout contamination
start "" /B wsl -- bash -c "nohup autossh -M 0 -N -f -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L 8888:10.0.4.2:8888 root@89.167.120.133 > /dev/null 2>&1 &" > nul 2>&1

REM 2. Wait a moment to ensure the tunnel is established
REM Redirecting timeout output to nul
timeout /t 3 /nobreak > nul

REM 3. Launch the HexStrike MCP server directly in WSL
REM Use -u for unbuffered output to ensure JSON-RPC messages are sent immediately.
REM Using --exec to bypass shell initialization output (like login banners).
wsl --exec python3 -u /mnt/c/Users/HP/Documents/codesec/hexstrike-ai/hexstrike_mcp.py --server http://localhost:8888
