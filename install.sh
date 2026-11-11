#!/usr/bin/env bash
# Install/uninstall aap-demo command and shell completions
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"

case "$(uname -s)" in
  Linux | Darwin) ;;
  *)
    echo "ERROR: Use powershell/install.ps1 on Windows; see Windows_Quickstart.md."
    exit 1
    ;;
esac

install_oc() (
  local platform arch archive tmp expected actual
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64 | Darwin:aarch64) platform=mac-arm64 ;;
    Darwin:x86_64) platform=mac ;;
    Linux:x86_64) platform=linux ;;
    Linux:aarch64 | Linux:arm64) platform=linux-arm64 ;;
    *) echo "ERROR: No oc download configured for $(uname -sm)" >&2; exit 1 ;;
  esac
  archive="openshift-client-${platform}.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' EXIT
  curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/$archive" \
    -o "$tmp/$archive" || exit 1
  curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/sha256sum.txt" \
    -o "$tmp/checksums" || exit 1
  expected=$(awk -v file="$archive" '$2 == file || $2 == "*" file {print $1}' "$tmp/checksums")
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
  fi
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "ERROR: Cannot verify the OpenShift client archive checksum" >&2
    exit 1
  fi
  tar -xzf "$tmp/$archive" -C "$tmp" || exit 1
  mkdir -p "$HOME/.local/bin" || exit 1
  for client in oc kubectl; do
    install -m 755 "$tmp/$client" "$HOME/.local/bin/$client" || exit 1
    if [ "$(uname -s)" = Darwin ]; then
      xattr -d com.apple.quarantine "$HOME/.local/bin/$client" 2>/dev/null || true
    fi
  done
)

install_kubectl() (
  local version arch tmp expected actual
  version=$(curl -fsSL https://dl.k8s.io/release/stable.txt) || exit 1
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "ERROR: Invalid Kubernetes release version" >&2; exit 1;
  }
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) echo "ERROR: Unsupported kubectl architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  tmp=$(mktemp -d) || exit 1
  trap 'rm -rf -- "$tmp"' EXIT
  curl -fsSL "https://dl.k8s.io/release/$version/bin/linux/$arch/kubectl" \
    -o "$tmp/kubectl" || exit 1
  expected=$(curl -fsSL "https://dl.k8s.io/release/$version/bin/linux/$arch/kubectl.sha256") || exit 1
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/kubectl" | awk '{print $1}') || exit 1
  else
    actual=$(shasum -a 256 "$tmp/kubectl" | awk '{print $1}') || exit 1
  fi
  [ "$expected" = "$actual" ] || { echo "ERROR: kubectl checksum mismatch" >&2; exit 1; }
  mkdir -p "$HOME/.local/bin" || exit 1
  install -m 755 "$tmp/kubectl" "$HOME/.local/bin/kubectl"
)

CLI_LINK="$HOME/.local/bin/aap-demo"

# True when ~/.local/bin/aap-demo is the Python command (pipx or pip), not a
# link to this checkout's aap-demo.sh. install.sh must not replace or remove it.
# pip writes a python shebang or, when the interpreter path has a space or is
# too long for a shebang (pipx on macOS lives under "Application Support"), a
# /bin/sh wrapper whose second line execs that python.
python_cli_installed() {
  local first="" second=""
  [ -f "$CLI_LINK" ] || return 1
  { IFS= read -r first && IFS= read -r second; } <"$CLI_LINK" 2>/dev/null || true
  case "$first" in
    '#!'*python*) return 0 ;;
  esac
  case "$first" in
    '#!/bin/sh'*) case "$second" in "'''exec' "*python*) return 0 ;; esac ;;
  esac
  return 1
}

python_cli_note() {
  echo "  ~/.local/bin/aap-demo is the Python aap-demo command. Leaving it in place."
  echo "  The bash script still runs directly: ${SCRIPT_DIR}/aap-demo.sh"
  echo "  To switch back to bash, remove it with the tool that installed it, then rerun install.sh:"
  echo "    pipx uninstall aap-demo   (or: pip uninstall aap-demo)"
  echo "    ${SCRIPT_DIR}/install.sh"
}

# Uninstall
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
  echo "Uninstalling aap-demo..."
  # The completions belong to the bash command, so they go either way.
  rm -f ~/.zsh/completions/_aap-demo
  rm -f ~/.local/share/bash-completion/completions/aap-demo
  if [ -f ~/.bashrc ]; then
    sed -i.bak \
      '/^# >>> aap-demo bash completion >>>$/,/^# <<< aap-demo bash completion <<<$/d' \
      ~/.bashrc
    sed -i.bak \
      '/^# >>> aap-demo PATH >>>$/,/^# <<< aap-demo PATH <<<$/d' \
      ~/.bashrc
    rm -f ~/.bashrc.bak
  fi
  if python_cli_installed; then
    echo "  ✓ Bash completions removed"
    python_cli_note
  else
    rm -f "$CLI_LINK"
    echo "  ✓ Binary and completions removed"
  fi
  if [ -f "${AAP_DEMO_CONFIG:-$HOME/.aap-demo/config}" ]; then
    config_file="${AAP_DEMO_CONFIG:-$HOME/.aap-demo/config}"
    sed -i.bak '/^ADDONS=/d' "$config_file"
    rm -f "${config_file}.bak"
    echo "  ✓ Enabled addon state removed from ${config_file}"
  fi
  echo ""
  echo "  CRC data at ~/.crc/ and demo data at ~/.aap-demo/ were NOT removed."
  echo "  Use 'aap-demo maintenance uninstall' before removing the launcher for full removal."
  exit 0
fi

echo "Installing aap-demo..."
echo ""

if python_cli_installed; then
  python_cli_note
  exit 0
fi

# Check dependencies
MISSING_DEPS=""

if ! command -v oc &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS oc"
fi

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

fi

# Auto-install missing dependencies
if [ -n "$MISSING_DEPS" ]; then
  echo "Missing dependencies:$MISSING_DEPS"
  echo ""

  if [[ "$(uname)" == "Darwin" ]]; then
    echo "Installing via Homebrew and OpenShift mirror..."
    for dep in $MISSING_DEPS; do
      case "$dep" in
        oc) install_oc ;;
        kubectl)
          # Skip if already installed via oc
          if command -v kubectl &>/dev/null; then
            echo "✓ kubectl already available"
          else
            brew install kubectl
          fi
          ;;
        ansible)
          brew install ansible
          ;;
        jq)
          brew install jq
          ;;
        python3)
          brew install python3
          ;;
      esac
    done
  else
    # Auto-install on Linux
    echo "Installing missing dependencies..."
    for dep in $MISSING_DEPS; do
      case "$dep" in
        oc) install_oc ;;
        kubectl)
          command -v kubectl >/dev/null 2>&1 && continue
          install_kubectl
          ;;
        ansible | jq | python3)
          # Try package manager
          if command -v dnf &>/dev/null; then
            PKG_CMD="sudo dnf install -y"
            case "$dep" in
              ansible) PKG="ansible-core" ;;
              *) PKG="$dep" ;;
            esac
          elif command -v apt &>/dev/null; then
            PKG_CMD="sudo apt install -y"
            PKG="$dep"
          else
            echo "ERROR: No supported package manager (dnf/apt) found for $dep"
            exit 1
          fi
          echo "Installing $dep via package manager..."
          $PKG_CMD $PKG || {
            echo "ERROR: Failed to install $dep"
            exit 1
          }
          ;;
      esac
    done
  fi

  echo ""
  echo "  ✓ Dependencies installed"
  echo ""
fi

for tool in oc kubectl ansible-playbook jq python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: Required tool is still missing after installation: $tool" >&2
    exit 1
  }
done
echo "  ✓ All required dependencies found"
echo ""

# Create ~/.local/bin if needed
mkdir -p ~/.local/bin

# Create symlink
ln -sf "${SCRIPT_DIR}/aap-demo.sh" ~/.local/bin/aap-demo
echo "  Symlink: ~/.local/bin/aap-demo -> ${SCRIPT_DIR}/aap-demo.sh"

# Detect OS and install completions
SHELL_NAME=$(basename "${SHELL:-/bin/bash}")

# Install Bash completion on every supported platform, regardless of the current
# login shell, so switching to Bash does not require reinstalling aap-demo.
mkdir -p ~/.local/share/bash-completion/completions
cp "${SCRIPT_DIR}/scripts/aap-demo-completion.bash" ~/.local/share/bash-completion/completions/aap-demo
echo "  Completion: ~/.local/share/bash-completion/completions/aap-demo (bash)"

if ! grep -q '^# >>> aap-demo PATH >>>$' ~/.bashrc 2>/dev/null; then
  cat >>~/.bashrc <<'EOF'

# >>> aap-demo PATH >>>
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< aap-demo PATH <<<
EOF
  echo "  Added ~/.local/bin to PATH in ~/.bashrc"
fi

if ! grep -q '^# >>> aap-demo bash completion >>>$' ~/.bashrc 2>/dev/null; then
  cat >>~/.bashrc <<'EOF'

# >>> aap-demo bash completion >>>
if [ -r "$HOME/.local/share/bash-completion/completions/aap-demo" ]; then
  source "$HOME/.local/share/bash-completion/completions/aap-demo"
fi
# <<< aap-demo bash completion <<<
EOF
  echo "  Added Bash completion loader to ~/.bashrc"
fi

if [ "$(uname)" = "Darwin" ]; then
  # macOS: also install zsh completion because zsh is the default shell.
  mkdir -p ~/.zsh/completions
  cp "${SCRIPT_DIR}/scripts/aap-demo-completion.zsh" ~/.zsh/completions/_aap-demo
  echo "  Completion: ~/.zsh/completions/_aap-demo (zsh)"

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
  fi
fi

echo ""
echo "Done. Completion will load automatically in new shell sessions."
echo "Load it in this shell with:"
if [ "$SHELL_NAME" = "zsh" ]; then
  echo "  exec zsh"
else
  echo "  source ~/.${SHELL_NAME}rc"
fi
echo ""
echo "Then run 'aap-demo help' to get started."
