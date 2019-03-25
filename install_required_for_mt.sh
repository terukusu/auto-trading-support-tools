#!/bin/bash

# ensure excuted with sudo
if [ "$(id -u)" -ne "0" ]; then
  echo please execute with sudo. 1>&2
  exit 1
fi

. /etc/os-release

if [ -z "$VERSION_CODENAME" ]; then
  VERSION_CODENAME=`echo -n $VERSION | tr '[A-Z]' '[a-z]' | grep -Eo 'artful|bionic|cosmic|precise|trusty|xenial|yakkety|zesty|jessie|stretch|buster'`
fi

DEBIAN_FRONTEND=noninteractive
ORG_USER=${SUDO_USER:-$USER}
WINE_REPOS="deb https://dl.winehq.org/wine-builds/$ID/ $VERSION_CODENAME main"

# For old OpenVZ kernel. SSHD doesn't start after updating systemd without this.
cron_line=`crontab -l 2>/dev/null | grep -o "mkdir -p -m0755 /var/run/sshd"`

if [ -z "$cron_line" ]; then
  cat <(crontab -l) <(echo '@reboot if [ ! -e /var/run/sshd  ]; then mkdir -p -m0755 /var/run/sshd; fi') | crontab
fi

BASH_PROFILE=$HOME/.bash_profile
if [ ! -f $BASH_PROFILE ] || [ -z "`cat $BASH_PROFILE | grep -o WINEARCH`" ]; then

  # write WINE param to the .bash_profile
  cat << EOS >> $BASH_PROFILE

export WINEARCH=win32
export WINEDEBUG=-all,err+all
export DISPLAY=:1

if [ -e \$HOME/.bashrc ]; then
  . \$HOME/.bashrc
fi
EOS
  chown $ORG_USER:$ORG_USER $BASH_PROFILE
fi

# For vps which don't have swap such as GCE f1-micro.
# Create swap space and enable swap unless OpenVZ

swap_total=`cat /proc/meminfo | grep -i swaptotal | tr -s " " | cut -d' ' -f'2'`

if [ ! -e /proc/user_beancounters ] && [ "$swap_total" == "0" ]; then
  echo make 1024 MB swap file. please wait for few minutes.
  dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap -f /swapfile
  swapon /swapfile

  if [ $? -ne 0 ] ;then
    echo swapon faild. continue without swap.
    rm /swapfile
  else
    echo -e "/swapfile\tswap\tswap\tdefaults\t0\t0" >> /etc/fstab
  fi
fi

# upgrade packages.
apt update -y
apt install -f -y
apt upgrade -y

# setting local and timezone.
apt install -y dbus tzdata

if [ "$ID" == "debian" ]; then
  # for debian
  apt install -y task-japanese locales
  echo "ja_JP.UTF-8 UTF-8" > /etc/locale.gen
else
  apt install -y language-pack-ja
fi

locale-gen
update-locale LANG=ja_JP.UTF-8
timedatectl set-timezone Asia/Tokyo

# install misc
apt-get install -y apt-transport-https psmisc vim nano less tmux curl net-tools lsof

# install gui
apt-get install -y vnc4server fonts-vlgothic xterm wm2

# install wine
apt install -y software-properties-common
dpkg --add-architecture i386
wget -nc https://dl.winehq.org/wine-builds/winehq.key
apt-key add winehq.key
rm winehq.key
apt-add-repository "$WINE_REPOS"
apt update
apt install -y --install-recommends winehq-devel

apt-get autoremove -y
apt-get clean -y
apt-get autoclean -y
