#!/bin/bash
# aap-demo disclaimer notice
# Shows the aap-demo logo and usage disclaimer before deployment

# Check if QUIET mode - skip everything
if [ "${QUIET}" = "true" ]; then
  exit 0
fi

# shellcheck source=aap-demo-version.sh
source "$(dirname "$0")/aap-demo-version.sh"

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
printf "                                   aap-demo %s \033[31m|\033[0m %s \033[31m|\033[0m %s\n" \
  "$AAP_DEMO_VERSION" "$AAP_DEMO_GIT_SHA" "$AAP_DEMO_GIT_DATE"
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
