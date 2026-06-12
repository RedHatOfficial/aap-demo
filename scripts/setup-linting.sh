#!/usr/bin/env bash
# Setup script for installing all linting tools and dependencies

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

check_command() {
  if command -v "$1" &>/dev/null; then
    info "✓ $1 is already installed"
    return 0
  else
    warn "✗ $1 is not installed"
    return 1
  fi
}

install_python_tools() {
  info "Installing Python linting tools in virtual environment..."

  # Find best Python version (prefer 3.10+ for ansible-lint)
  local PYTHON_CMD=""
  for py in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$py" &>/dev/null; then
      PYTHON_CMD="$py"
      break
    fi
  done

  if [ -z "$PYTHON_CMD" ]; then
    error "Python 3 not found. Please install Python 3.10+ first."
    exit 1
  fi

  local PY_VERSION
  PY_VERSION=$($PYTHON_CMD -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  info "Using $PYTHON_CMD ($PY_VERSION)"

  # Create venv for linting tools
  local VENV_DIR=".venv-lint"
  if [ -d "$VENV_DIR" ]; then
    info "Removing existing $VENV_DIR"
    rm -rf "$VENV_DIR"
  fi

  $PYTHON_CMD -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  pip install --upgrade pip

  # Install core tools
  pip install \
    pre-commit \
    yamllint \
    detect-secrets \
    commitizen

  # Try ansible-lint (will fail gracefully if Python < 3.10)
  if pip install ansible-lint 2>/dev/null; then
    info "✓ ansible-lint installed"
  else
    warn "Skipping ansible-lint (requires Python 3.10+, found $PY_VERSION)"
  fi

  deactivate

  info "✓ Python tools installed in $VENV_DIR"
  info "  Activate with: source $VENV_DIR/bin/activate"
}

install_node_tools() {
  info "Installing Node.js linting tools..."

  if ! command -v npm &>/dev/null; then
    warn "npm is not installed. Skipping Node.js tools."
    warn "Install Node.js 20+ to enable commitlint and markdownlint"
    return 0
  fi

  npm install -g \
    markdownlint-cli \
    @commitlint/cli \
    @commitlint/config-conventional

  info "✓ Node.js tools installed"
}

install_shellcheck() {
  info "Installing ShellCheck..."

  if check_command shellcheck; then
    return 0
  fi

  case "$(uname -s)" in
    Darwin*)
      if command -v brew &>/dev/null; then
        brew install shellcheck
      else
        warn "Homebrew not found. Please install ShellCheck manually:"
        warn "  https://github.com/koalaman/shellcheck#installing"
      fi
      ;;
    Linux*)
      if command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y shellcheck
      elif command -v yum &>/dev/null; then
        sudo yum install -y ShellCheck
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y ShellCheck
      else
        warn "Package manager not recognized. Please install ShellCheck manually:"
        warn "  https://github.com/koalaman/shellcheck#installing"
      fi
      ;;
    *)
      warn "OS not recognized. Please install ShellCheck manually:"
      warn "  https://github.com/koalaman/shellcheck#installing"
      ;;
  esac

  check_command shellcheck && info "✓ ShellCheck installed" || warn "ShellCheck installation may have failed"
}

install_shfmt() {
  info "Installing shfmt..."

  if check_command shfmt; then
    return 0
  fi

  case "$(uname -s)" in
    Darwin*)
      if command -v brew &>/dev/null; then
        brew install shfmt
      else
        warn "Homebrew not found. Please install shfmt manually:"
        warn "  https://github.com/mvdan/sh#shfmt"
      fi
      ;;
    Linux*)
      local ARCH
      ARCH="$(uname -m)"
      case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
      esac

      local VERSION="v3.8.0"
      local URL="https://github.com/mvdan/sh/releases/download/${VERSION}/shfmt_${VERSION}_linux_${ARCH}"

      warn "Downloading shfmt to /usr/local/bin (may require sudo)..."
      sudo curl -fsSL "$URL" -o /usr/local/bin/shfmt
      sudo chmod +x /usr/local/bin/shfmt
      ;;
    *)
      warn "OS not recognized. Please install shfmt manually:"
      warn "  https://github.com/mvdan/sh#shfmt"
      ;;
  esac

  check_command shfmt && info "✓ shfmt installed" || warn "shfmt installation may have failed"
}

install_kubeconform() {
  info "Installing kubeconform..."

  if check_command kubeconform; then
    return 0
  fi

  local ARCH
  ARCH="$(uname -m)"

  case "$(uname -s)" in
    Darwin*)
      case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        arm64) ARCH="arm64" ;;
      esac
      local URL="https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-darwin-${ARCH}.tar.gz"
      ;;
    Linux*)
      case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
      esac
      local URL="https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-${ARCH}.tar.gz"
      ;;
    *)
      warn "OS not recognized. Skipping kubeconform installation."
      return
      ;;
  esac

  curl -fsSL "$URL" | tar -xz
  sudo mv kubeconform /usr/local/bin/
  check_command kubeconform && info "✓ kubeconform installed" || warn "kubeconform installation may have failed"
}

setup_pre_commit_hooks() {
  info "Setting up pre-commit hooks..."

  # Activate venv if it exists
  if [ -d ".venv-lint" ]; then
    # shellcheck disable=SC1091
    source .venv-lint/bin/activate
  fi

  if ! command -v pre-commit &>/dev/null; then
    error "pre-commit not found. Run ./scripts/setup-linting.sh to install."
    exit 1
  fi

  pre-commit install --hook-type pre-commit --hook-type commit-msg

  # Patch hooks to auto-activate venv
  for hook in .git/hooks/pre-commit .git/hooks/commit-msg; do
    if [ -f "$hook" ]; then
      # Add venv activation at the start if not already present
      if ! grep -q "venv-lint" "$hook"; then
        sed -i.bak '2i\
# Auto-activate venv for linting tools\
[ -f .venv-lint/bin/activate ] && source .venv-lint/bin/activate\
' "$hook" && rm -f "$hook.bak"
      fi
    fi
  done

  [ -d ".venv-lint" ] && deactivate

  info "✓ Pre-commit hooks installed (auto-activate .venv-lint)"
}

verify_installation() {
  info "Verifying installation..."
  echo ""

  # Activate venv for Python tools check
  if [ -d ".venv-lint" ]; then
    # shellcheck disable=SC1091
    source .venv-lint/bin/activate
  fi

  local FAILED=0

  echo "Checking installed tools:"
  echo ""

  for tool in pre-commit shellcheck shfmt yamllint markdownlint ansible-lint detect-secrets kubeconform; do
    if command -v "$tool" &>/dev/null; then
      echo "  ✓ $tool"
    else
      echo "  ✗ $tool (optional)"
      FAILED=$((FAILED + 1))
    fi
  done

  [ -d ".venv-lint" ] && deactivate

  echo ""

  if [ $FAILED -eq 0 ]; then
    info "All tools installed successfully!"
  else
    warn "$FAILED optional tools are not installed"
    warn "The linting setup will work, but some checks may be skipped"
  fi
}

main() {
  echo ""
  info "Setting up linting tools for aap-demo"
  echo ""

  # Core tools
  install_shellcheck
  install_shfmt
  install_python_tools

  # Optional tools
  install_node_tools
  install_kubeconform

  # Setup hooks
  setup_pre_commit_hooks

  # Verify
  verify_installation

  echo ""
  info "Setup complete!"
  echo ""
  echo "Python linting tools installed in .venv-lint/"
  echo "Pre-commit hooks will auto-activate the venv when needed."
  echo ""
  echo "To use linting tools manually:"
  echo "  source .venv-lint/bin/activate"
  echo ""
  echo "Next steps:"
  echo "  1. Run 'pre-commit run --all-files' to test the setup"
  echo "  2. Run 'make lint' to run all linters manually"
  echo "  3. See docs/LINTING.md for detailed usage instructions"
  echo ""
}

main "$@"
