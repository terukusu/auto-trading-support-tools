#!/bin/bash

########################################
# Setup shell/environment variables
########################################

VNC_PASSWORD=123123
TARGET_LOCALE=ja_JP.UTF-8

IS_SYSTEMD=$(which systemctl)
ABS_PWD=$(cd "$(dirname "$BASH_SOURCE")"; pwd)
ORG_USER=${SUDO_USER:-$USER}
DIR_WINECACHE=$HOME/.cache/wine

export WINEARCH=win32
export WINEDEBUG=-all,err+all
export WINEPREFIX=$HOME/.wine
export DISPLAY=:1

export DEBIAN_FRONTEND=noninteractive

. /etc/os-release

if [ -z "$VERSION_CODENAME" ]; then
  VERSION_CODENAME=`echo -n $VERSION | tr '[A-Z]' '[a-z]' | grep -Eo 'artful|bionic|cosmic|precise|trusty|xenial|yakkety|zesty|jessie|stretch|buster'`
fi

WINE_REPOS="deb https://dl.winehq.org/wine-builds/$ID/ $VERSION_CODENAME main"

########################################
# Creating directories
########################################

mkdir -p "$DIR_WINECACHE"

########################################
# Setup root crontab
########################################
function setup_root_crontab() {
  # For old OpenVZ kernel. SSHD doesn't start after updating systemd without this.

  cron_line=$(sudo bash -c "crontab -l 2>/dev/null" | grep -o "mkdir -p -m0755 /var/run/sshd")

  if [ -z "$cron_line" ]; then
    sudo bash -c "cat <(crontab -l 2>/dev/null) <(echo '@reboot if [ ! -e /var/run/sshd  ]; then mkdir -p -m0755 /var/run/sshd; fi') | crontab"
  fi

  return 0
}

########################################
# Creating ~/.bash_profile if needed
########################################
function create_bash_profile_if_needed() {
  bash_profile=$HOME/.bash_profile

  if [ ! -f "$bash_profile" ] || [ -z "`cat $bash_profile | grep -o WINEARCH`" ]; then

    # write WINE param to the .bash_profile
    cat << EOS >> "$bash_profile"

export WINEARCH=$WINEARCH
export WINEDEBUG=$WINEDEBUG
export WINEPREFIX=$WINEPREFIX
export DISPLAY=$DISPLAY

if [ -e \$HOME/.bashrc ]; then
  . \$HOME/.bashrc
fi
EOS
  fi
}


########################################
# Creating swap space if needed
########################################
function create_swap_space_if_needed() {
  # For vps which don't have swap such as GCE f1-micro.
  # Create swap space and enable swap unless OpenVZ

  swap_total=`cat /proc/meminfo | grep -i swaptotal | tr -s " " | cut -d' ' -f'2'`

  if [ ! -e /proc/user_beancounters ] && [ "$swap_total" == "0" ]; then
    echo make 1024 MB swap file. please wait for few minutes.
    sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
    sudo chmod 600 /swapfile
    sudo mkswap -f /swapfile
    sudo swapon /swapfile

    if [ $? -ne 0 ] ;then
      echo swapon faild. continue without swap.
      sudo rm /swapfile
    else
      sudo bash -c 'echo -e "/swapfile\tswap\tswap\tdefaults\t0\t0" >> /etc/fstab'
    fi
  fi
}

########################################
# Upgrade existing packages
########################################
function upgrade_existing_packages {
  # upgrade packages.
  sudo apt update
  sudo apt -y -f install
  sudo apt -y upgrade
}

########################################
# Install and setup Japanese locale, Timezone
########################################
function set_up_locale_and_timezone() {
  sudo apt -y install dbus

  # setting local and timezone.
  sudo apt -y install tzdata

  if [ "$ID" == "debian" ]; then
    # for debian
    sudo apt -y install task-japanese locales
    sudo bash -c 'echo "'$TARGET_LOCALE' UTF-8" > /etc/locale.gen'
  else
    sudo apt -y install language-pack-ja
  fi

  sudo locale-gen
  sudo update-locale LANG=$TARGET_LOCALE
  sudo timedatectl set-timezone Asia/Tokyo
}

#####################################################
# Install packages required by MetaTrader
#####################################################
function install_packages_misc_and_needed_by_mt4() {
  # install misc
  sudo apt -y install unattended-upgrades apt-transport-https psmisc vim nano less tmux curl net-tools lsof

  # install gui
  sudo apt -y install vnc4server fonts-vlgothic xterm wm2

  # install wine
  sudo apt -y install software-properties-common
  sudo dpkg --add-architecture i386
  wget -q -nc -P "$DIR_WINECACHE" https://dl.winehq.org/wine-builds/winehq.key
  sudo apt-key add "$DIR_WINECACHE/winehq.key"
  sudo apt-add-repository "$WINE_REPOS"
  sudo apt -y update
  sudo apt -y install --install-recommends winehq-stable

  sudo apt -y install unattended-upgrades
}

#####################################################
# Auto update package list.
#####################################################
function setup_auto_update_package_list() {
  echo Setting auto update package list.

  upgrades_conf="/etc/apt/apt.conf.d/20auto-upgrades"

  if [ ! -e "$upgrades_conf" ]; then
    cat - << EOS | sudo bash -c "cat - > '$upgrades_conf'"
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
EOS
  else
    sudo sed -i -e 's/APT::Periodic::Update-Package-Lists "[0-9][0-9]*"/APT::Periodic::Update-Package-Lists "1"/g'  "$upgrades_conf"
    sudo sed -i -e 's/APT::Periodic::Unattended-Upgrade "[0-9][0-9]*"/APT::Periodic::Unattended-Upgrade "0"/g'  "$upgrades_conf"
  fi

  is_enabled=$(systemctl list-unit-files | grep apt-daily.timer | awk '{print $2}')

  if [ -n "$is_enabled" ]; then
    # for systemd
    if [ "$is_enabled" == "disabled" ]; then
      sudo systemctl enable apt-daily.timer
      sudo systemctl start apt-daily.timer
    fi
  elif [ -f /etc/cron.daily/apt-compat.disabled ]; then
    # for systemd + cron
    if [ ! -f /etc/cron.daily/apt-compat ]; then
      sudo mv /etc/cron.daily/apt-compat.disabled /etc/cron.daily/apt-compat
    fi
  elif [ -f /etc/cron.daily/apt.disabled ]; then
    # for cron based upgrade.
    if [ ! -f /etc/cron.daily/apt ]; then
      sudo mv /etc/cron.daily/apt.disabled /etc/cron.daily/apt
    fi
  fi
}

#####################################################
# Setup VNC server (seup only. not start service here)
#####################################################
function setup_vncserver {
  if [ -n "$IS_SYSTEMD" ]; then
      # for systemd
      echo Registering VNC Server as systemd service.

      if [ ! -f "/etc/systemd/system/vncserver@:1.service" ]; then
        sudo install -o root -g root -m 644 -D "$ABS_PWD/vncserver@:1.service" "/etc/systemd/system/vncserver@:1.service"
        sudo sed -i -e 's/%%USER_NAME%%/'$ORG_USER'/g' "/etc/systemd/system/vncserver@:1.service"
      fi

      sudo systemctl enable "vncserver@:1.service"
  else
      # for upstart
      echo Registering VNC Server as upstart service.

      if [ ! -f "/etc/init.d/vncserver" ]; then
        sudo install -o root -g root -m 644 -D "$ABS_PWD/vncserver_for_upstart" "/etc/init.d/vncserver"
        sudo sed -i -e 's/%%USER_NAME%%/'$ORG_USER'/g' "/etc/init.d/vncserver"
        sudo chmod +x /etc/init.d/vncserver
      fi

      sudo update-rc.d vncserver defaults
  fi

  # setting default password for vncserver
  echo 'Setting default VNC password "123123". Please change this yourself later :-)'
  echo -e "$VNC_PASSWORD\n$VNC_PASSWORD" | vncpasswd &>/dev/null
}

#####################################################
# Start VNC Server
#####################################################
function start_vncserver_service() {
  echo -n Starting VNC Server ...
  if [ -n "$IS_SYSTEMD" ]; then
      sudo systemctl start "vncserver@:1"
  else
      sudo service vncserver start
  fi

  if [ $? == "0" ]; then
      echo stared!
  else
      echo failed!
  fi
}

#####################################################
# Setup Wine, Downlaod & install Wine-Mono and Wine-Gecko package.
#####################################################
function setup_wine {
  latest_mono=$(curl -s http://dl.winehq.org/wine/wine-mono/ | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -nr | head -n1)
  latest_gecko=$(curl -s http://dl.winehq.org/wine/wine-gecko/ | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -nr | head -n1)

  msi_arch=x86

  if [ "win64" == "$WINEARCH" ]; then
      msi_arch=x86_64
  fi

  msi_mono=wine-mono-$latest_mono.msi
  msi_gecko=wine_gecko-$latest_gecko-$msi_arch.msi

  echo -n Downlaoding mono: $latest_mono ...
  wget -q -N -P "$DIR_WINECACHE" "http://dl.winehq.org/wine/wine-mono/$latest_mono/$msi_mono"

  if [ $? == 0 ]; then
      echo done.
  else
      echo failed.
  fi

  echo -n Downlaoding gecko: $latest_gecko ...
  wget -q -N -P "$DIR_WINECACHE" "http://dl.winehq.org/wine/wine-gecko/$latest_gecko/$msi_gecko"

  if [ $? == 0 ]; then
      echo done.
  else
      echo failed.
  fi

  #####################################################
  # Setup Wine
  #####################################################

  export WINEDEBUG=-all

  # initialize wineprefix
  echo Initializing wine.. this takes few minutes.
  wineserver -kw
  wineboot -i
  wineserver -w

  # setting japanese fonts
  fot_replace_exist=$(cat $WINEPREFIX/user.reg | tr -d '\r' | grep -o '\[Software\\\\Wine\\\\Fonts\\\\Replacements\]')
  if [ -z "$fot_replace_exist" ]; then
      cat "$ABS_PWD/font_replace.reg" >> "$WINEPREFIX/user.reg"
  fi

  # install wine-mono and wine-gecko
  echo Installing Wine-Mono
  wine msiexec /i "$DIR_WINECACHE/$msi_mono"

  echo Installing Wine-Gecko
  wine msiexec /i "$DIR_WINECACHE/$msi_gecko"
}

#####################################################
# Clean needless files
#####################################################
function clean_needless_files {
  sudo apt-get -y autoremove
  sudo apt-get -y clean
  rm "$DIR_WINECACHE/$msi_mono"
  rm "$DIR_WINECACHE/$msi_gecko"
  rm "$DIR_WINECACHE/winehq.key"
  "$ABS_PWD/minimize_wine.sh"
}

#####################################################
# Download MT4 and start installer
#####################################################
function download_and_start_mt4_installer() {
  echo Downloading MetaTrader4 ...
  if [ -f "$DIR_WINECACHE/landfx4setup.exe" ]; then
      rm "$DIR_WINECACHE/landfx4setup.exe"
  fi

  wget -q -N -P "$DIR_WINECACHE" 'https://download.mql5.com/cdn/web/land.prime.ltd/mt4/landfx4setup.exe'

  echo Staring MetaTrader4 installer...
  WINEDEBUG=-all wine start /unix "$DIR_WINECACHE/landfx4setup.exe"
}

setup_root_crontab
create_bash_profile_if_needed
create_swap_space_if_needed
upgrade_existing_packages
set_up_locale_and_timezone

export LANG=$TARGET_LOCALE

install_packages_misc_and_needed_by_mt4
setup_auto_update_package_list
setup_vncserver
setup_wine
start_vncserver_service
clean_needless_files
download_and_start_mt4_installer

echo ""
echo "====================================================="
echo "Now MetaTrader4 installer is running on VNC(GUI) !!"
echo "====================================================="
