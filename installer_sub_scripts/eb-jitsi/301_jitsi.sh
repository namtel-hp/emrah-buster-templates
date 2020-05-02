# -----------------------------------------------------------------------------
# JITSI.SH
# -----------------------------------------------------------------------------
set -e
source $INSTALLER/000_source

# -----------------------------------------------------------------------------
# ENVIRONMENT
# -----------------------------------------------------------------------------
MACH="eb-jitsi"
cd $MACHINES/$MACH

ROOTFS="/var/lib/lxc/$MACH/rootfs"
DNS_RECORD=$(grep "address=/$MACH/" /etc/dnsmasq.d/eb_jitsi | head -n1)
IP=${DNS_RECORD##*/}
SSH_PORT="30$(printf %03d ${IP##*.})"
echo JITSI="$IP" >> $INSTALLER/000_source

# -----------------------------------------------------------------------------
# NFTABLES RULES
# -----------------------------------------------------------------------------
# public ssh
nft delete element eb-nat tcp2ip { $SSH_PORT } 2>/dev/null || true
nft add element eb-nat tcp2ip { $SSH_PORT : $IP }
nft delete element eb-nat tcp2port { $SSH_PORT } 2>/dev/null || true
nft add element eb-nat tcp2port { $SSH_PORT : 22 }
# http
nft delete element eb-nat tcp2ip { 80 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 80 : $IP }
nft delete element eb-nat tcp2port { 80 } 2>/dev/null || true
nft add element eb-nat tcp2port { 80 : 80 }
# https
nft delete element eb-nat tcp2ip { 443 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 443 : $IP }
nft delete element eb-nat tcp2port { 443 } 2>/dev/null || true
nft add element eb-nat tcp2port { 443 : 443 }
# udp/10000
nft delete element eb-nat udp2ip { 10000 } 2>/dev/null || true
nft add element eb-nat udp2ip { 10000 : $IP }
nft delete element eb-nat udp2port { 10000 } 2>/dev/null || true
nft add element eb-nat udp2port { 10000 : 10000 }

# -----------------------------------------------------------------------------
# INIT
# -----------------------------------------------------------------------------
[ "$DONT_RUN_JITSI" = true ] && exit

echo
echo "-------------------------- $MACH --------------------------"

# -----------------------------------------------------------------------------
# REINSTALL_IF_EXISTS
# -----------------------------------------------------------------------------
EXISTS=$(lxc-info -n $MACH | egrep '^State' || true)
if [ -n "$EXISTS" -a "$REINSTALL_JITSI_IF_EXISTS" != true ]
then
    echo "Already installed. Skipped..."
    echo
    echo "Please set REINSTALL_JITSI_IF_EXISTS in $APP_CONFIG"
    echo "if you want to reinstall this container"
    exit
fi

# -----------------------------------------------------------------------------
# CONTAINER SETUP
# -----------------------------------------------------------------------------
# stop the template container if it's running
set +e
lxc-stop -n eb-buster
lxc-wait -n eb-buster -s STOPPED
set -e

# remove the old container if exists
set +e
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
lxc-destroy -n $MACH
rm -rf /var/lib/lxc/$MACH
sleep 1
set -e

# create the new one
lxc-copy -n eb-buster -N $MACH -p /var/lib/lxc/

# shared directories
mkdir -p $SHARED/cache

# container config
rm -rf $ROOTFS/var/cache/apt/archives
mkdir -p $ROOTFS/var/cache/apt/archives
sed -i '/^lxc\.net\./d' /var/lib/lxc/$MACH/config
sed -i '/^# Network configuration/d' /var/lib/lxc/$MACH/config

cat >> /var/lib/lxc/$MACH/config <<EOF

# Network configuration
lxc.net.0.type = veth
lxc.net.0.link = $BRIDGE
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.net.0.ipv4.address = $IP/24
lxc.net.0.ipv4.gateway = auto

# Start options
lxc.start.auto = 1
lxc.start.order = 500
lxc.start.delay = 2
lxc.group = eb-group
lxc.group = onboot
EOF

# start container
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING

# -----------------------------------------------------------------------------
# HOSTNAME
# -----------------------------------------------------------------------------
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     echo $JITSI_HOST > /etc/hostname
     sed -i 's/\(127.0.1.1\s*\).*$/\1$JITSI_HOST/' /etc/hosts
     hostname $JITSI_HOST"

# -----------------------------------------------------------------------------
# PACKAGES
# -----------------------------------------------------------------------------
# fake install
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     export DEBIAN_FRONTEND=noninteractive
     apt-get $APT_PROXY_OPTION -dy reinstall hostname"

# update
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     export DEBIAN_FRONTEND=noninteractive
     apt-get $APT_PROXY_OPTION update
     apt-get $APT_PROXY_OPTION -y dist-upgrade"

# apt-transport-https, gnupg
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     export DEBIAN_FRONTEND=noninteractive
     apt-get $APT_PROXY_OPTION -y install apt-transport-https gnupg"

# ssl
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     export DEBIAN_FRONTEND=noninteractive
     apt-get $APT_PROXY_OPTION -y install ssl-cert ca-certificates certbot"

# ssl early config, needed for the jitsi install
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     ln -s ssl-cert-snakeoil.pem /etc/ssl/certs/ssl-eb.pem
     ln -s ssl-cert-snakeoil.key /etc/ssl/private/ssl-eb.key"

# jitsi sources list and jitsi GPG key
cp etc/apt/sources.list.d/jitsi.list $ROOTFS/etc/apt/sources.list.d/
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     wget -qO -  https://download.jitsi.org/jitsi-key.gpg.key | apt-key add -
     apt-get update"

lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     export DEBIAN_FRONTEND=noninteractive
     debconf-set-selections <<< \
         'jitsi-meet-turnserver jitsi-meet-turnserver/jvb-hostname string $JITSI_HOST'
     debconf-set-selections <<< \
         'jitsi-meet-web-config jitsi-meet/cert-choice select I want to use my own certificate'
     debconf-set-selections <<< \
         'jitsi-meet-web-config jitsi-meet/cert-path-key string /etc/ssl/private/ssl-eb.key'
     debconf-set-selections <<< \
         'jitsi-meet-web-config jitsi-meet/cert-path-crt string /etc/ssl/certs/ssl-eb.pem'
     apt-get $APT_PROXY_OPTION -y --install-recommends install jitsi-meet"

# -----------------------------------------------------------------------------
# SYSTEM CONFIGURATION
# -----------------------------------------------------------------------------
# nginx
rm $ROOTFS/etc/nginx/sites-enabled/default
rm -rf /var/www/html
ln -s /usr/share/jitsi-meet /var/www/html

lxc-attach -n $MACH -- systemctl stop nginx.service
lxc-attach -n $MACH -- systemctl start nginx.service

# certbot service
cp ../common/lib/systemd/system/certbot.service $ROOTFS/lib/systemd/system/
lxc-attach -n $MACH -- systemctl daemon-reload

# -----------------------------------------------------------------------------
# CONTAINER SERVICES
# -----------------------------------------------------------------------------
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING