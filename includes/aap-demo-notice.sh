#!/bin/bash
# aap-demo disclaimer notice
# Shows the aap-demo logo and usage disclaimer before deployment

# Check if QUIET mode - skip everything
if [ "${QUIET}" = "true" ]; then
  exit 0
fi

echo ""
echo ""
echo "                                                ░██                                       "
echo "                                                ░██                                       "
echo " ░██████    ░██████   ░████████           ░████████  ░███████  ░█████████████   ░███████  "
echo "      ░██        ░██  ░██    ░██ ░██████ ░██    ░██ ░██    ░██ ░██   ░██   ░██ ░██    ░██ "
echo " ░███████   ░███████  ░██    ░██         ░██    ░██ ░█████████ ░██   ░██   ░██ ░██    ░██ "
echo "░██   ░██  ░██   ░██  ░███   ░██         ░██   ░███ ░██        ░██   ░██   ░██ ░██    ░██ "
echo " ░█████░██  ░█████░██ ░██░█████           ░█████░██  ░███████  ░██   ░██   ░██  ░███████  "
echo "                      ░██                                                                 "
echo "                      ░██                                                                 "
echo "                                                                                          "
_AAP_DEMO_DIR=$(cd "$(dirname "$0")/.." && pwd)
_AAP_DEMO_SHA=$(git -C "$_AAP_DEMO_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
_AAP_DEMO_DATE=$(git -C "$_AAP_DEMO_DIR" log -1 --format=%cd --date=short 2>/dev/null || echo "unknown")
printf "                                   version %s \033[31m|\033[0m %s\n" "$_AAP_DEMO_SHA" "$_AAP_DEMO_DATE"
echo ""
echo ""
printf "                   \033[1m** PLEASE READ BEFORE PROCEEDING: **\033[0m\n"
echo ""
printf " aap-demo is for \033[1mLOCAL\033[0m DEVELOPMENT, TESTING, and DEMONSTRATION purposes \033[1mONLY\033[0m.\n"
echo ""
echo "      • DO NOT deploy for any type of production use"
echo "      • DO NOT expose to external traffic outside your local machine"
echo "      • Endpoints are intentionally unauthenticated for ease of local use"
echo "      • DNS (*.apps.127.0.0.1.nip.io) resolves to localhost by design"
echo ""
echo ""
echo ""
echo "  Press Enter to continue (auto-continues in 30s)..."
echo "  Suppress this message with: QUIET=true"
echo ""
read -t 30 -r || true
