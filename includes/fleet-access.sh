#!/usr/bin/env bash

if [ -n "${_FLEET_ACCESS_LOADED:-}" ]; then return 0; fi
_FLEET_ACCESS_LOADED=1
FLEET_ACCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credential-vault.sh
source "${FLEET_ACCESS_DIR}/credential-vault.sh"
# shellcheck source=fleet-stack.sh
source "${FLEET_ACCESS_DIR}/fleet-stack.sh"

fleet_admin_password() {
  local index="$1"
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || { _err "Invalid Fleet node index"; return 1; }
  aap_demo_vault_get "aap_demo.fleet.node_${index}.password"
}

fleet_reconcile_access() {
  local index="$1" root="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet"
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || { _err "Invalid Fleet node index"; return 1; }
  local port password hash rc=0 guest_ip
  port=$(sed -n 's/^PORT=//p' "$root/node-$index/meta")
  [[ "$port" =~ ^[0-9]+$ ]] || { _err "Invalid Fleet SSH port"; return 1; }
  _aap_demo_vault_require_tools || return 1
  password=$(fleet_admin_password "$index") || rc=$?
  [ "$rc" -ne 2 ] || return 1
  if [ -z "$password" ]; then
    password=$("$AAP_DEMO_VAULT_PYTHON" -c 'import secrets; print(secrets.token_urlsafe(24))') || return 1
    aap_demo_vault_set "aap_demo.fleet.node_${index}.password" "$password" || return 1
  fi
  hash=$(printf '%s\n' "$password" | openssl passwd -6 -stdin) || return 1
  unset password
  # Only the password hash crosses SSH stdin; no secrets enter child-process arguments.
  if ! {
    printf 'set -e\n'
    printf 'password_hash=%q\n' "$hash"
    cat <<'REMOTE'
id admin >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash admin
sudo usermod --shell /bin/bash admin
printf 'admin:%s\n' "$password_hash" | sudo chpasswd -e
sudo install -d -m 700 -o admin -g admin /home/admin/.ssh
sudo touch /home/admin/.ssh/authorized_keys
while IFS= read -r key; do
  sudo grep -Fxq -- "$key" /home/admin/.ssh/authorized_keys ||
    printf '%s\n' "$key" | sudo tee -a /home/admin/.ssh/authorized_keys >/dev/null
done <"$HOME/.ssh/authorized_keys"
sudo chown admin:admin /home/admin/.ssh/authorized_keys
sudo chmod 600 /home/admin/.ssh/authorized_keys
if command -v restorecon >/dev/null; then sudo restorecon -R /home/admin/.ssh; fi
case " $(id -nG admin) " in
  *" wheel "*) sudo gpasswd -d admin wheel >/dev/null ;;
esac
sudo_file=$(mktemp)
printf 'admin     ALL=(ALL)       ALL\n' >"$sudo_file"
sudo visudo -cf "$sudo_file" >/dev/null
sudo install -m 440 -o root -g root "$sudo_file" /etc/sudoers.d/aap-demo-admin
rm -f "$sudo_file"
sudo visudo -c >/dev/null
if ! sudo test -f /home/admin/.ssh/id_ed25519; then
  sudo -u admin ssh-keygen -q -t ed25519 -N '' -f /home/admin/.ssh/id_ed25519 -C "admin@$(hostname)"
fi
if ! sudo test -f /home/admin/.ssh/id_ed25519.pub; then
  sudo -u admin sh -c 'ssh-keygen -y -f "$HOME/.ssh/id_ed25519" >"$HOME/.ssh/id_ed25519.pub"'
fi
sudo chown admin:admin /home/admin/.ssh/id_ed25519 /home/admin/.ssh/id_ed25519.pub
sudo chmod 600 /home/admin/.ssh/id_ed25519
sudo chmod 644 /home/admin/.ssh/id_ed25519.pub
if command -v restorecon >/dev/null; then sudo restorecon -R /home/admin/.ssh; fi
# A Match block permits password login for admin without enabling it for every account.
ssh_config=$(mktemp)
printf 'Match User admin\n    PasswordAuthentication yes\nMatch all\n' >"$ssh_config"
if ! sudo cmp -s "$ssh_config" /etc/ssh/sshd_config.d/00-aap-demo-admin.conf; then
  sudo install -m 644 -o root -g root "$ssh_config" /etc/ssh/sshd_config.d/00-aap-demo-admin.conf
  sudo sshd -t
  sudo systemctl reload sshd
fi
rm -f "$ssh_config"
REMOTE
  } | ssh -p "$port" -i "$root/ssh_key" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$root/known_hosts" \
    -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes \
    ansible@127.0.0.1 'bash -s'; then
    _err "Could not configure admin SSH access for Fleet node $index"
    return 1
  fi
  guest_ip=$(ssh -p "$port" -i "$root/ssh_key" \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$root/known_hosts" \
    -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes \
    admin@127.0.0.1 "hostname -I | awk '{print \$1}'") || return 1
  printf '%s\n' "$guest_ip" >"$root/node-$index/guest_ip"
  printf '  ✓ Fleet node %s: admin SSH ready at 127.0.0.1:%s (guest %s)\n' "$index" "$port" "$guest_ip"
}

fleet_reconcile_running_access() {
  local root="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet" meta index pid
  for meta in "$root"/node-*/meta; do
    [ -f "$meta" ] || continue
    index=$(sed -n 's/^INDEX=//p' "$meta")
    pid=$(sed -n 's/^PID=//p' "$meta")
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      fleet_reconcile_access "$index" || return 1
    fi
  done
}

fleet_access_inventory() {
  local mode="${1:-omit}" root="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet"
  local result='[]' meta index port hostname pid state guest_ip password rc
  for meta in "$root"/node-*/meta; do
    [ -f "$meta" ] || continue
    index=$(sed -n 's/^INDEX=//p' "$meta")
    port=$(sed -n 's/^PORT=//p' "$meta")
    hostname=$(sed -n 's/^HOSTNAME=//p' "$meta")
    pid=$(sed -n 's/^PID=//p' "$meta")
    [[ "$index" =~ ^[1-9][0-9]*$ ]] && [[ "$port" =~ ^[0-9]+$ ]] || {
      _err "Invalid Fleet metadata: $meta"; return 1;
    }
    state=stopped
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then state=running; fi
    guest_ip=""
    [ ! -f "$root/node-$index/guest_ip" ] || guest_ip=$(cat "$root/node-$index/guest_ip")
    password=""
    case "$mode" in
      include)
        rc=0
        password=$(fleet_admin_password "$index") || rc=$?
        [ "$rc" -ne 2 ] || return 1
        ;;
      redact) password='******' ;;
      omit) ;;
      *) _err "Invalid Fleet secret mode"; return 1 ;;
    esac
    result=$(jq -c --argjson index "$index" --argjson port "$port" \
      --arg hostname "$hostname" --arg state "$state" --arg guest_ip "$guest_ip" \
      --arg password "$password" \
      '. + [{index:$index, hostname:$hostname, state:$state, ssh_host:"127.0.0.1",
        ssh_port:$port, guest_ip:(if $guest_ip == "" then null else $guest_ip end),
        username:"admin", password:(if $password == "" then null else $password end),
        terminal_url:("/terminal?node=" + ($index|tostring))}]' <<<"$result") || return 1
  done
  printf '%s\n' "$result"
}

fleet_reconcile_existing_inventory() {
  local nodes
  nodes=$(fleet_access_inventory omit) || return 1
  if jq -e 'any(.[]; .state == "running")' <<<"$nodes" >/dev/null; then
    bash "${FLEET_ACCESS_DIR}/../aap-demo.sh" fleet register
  elif [ "$nodes" != '[]' ]; then
    printf 'Fleet nodes are stopped; start them before reconciling the AAP inventory.\n'
  fi
}
