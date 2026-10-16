#!/bin/bash
# Process inside a fleet pod. The CLI does not execute this file.
set -euo pipefail

. /etc/os-release

if ! command -v sshd >/dev/null 2>&1; then
  case "${ID}" in
    debian)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server python3 sudo
      ;;
    *)
      dnf install -y openssh-server python3 sudo
      ;;
  esac
fi

if ! id ansible >/dev/null 2>&1; then
  useradd -m -s /bin/bash ansible
fi
echo "ansible ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/ansible
chmod 440 /etc/sudoers.d/ansible

install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
cp /etc/fleet/authorized_keys /home/ansible/.ssh/authorized_keys
chown ansible:ansible /home/ansible/.ssh/authorized_keys
chmod 600 /home/ansible/.ssh/authorized_keys

ssh-keygen -A
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e
