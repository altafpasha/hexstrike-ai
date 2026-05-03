# start_hexstrike_mcp.ps1
# Wrapper script for HexStrike MCP - Silenced for MCP protocol purity

# 1. Start the autossh tunnel silently in the background inside WSL
# All output redirected to null to avoid stdout contamination
$null = wsl -- bash -c "autossh -M 0 -N -f -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L 8888:10.0.4.2:8888 root@89.167.120.133 > /dev/null 2>&1"

# 2. Wait a moment to ensure the tunnel is established
# Start-Sleep -Seconds 3 produces no output usually, but we ensure it
Start-Sleep -Seconds 3 | Out-Null

# 3. Launch the HexStrike MCP server directly in WSL
# Use -u for unbuffered output and --exec to bypass shell initialization.
wsl --exec python3 -u /mnt/c/Users/HP/Documents/codesec/hexstrike-ai/hexstrike_mcp.py --server http://localhost:8888
