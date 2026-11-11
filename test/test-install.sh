#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$TEST_HOME/.aap-demo"
cat >"$TEST_HOME/.aap-demo/config" <<'EOF'
INFRA=crc
ADDONS=ao,portal
EOF

HOME="$TEST_HOME" bash "$SCRIPT_DIR/install.sh" --uninstall >/dev/null

grep -q '^INFRA=crc$' "$TEST_HOME/.aap-demo/config"
if grep -q '^ADDONS=' "$TEST_HOME/.aap-demo/config"; then
  echo "ADDONS state was not removed during uninstall" >&2
  exit 1
fi

echo "✓ uninstall_clears_addon_state"

eval "$(sed -n '/^install_oc() (/,/^)/p' "$SCRIPT_DIR/install.sh")"
eval "$(sed -n '/^install_kubectl() (/,/^)/p' "$SCRIPT_DIR/install.sh")"
mkdir -p "$TEST_HOME/fixture"
printf '#!/bin/sh\nexit 0\n' >"$TEST_HOME/fixture/oc"
cp "$TEST_HOME/fixture/oc" "$TEST_HOME/fixture/kubectl"
tar -czf "$TEST_HOME/clients.tar.gz" -C "$TEST_HOME/fixture" oc kubectl
EXPECTED_HASH=$(shasum -a 256 "$TEST_HOME/clients.tar.gz" | awk '{print $1}')
CLIENT_HASH=$(shasum -a 256 "$TEST_HOME/fixture/kubectl" | awk '{print $1}')
KUBE_VERSION=v1.34.0
HOST_OS=Linux
HOST_ARCH=x86_64
BAD_CHECKSUM=false
DOWNLOAD_FAILURE=false
uname() {
  case "$1" in -s) echo "$HOST_OS" ;; -m) echo "$HOST_ARCH" ;; esac
}
xattr() { return 0; }
curl() {
  [ "$DOWNLOAD_FAILURE" != true ] || return 1
  local url="$2" dest="${4:-}"
  case "$url" in
    */stable.txt) echo "$KUBE_VERSION" ;;
    */kubectl.sha256)
      if [ "$BAD_CHECKSUM" = true ]; then echo invalid; else echo "$CLIENT_HASH"; fi
      ;;
    */kubectl)
      [[ "$url" == *"/linux/$CLIENT_ARCH/kubectl" ]] || return 1
      cp "$TEST_HOME/fixture/kubectl" "$dest"
      ;;
    */sha256sum.txt)
      local hash="$EXPECTED_HASH"
      [ "$BAD_CHECKSUM" != true ] || hash=invalid
      printf '%s  %s\n' "$hash" "$ARCHIVE" >"$dest"
      ;;
    *)
      [[ "$url" == *"/$ARCHIVE" ]] || return 1
      cp "$TEST_HOME/clients.tar.gz" "$dest"
      ;;
  esac
}
for platform in Linux:x86_64:linux Linux:aarch64:linux-arm64 \
  Darwin:x86_64:mac Darwin:arm64:mac-arm64; do
  IFS=: read -r HOST_OS HOST_ARCH suffix <<<"$platform"
  ARCHIVE="openshift-client-${suffix}.tar.gz"
  HOME="$TEST_HOME" install_oc
  test -x "$TEST_HOME/.local/bin/oc"
  test -x "$TEST_HOME/.local/bin/kubectl"
done
echo "✓ architecture-specific Linux/macOS oc and kubectl installation"
if BAD_CHECKSUM=true HOME="$TEST_HOME" install_oc >/dev/null 2>&1; then
  echo "FAIL: invalid client checksum accepted" >&2; exit 1
fi
if DOWNLOAD_FAILURE=true HOME="$TEST_HOME" install_oc >/dev/null 2>&1; then
  echo "FAIL: failed client download accepted" >&2; exit 1
fi
echo "✓ download and checksum failures are explicit"

HOST_OS=Linux
for platform in x86_64:amd64 aarch64:arm64; do
  IFS=: read -r HOST_ARCH CLIENT_ARCH <<<"$platform"
  HOME="$TEST_HOME" install_kubectl
  test -x "$TEST_HOME/.local/bin/kubectl"
done
if BAD_CHECKSUM=true HOME="$TEST_HOME" install_kubectl >/dev/null 2>&1; then
  echo "FAIL: invalid kubectl checksum accepted" >&2; exit 1
fi
if KUBE_VERSION=invalid HOME="$TEST_HOME" install_kubectl >/dev/null 2>&1; then
  echo "FAIL: invalid Kubernetes release accepted" >&2; exit 1
fi
echo "✓ verified standalone kubectl installation and release validation"

# The Python command (pipx) owns ~/.local/bin/aap-demo: install and uninstall
# must leave it alone.
PY_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME" "$PY_HOME"' EXIT
mkdir -p "$PY_HOME/venv/bin" "$PY_HOME/.local/bin"
printf '#!%s\nprint("python")\n' "$PY_HOME/venv/bin/python" >"$PY_HOME/venv/bin/aap-demo"
chmod +x "$PY_HOME/venv/bin/aap-demo"
ln -s "$PY_HOME/venv/bin/aap-demo" "$PY_HOME/.local/bin/aap-demo"

out="$(HOME="$PY_HOME" bash "$SCRIPT_DIR/install.sh" 2>&1)"
if [ "$(readlink "$PY_HOME/.local/bin/aap-demo")" != "$PY_HOME/venv/bin/aap-demo" ]; then
  echo "install.sh replaced the Python command" >&2
  exit 1
fi
grep -q 'pipx uninstall aap-demo' <<<"$out"
echo "✓ install_keeps_python_cli"

mkdir -p "$PY_HOME/.zsh/completions"
touch "$PY_HOME/.zsh/completions/_aap-demo"
HOME="$PY_HOME" bash "$SCRIPT_DIR/install.sh" --uninstall >/dev/null
[ -L "$PY_HOME/.local/bin/aap-demo" ] || {
  echo "uninstall removed the Python command" >&2
  exit 1
}
[ ! -e "$PY_HOME/.zsh/completions/_aap-demo" ] || {
  echo "uninstall left the bash completions" >&2
  exit 1
}
echo "✓ uninstall_keeps_python_cli"

# A link to the bash script is still removed by uninstall.
rm "$PY_HOME/.local/bin/aap-demo"
ln -s "$SCRIPT_DIR/aap-demo.sh" "$PY_HOME/.local/bin/aap-demo"
HOME="$PY_HOME" bash "$SCRIPT_DIR/install.sh" --uninstall >/dev/null
if [ -e "$PY_HOME/.local/bin/aap-demo" ] || [ -L "$PY_HOME/.local/bin/aap-demo" ]; then
  echo "uninstall left the bash link" >&2
  exit 1
fi
echo "✓ uninstall_removes_bash_link"

# pip's /bin/sh wrapper, used when the interpreter path has a space (pipx on
# macOS lives under "Application Support"), is the Python command too.
SH_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME" "$PY_HOME" "$SH_HOME"' EXIT
SH_BIN="$SH_HOME/Application Support/venv/bin"
mkdir -p "$SH_BIN" "$SH_HOME/.local/bin"
cat >"$SH_BIN/aap-demo" <<WRAPPER
#!/bin/sh
'''exec' "$SH_BIN/python" "\$0" "\$@"
' '''
WRAPPER
chmod +x "$SH_BIN/aap-demo"
ln -s "$SH_BIN/aap-demo" "$SH_HOME/.local/bin/aap-demo"

HOME="$SH_HOME" bash "$SCRIPT_DIR/install.sh" >/dev/null 2>&1
if [ "$(readlink "$SH_HOME/.local/bin/aap-demo")" != "$SH_BIN/aap-demo" ]; then
  echo "install.sh replaced the pip sh-wrapper command" >&2
  exit 1
fi
echo "✓ install_keeps_pip_sh_wrapper"

HOME="$SH_HOME" bash "$SCRIPT_DIR/install.sh" --uninstall >/dev/null
[ -L "$SH_HOME/.local/bin/aap-demo" ] || {
  echo "uninstall removed the pip sh-wrapper command" >&2
  exit 1
}
echo "✓ uninstall_keeps_pip_sh_wrapper"
