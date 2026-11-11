#version=RHEL9
# satellite-vm.ks — unattended RHEL 9 base for the Satellite server.
# Tokens __ROOTPW__ / __RHSM_*__ / __INSTALL_SOURCE__ are rendered by
# 01-provision-satellite-vm.sh.
text
eula --agreed
firstboot --disable
reboot
# Install source: __INSTALL_SOURCE__ is rendered to either nothing (DVD media
# install, the default) or a CDN line (boot.iso + network install from the Red
# Hat CDN, which registers via RHSM below before packages are pulled).
__INSTALL_SOURCE__
lang en_US.UTF-8
keyboard --vckeymap=us
timezone America/Denver --utc
rootpw __ROOTPW_HASH__ --iscrypted

# NIC1: libvirt 'default' network (NAT to host + upstream; DNS via host dnsmasq at .122.1)
network --device=52:54:00:5a:7e:01 --bootproto=static --ip=192.168.122.20 --netmask=255.255.255.0 --gateway=192.168.122.1 --nameserver=192.168.122.1 --hostname=satellite.demo.lab --activate
# NIC2: satlab provisioning segment (Satellite serves DHCP/DNS/TFTP here; no default route)
network --device=52:54:00:5a:7e:02 --bootproto=static --ip=192.168.150.10 --netmask=255.255.255.0 --nodefroute --activate

# --- Disk layout: minimal 40 GB OS disk; Pulp content lives on the host via NFS ---
# /boot 1G | / 32G | swap 4G | ~3G slack. /var/lib/pulp is mounted from the host
# NFS export (see 00b-host-nfs-storage.sh) in %post so the VM disk stays small.
bootloader --location=mbr --boot-drive=vda
zerombr
clearpart --all --initlabel --drives=vda
part /boot --fstype=xfs --size=1024 --asprimary
part pv.01 --fstype=lvmpv --size=1 --grow
volgroup vg_sat pv.01
logvol /              --vgname=vg_sat --name=lv_root  --size=32768 --fstype=xfs
logvol swap           --vgname=vg_sat --name=lv_swap  --size=4096

%packages
@core
chrony
firewalld
nfs-utils
vim-enhanced
tmux
bash-completion
sos
tar
%end

%addon com_redhat_kdump --disable
%end

%post --log=/root/ks-post.log
# Write persistent NetworkManager keyfiles so the static IPs survive reboot.
# The kickstart `network --device=<MAC>` lines only configure the install
# environment (nm-initrd-generator); they do not persist reliably.
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/satlab-uplink.nmconnection <<'NMEOF'
[connection]
id=satlab-uplink
type=ethernet
autoconnect=true
[ethernet]
mac-address=52:54:00:5A:7E:01
[ipv4]
method=manual
address1=192.168.122.20/24,192.168.122.1
dns=192.168.122.1;
[ipv6]
method=disabled
NMEOF
cat > /etc/NetworkManager/system-connections/satlab-prov.nmconnection <<'NMEOF'
[connection]
id=satlab-prov
type=ethernet
autoconnect=true
[ethernet]
mac-address=52:54:00:5A:7E:02
[ipv4]
method=manual
address1=192.168.150.10/24
never-default=true
[ipv6]
method=disabled
NMEOF
chmod 600 /etc/NetworkManager/system-connections/*.nmconnection
# Remove the transient initrd-generated connections so they do not conflict.
rm -f /etc/NetworkManager/system-connections/ksdev0.nmconnection \
      /etc/NetworkManager/system-connections/enp*.nmconnection 2>/dev/null || true
# Install the host's SSH public key for root so the orchestrator can SSH in
# (RHEL 9 sshd defaults to PermitRootLogin prohibit-password, i.e. key-only).
# __HOST_SSH_PUBKEY__ is rendered by 01-provision-satellite-vm.sh.
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "__HOST_SSH_PUBKEY__" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
restorecon -R /root/.ssh 2>/dev/null || true
# Enable sshd (start is a no-op in chroot; it starts on first boot)
systemctl enable sshd

echo "Kickstart %post complete" > /root/KICKSTART_DONE

# RHSM registration + repo setup run post-boot over SSH (see
# build-and-configure.sh _stage_register) where errors are visible
# POSTBOOT: if [ -n "__RHSM_AK__" ]; then
# POSTBOOT:   subscription-manager register --org="__RHSM_ORG__" --activationkey="__RHSM_AK__"
# POSTBOOT: else
# POSTBOOT:   subscription-manager register --username="__RHSM_USER__" --password="__RHSM_PASS__" --auto-attach
# POSTBOOT: fi

# Attach only what Satellite 6.17 on RHEL 9 needs (adjust SAT_VER as required)
# POSTBOOT: subscription-manager repos --disable='*'
# POSTBOOT: subscription-manager repos \
# POSTBOOT:   --enable=rhel-9-for-x86_64-baseos-rpms \
# POSTBOOT:   --enable=rhel-9-for-x86_64-appstream-rpms \
# POSTBOOT:   --enable=satellite-6.17-for-rhel-9-x86_64-rpms \
# POSTBOOT:   --enable=satellite-maintenance-6.17-for-rhel-9-x86_64-rpms

# FQDN must resolve locally for the installer
# POSTBOOT: echo "192.168.150.10 satellite.demo.lab satellite" >> /etc/hosts

# Mount /var/lib/pulp from the host NFS export (keeps the VM OS disk small).
# The host is reachable at the default-net gateway. NFSv4 does not need
# rpc.mountd, so attempt the mount directly rather than relying on showmount.
# The mount is added to fstab with _netdev so it mounts after networking.
# POSTBOOT: HOST_GW=192.168.122.1
# POSTBOOT: NFS_EXPORT=/var/lib/satlab/pulp
# POSTBOOT: mkdir -p /var/lib/pulp
# POSTBOOT: mounted=0
# POSTBOOT: for i in $(seq 1 30); do
# POSTBOOT:   if mount -t nfs4 -o rw,sync,hard,intr "$HOST_GW:$NFS_EXPORT" /var/lib/pulp 2>/dev/null; then
# POSTBOOT:     mounted=1
# POSTBOOT:     break
# POSTBOOT:   fi
# POSTBOOT:   sleep 2
# POSTBOOT: done
# POSTBOOT: if [ "$mounted" = 1 ]; then
# POSTBOOT:   grep -q "$NFS_EXPORT" /etc/fstab || \
# POSTBOOT:     echo "$HOST_GW:$NFS_EXPORT /var/lib/pulp nfs4 rw,sync,hard,intr,_netdev 0 0" >> /etc/fstab
# POSTBOOT: else
# POSTBOOT:   echo "WARN: host NFS export $NFS_EXPORT not reachable; /var/lib/pulp is local" >> /root/ks-post.log
# POSTBOOT: fi
%end
