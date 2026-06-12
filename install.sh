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
