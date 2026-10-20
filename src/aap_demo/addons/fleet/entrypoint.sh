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

# /etc stays off the disk mount so the pod keeps cluster DNS. A copy of
# everything else in /etc lives under /var, which is on the disk.
ETC_SAVE=/var/lib/fleet-etc

restore_etc() {
  [[ -d ${ETC_SAVE} ]] || return 0
  cp -a /etc/resolv.conf /tmp/fleet-resolv.conf
  cp -a /etc/hosts /tmp/fleet-hosts
  if [[ -f /etc/hostname ]]; then
    cp -a /etc/hostname /tmp/fleet-hostname
  fi
  cp -a "${ETC_SAVE}/." /etc/
  cp -a /tmp/fleet-resolv.conf /etc/resolv.conf
  cp -a /tmp/fleet-hosts /etc/hosts
  if [[ -f /tmp/fleet-hostname ]]; then
    cp -a /tmp/fleet-hostname /etc/hostname
  fi
}

save_etc() {
  mkdir -p "${ETC_SAVE}"
  find "${ETC_SAVE}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -C /etc \
    --exclude=resolv.conf \
    --exclude=hosts \
    --exclude=hostname \
    --exclude=fleet \
    -cf - . | tar -C "${ETC_SAVE}" -xpf -
}

# dpkg's statoverride file is on the disk, but the groups it names were
# created in /etc and disappeared with the previous pod.
fix_debian_overrides() {
  [[ ${ID} == debian && -f /var/lib/dpkg/statoverride ]] || return 0
  while read -r user group _mode _path; do
    [[ -z ${group} || ${group} == \#* ]] && continue
    getent group "${group}" >/dev/null 2>&1 || groupadd --system "${group}" || true
    if [[ -n ${user} && ${user} != root ]] && ! id "${user}" >/dev/null 2>&1; then
      useradd --system --no-create-home --gid "${group}" "${user}" || true
    fi
  done </var/lib/dpkg/statoverride
}

restore_etc
fix_debian_overrides

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
install -d -m 755 -o ansible -g ansible /home/ansible
echo "ansible ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/ansible
chmod 440 /etc/sudoers.d/ansible

install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
cp /etc/fleet/authorized_keys /home/ansible/.ssh/authorized_keys
chown ansible:ansible /home/ansible/.ssh/authorized_keys
chmod 600 /home/ansible/.ssh/authorized_keys

ssh-keygen -A
mkdir -p /run/sshd
save_etc
exec /usr/sbin/sshd -D -e
