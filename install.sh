#!/usr/bin/env bash
# Install/uninstall aap-demo command and shell completions
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Uninstall
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
  echo "Uninstalling aap-demo..."
  rm -f ~/.local/bin/aap-demo
  rm -f ~/.zsh/completions/_aap-demo
  rm -f ~/.local/share/bash-completion/completions/aap-demo
  echo "  ✓ Binary and completions removed"
  echo ""
  echo "  VM data at ~/.aap-demo/vm/ was NOT removed."
  echo "  To remove everything: rm -rf ~/.aap-demo/vm/"
  exit 0
fi

echo "Installing aap-demo..."
echo ""

# Check dependencies
MISSING_DEPS=""

if ! command -v kubectl &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS kubectl"
fi

if ! command -v ansible-playbook &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS ansible"
fi

if ! command -v jq &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS jq"
fi

if ! command -v python3 &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS python3"
fi

# macOS-specific checks
if [[ "$(uname)" == "Darwin" ]]; then
  if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is required on macOS"
    echo ""
    echo "Install Homebrew with:"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo ""
    exit 1
  fi

  if ! command -v operator-sdk &>/dev/null; then
    MISSING_DEPS="$MISSING_DEPS operator-sdk"
  fi
fi

# Report missing dependencies
if [ -n "$MISSING_DEPS" ]; then
  echo "ERROR: Missing required dependencies:$MISSING_DEPS"
  echo ""
  echo "Install with:"
  echo ""
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "  macOS:"
    echo "    brew install kubectl ansible jq python3 operator-sdk"
  else
    echo "  Fedora/RHEL:"
    echo "    sudo dnf install ansible-core jq python3-pip"
    echo "    # kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
    echo ""
    echo "  Ubuntu/Debian:"
    echo "    sudo apt install ansible jq python3-pip"
    echo "    # kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
  fi
  echo ""
  exit 1
fi

echo "  ✓ All required dependencies found"
echo ""

# Create ~/.local/bin if needed
mkdir -p ~/.local/bin

# Create symlink
ln -sf "${SCRIPT_DIR}/aap-demo.sh" ~/.local/bin/aap-demo
echo "  Symlink: ~/.local/bin/aap-demo -> ${SCRIPT_DIR}/aap-demo.sh"

# Detect OS and install completions
SHELL_NAME=$(basename "$SHELL")

if [ "$(uname)" = "Darwin" ]; then
  # macOS: install both zsh (default) and bash completions
  mkdir -p ~/.zsh/completions
  cp "${SCRIPT_DIR}/scripts/aap-demo-completion.zsh" ~/.zsh/completions/_aap-demo
  echo "  Completion: ~/.zsh/completions/_aap-demo (zsh)"

  mkdir -p ~/.local/share/bash-completion/completions
  cp "${SCRIPT_DIR}/scripts/aap-demo-completion.bash" ~/.local/share/bash-completion/completions/aap-demo
  echo "  Completion: ~/.local/share/bash-completion/completions/aap-demo (bash)"

  # Ensure zsh fpath includes completions dir
  if ! grep -q 'fpath=(~/.zsh/completions' ~/.zshrc 2>/dev/null; then
    echo 'fpath=(~/.zsh/completions $fpath)' >>~/.zshrc
    echo 'autoload -Uz compinit && compinit' >>~/.zshrc
    echo "  Added completion path to ~/.zshrc"
  fi
else
  # Linux: install based on current shell
  if [ "$SHELL_NAME" = "zsh" ]; then
    mkdir -p ~/.zsh/completions
    cp "${SCRIPT_DIR}/scripts/aap-demo-completion.zsh" ~/.zsh/completions/_aap-demo
    echo "  Completion: ~/.zsh/completions/_aap-demo"

    if ! grep -q 'fpath=(~/.zsh/completions' ~/.zshrc 2>/dev/null; then
      echo 'fpath=(~/.zsh/completions $fpath)' >>~/.zshrc
      echo 'autoload -Uz compinit && compinit' >>~/.zshrc
      echo "  Added completion path to ~/.zshrc"
    fi
  else
    mkdir -p ~/.local/share/bash-completion/completions
    cp "${SCRIPT_DIR}/scripts/aap-demo-completion.bash" ~/.local/share/bash-completion/completions/aap-demo
    echo "  Completion: ~/.local/share/bash-completion/completions/aap-demo"
  fi
fi

# Check PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo ""
  echo "NOTE: ~/.local/bin is not in your PATH. Add it with:"
  echo "  echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.${SHELL_NAME}rc"
fi

echo ""
echo "Done. Reload completions with:"
if [ "$SHELL_NAME" = "zsh" ]; then
  echo "  exec zsh"
else
  echo "  source ~/.${SHELL_NAME}rc"
fi
echo ""
echo "Then run 'aap-demo help' to get started."
