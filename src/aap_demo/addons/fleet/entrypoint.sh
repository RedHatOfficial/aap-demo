#!/bin/bash
# Process inside a fleet pod. The CLI does not execute this file.
set -euo pipefail

# Copy the image's package paths onto an empty disk once. The main
# container then mounts those paths, so a later dnf or apt install
# survives a new pod. /etc stays on the image so cluster DNS still works.
if [[ ${1:-} == seed ]]; then
  marker=/mnt/disk/.seeded
  if [[ ! -f ${marker} ]]; then
    mkdir -p /mnt/disk/usr /mnt/disk/var
    tar -C /usr -cf - . | tar -C /mnt/disk/usr -xpf -
    tar -C /var -cf - . | tar -C /mnt/disk/var -xpf -
    touch "${marker}"
  fi
  exit 0
fi

. /etc/os-release

# /etc comes from the image on every start. Packages installed later keep
# their files under /usr and /var, so config that the package dropped in
# /etc has to be restored before sshd and sudo can run again.
if [[ ${ID} == debian ]]; then
  if ! command -v sshd >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server python3 sudo
  elif [[ ! -f /etc/ssh/sshd_config || ! -d /etc/sudoers.d ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall openssh-server sudo
  fi
else
  if ! command -v sshd >/dev/null 2>&1; then
    dnf install -y openssh-server python3 sudo
  elif [[ ! -f /etc/ssh/sshd_config || ! -d /etc/sudoers.d ]]; then
    # rpm --restore only resets ownership. Reinstall puts the config files back.
    dnf reinstall -y openssh-server sudo
  fi
fi
mkdir -p /etc/ssh /etc/sudoers.d

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
