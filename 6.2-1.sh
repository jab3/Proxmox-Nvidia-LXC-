#!/usr/bin/env bash

#remove proxmox ui nag
bash -c "$(wget -qLO - https://gist.githubusercontent.com/whiskerz007/53c6aa5d624154bacbbc54880e1e3b2a/raw/70b66d1852978cc457526df4a2913ca2974970a1/gistfile1.txt)"

# Update Proxmox
apt-get update && apt-get upgrade -qqy

# Install NVidia drivers prerequisites
apt-get install -qqy pve-headers-`uname -r` gcc make 

# Setup temporary environment
trap cleanup EXIT
function cleanup() {
  popd >/dev/null
  rm -rf $TMP_DIR
}
TMP_DIR=$(mktemp -d)
pushd $TMP_DIR >/dev/null

#removal of Nouveau driver from system
cat <<e > /etc/modprobe.d/nvidia-installer-disable-nouveau.conf
# generated by nvidia-installer
blacklist nouveau
options nouveau modeset=0
e
rmmod nouveau

# Install NVidia drivers
LATEST_DRIVER=$(wget -qLO - https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt | awk '{print $2}')
LATEST_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${LATEST_DRIVER}"
INSTALL_SCRIPT=$(basename $LATEST_DRIVER_URL)
wget -qLO $INSTALL_SCRIPT $LATEST_DRIVER_URL
bash $INSTALL_SCRIPT --silent

# Install NVidia Persistenced
#/usr/share/doc/NVIDIA_GLX-1.0/sample/nvidia-persistenced-init.tar.bz2 
if [ -f /usr/share/doc/NVIDIA_GLX-1.0/samples/nvidia-persistenced-init.tar.bz2 ]; then
  tar -jxvf /usr/share/doc/NVIDIA_GLX-1.0/samples/nvidia-persistenced-init.tar.bz2  
  bash ./nvidia-persistenced-init/install.sh
fi

# Install NVidia Container Runtime
wget -qLO - https://nvidia.github.io/nvidia-container-runtime/gpgkey | apt-key add - 
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
wget -qLO - https://nvidia.github.io/nvidia-container-runtime/$distribution/nvidia-container-runtime.list | tee /etc/apt/sources.list.d/nvidia-container-runtime.list
apt-get update
apt-get install -qqy nvidia-container-runtime

#check nvidia-smi works check /dev/nvidia* for nvidia0 nvidia-modeset nvidia-uvm nvidia-uvm toolkit

# user must modify lxc config and add lines
#
#lxc.hook.pre-start: sh -c '[ ! -f /dev/nvidia-uvm ] && /usr/bin/nvidia-modprobe -c0 -u'
#lxc.environment: NVIDIA_VISIBLE_DEVICES=all
#lxc.environment: NVIDIA_DRIVER_CAPABILITIES=all
#lxc.hook.mount: /usr/share/lxc/hooks/nvidia
#lxc.hook.pre-start: sh -c 'chown :100000 /dev/nvidia*' # if your still having permission issuse run/add this line to your config

#create LXC 

function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "$FLAG $REASON"
}

while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=( "$TAG" "$ITEM" "OFF" )
done < <(pvesm status -content rootdir | awk 'NR>1')
if [ $((${#STORAGE_MENU[@]}/3)) -eq 0 ]; then
  warn "'Container' needs to be selected for at least one storage location."
  die "Unable to detect valid storage location."
elif [ $((${#STORAGE_MENU[@]}/3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --title "Storage Pools" --radiolist \
    "Which storage pool you would like to use for the container?\n\n" \
    16 $(($MSG_MAX_LENGTH + 23)) 6 \
    "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit
  done
fi
info "Using '$STORAGE' for storage location."

CTID=$(pvesh get /cluster/nextid)

msg "Updating LXC template list..."
pveam update 
msg "Downloading LXC template..."
OSTYPE=ubuntu
OSVERSION=${OSTYPE}-20
mapfile -t TEMPLATES < <(pveam available -section system | sed -n "s/.*\($OSVERSION.*\)/\1/p" | sort -t - -k 2 -V)
TEMPLATE="${TEMPLATES[-1]}"
pveam download local $TEMPLATE ||
  die "A problem occured while downloading the LXC template."

HOSTNAME=PLEX
TEMPLATE_STRING="local:vztmpl/${TEMPLATE}"

pct create $CTID $TEMPLATE_STRING -cmode shell -features nesting=1 \
  -hostname $HOSTNAME -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -ostype $OSTYPE -storage $STORAGE --unprivileged=1

LXC_CONFIG=/etc/pve/lxc/${CTID}.conf
cat <<EOF >> $LXC_CONFIG
lxc.hook.pre-start: sh -c '[ ! -f /dev/nvidia-uvm ] && /usr/bin/nvidia-modprobe -c0 -u'
lxc.environment: NVIDIA_VISIBLE_DEVICES=all
lxc.environment: NVIDIA_DRIVER_CAPABILITIES=all
lxc.hook.mount: /usr/share/lxc/hooks/nvidia
lxc.hook.pre-start: sh -c 'chown :100000 /dev/nvidia*'
EOF

pct start $CTID

until lxc-info $CTID | grep -q IP;do 
  echo -ne "no ip found \033[0K\r"
done

lxc-attach -n $CTID -- apt -y install gnupg2
lxc-attach -n $CTID -- bash -c 'wget -q https://downloads.plex.tv/plex-keys/PlexSign.key -O - | apt-key add -'
lxc-attach -n $CTID -- bash -c 'echo "deb https://downloads.plex.tv/repo/deb/ public main" > /etc/apt/sources.list.d/plexmediaserver.list'
lxc-attach -n $CTID -- apt update
lxc-attach -n $CTID -- apt -y upgrade
lxc-attach -n $CTID -- apt -y install nvtop 
lxc-attach -n $CTID -- apt-get -y -o Dpkg::Options::="--force-confnew" install plexmediaserver
