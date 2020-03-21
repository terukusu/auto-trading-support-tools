#!/bin/bash

########################################
# Setup shell/environment variables
########################################

VNC_PASSWORD=123123
TARGET_LOCALE=ja_JP.UTF-8

ABS_PWD=$(cd "$(dirname "$BASH_SOURCE")"; pwd)
ORG_USER=${SUDO_USER:-$USER}
IS_SYSTEMD=$(which systemctl)
DIR_TEMPLATES="$ABS_PWD/templates"
DIR_WINECACHE=$HOME/.cache/wine
APT_OPT='-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'

export DEBIAN_FRONTEND=noninteractive
export WINEARCH=win32
export WINEDEBUG=-all,err+all
export WINEPREFIX=$HOME/.wine
export DISPLAY=:1

########################################
# Detect distribution.
########################################
. /etc/os-release

if [ -z "$VERSION_CODENAME" ]; then
  VERSION_CODENAME=`echo -n $VERSION | tr '[A-Z]' '[a-z]' | grep -Eo 'artful|bionic|cosmic|precise|trusty|xenial|yakkety|zesty|jessie|stretch|buster'`
fi

WINE_REPOS="deb https://dl.winehq.org/wine-builds/$ID/ $VERSION_CODENAME main"

FAUDIO_REPOS_BASE="https://download.opensuse.org/repositories/Emulators:/Wine:/Debian"
DIST_NAME=$(echo $NAME | tr '[A-Z]' '[a-z]' | grep -oE "ubuntu|debian")
if [ "$DIST_NAME" = "ubuntu" ]; then
    FAUDIO_REPOS=${FAUDIO_REPOS_BASE}/xUbuntu_${VERSION_ID}
elif [ "$DIST_NAME" = "debian" ]; then
    FAUDIO_REPOS=${FAUDIO_REPOS_BASE}/Debian_${VERSION_ID}
fi

########################################
# Creating directories
########################################

mkdir -p "$DIR_WINECACHE"

########################################
# Setup root crontab
########################################
function setup_root_crontab() {
  # For old OpenVZ kernel. SSHD doesn't start after updating systemd without this.

  sudo -E apt $APT_OPT install cron

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
export WINEPREFIX=\$HOME/.wine
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
  sudo -E apt $APT_OPT -f install
  sudo -E apt $APT_OPT upgrade
}

########################################
# Install and setup Japanese locale, Timezone
########################################
function set_up_locale_and_timezone() {
  sudo -E apt $APT_OPT install dbus

  # setting local and timezone.
  sudo -E apt $APT_OPT install tzdata

  if [ "$ID" == "debian" ]; then
    # for debian
    sudo -E apt $APT_OPT install task-japanese locales
  else
    sudo -E apt $APT_OPT install language-pack-ja
  fi

  # 1 locale only
  sudo bash -c 'echo "'$TARGET_LOCALE' UTF-8" > /etc/locale.gen'

  sudo locale-gen
  sudo update-locale LANG=$TARGET_LOCALE
  sudo timedatectl set-timezone Asia/Tokyo
}

#####################################################
# Install packages required by MetaTrader
#####################################################
function install_packages_misc_and_needed_by_mt4() {
  # install misc
  sudo -E apt $APT_OPT install unattended-upgrades apt-transport-https ntp psmisc file bc vim nano less tmux curl net-tools lsof

  # install gui
  sudo -E apt $APT_OPT install tightvncserver fonts-vlgothic xterm wm2

  # install wine
  sudo -E apt $APT_OPT install software-properties-common
  sudo dpkg --add-architecture i386

  REPOS_EXISTS=$(cat /etc/apt/sources.list | grep "$WINE_REPOS" | head -n1)
  if [ -z "$REPOS_EXISTS" ]; then
    wget -q -nc -P "$DIR_WINECACHE" https://dl.winehq.org/wine-builds/winehq.key
    sudo apt-key add "$DIR_WINECACHE/winehq.key"
    sudo apt-add-repository "$WINE_REPOS"
  fi

  REPOS_EXISTS=$(cat /etc/apt/sources.list | grep "$FAUDIO_REPOS" | head -n1)
  if [ -z "$REPOS_EXISTS" ]; then
    WEB_REPOS_EXITS=$(curl -s --head "$FAUDIO_REPOS/" | head -n1 | cut -d' ' -f2 | grep -oe '^2')
    if [ -n "$WEB_REPOS_EXITS" ]; then
      wget -nc $FAUDIO_REPOS/Release.key
      sudo apt-key add Release.key
      sudo apt-add-repository "deb $FAUDIO_REPOS ./"
    fi
  fi

  sudo -E apt $APT_OPT update
  sudo -E apt $APT_OPT install --install-recommends winehq-stable
}

#####################################################
# Install packages required by graphical report
#####################################################
install_packages_needed_by_graphical_report() {
  sudo -E apt $APT_OPT install gnuplot-nox vncsnapshot
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
APT::Periodic::AutocleanInterval "1";
EOS
  else
    # Update-Package-List
    if [ -z "$(grep -io 'APT::Periodic::Update-Package-Lists' "$upgrades_conf")" ]; then
      echo 'APT::Periodic::Update-Package-Lists "1";' | sudo bash -c 'cat - >> "'$upgrades_conf'"'
    else
      sudo sed -i -e 's/APT::Periodic::Update-Package-Lists "[0-9][0-9]*"/APT::Periodic::Update-Package-Lists "1"/g'  "$upgrades_conf"
    fi

    # Unattended-Upgrade
    if [ -z "$(grep -io 'APT::Periodic::Unattended-Upgrade' "$upgrades_conf")" ]; then
      echo 'APT::Periodic::Unattended-Upgrade "0";' | sudo bash -c 'cat - >> "'$upgrades_conf'"'
    else
      sudo sed -i -e 's/APT::Periodic::Unattended-Upgrade "[0-9][0-9]*"/APT::Periodic::Unattended-Upgrade "0"/g'  "$upgrades_conf"
    fi
    # AutocleanInterval
    if [ -z "$(grep -io 'APT::Periodic::AutocleanInterval' "$upgrades_conf")" ]; then
      echo 'APT::Periodic::AutocleanInterval "1";' | sudo bash -c 'cat - >> "'$upgrades_conf'"'
    else
      sudo sed -i -e 's/APT::Periodic::AutocleanInterval "[0-9][0-9]*"/APT::Periodic::AutocleanInterval "1"/g'  "$upgrades_conf"
    fi
  fi

  if [ -n "$IS_SYSTEMD" ]; then
    is_apt_daily_timer_exists=$(systemctl list-unit-files | grep apt-daily.timer)
  fi

  if [ -n "$is_apt_daily_timer_exists" ]; then
    # for systemd

    # daily update
    is_enabled=$(systemctl list-unit-files | grep apt-daily.timer | awk '{print $2}')

    if [ "$is_enabled" == "disabled" ]; then
      sudo systemctl enable apt-daily.timer
    fi

    sudo systemctl start apt-daily.timer

    # daily upgrade
    is_enabled=$(systemctl list-unit-files | grep apt-daily-upgrade.timer | awk '{print $2}')

    if [ "$is_enabled" == "disabled" ]; then
      sudo systemctl enable apt-daily-upgrade.timer
    fi

    sudo systemctl start apt-daily-upgrade.timer
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
      sudo install -o root -g root -m 644 -D "$DIR_TEMPLATES/vncserver@:1.service" "/etc/systemd/system/vncserver@:1.service"
      sudo sed -i -e 's/%%USER_NAME%%/'$ORG_USER'/g' "/etc/systemd/system/vncserver@:1.service"
    fi

    sudo systemctl enable "vncserver@:1.service"
  else
    # for upstart
    echo Registering VNC Server as upstart service.

    if [ ! -f "/etc/init.d/vncserver" ]; then
      sudo install -o root -g root -m 644 -D "$DIR_TEMPLATES/vncserver" "/etc/init.d/vncserver"
      sudo sed -i -e 's/%%USER_NAME%%/'$ORG_USER'/g' "/etc/init.d/vncserver"
      sudo chmod +x /etc/init.d/vncserver
    fi

    sudo update-rc.d vncserver defaults
  fi

  if [ ! -e "$HOME/.vnc/xstartup" ]; then
    # install xstartup
    install -m 755 -D "$DIR_TEMPLATES/xstartup" "$HOME/.vnc/xstartup"
  fi

  # setting default password for vncserver
  if [ ! -e "$HOME/.vnc/passwd" ]; then
    echo 'Setting default password '123123' to VNC. Please change this yourself later :-)'
    echo "123123" | vncpasswd -f > "$HOME/.vnc/passwd"
    chmod 600 "$HOME/.vnc/passwd"
  fi
}

#####################################################
# Start VNC Server
#####################################################
function start_vncserver_service() {
  echo -n Starting VNC Server ...
  if [ -n "$IS_SYSTEMD" ]; then
    sudo systemctl stop "vncserver@:1"
    sudo systemctl start "vncserver@:1"
  else
    sudo service vncserver stop
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
  msi_gecko=wine-gecko-$latest_gecko-$msi_arch.msi

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
  # Setup Wine (it must be exec without GUI.)
  #####################################################

  DISPLAY_OLD=$DISPLAY
  WINEDEBUG_OLD=$WINEDEBUG

  export WINEDEBUG=-all
  export DISPLAY=""

  # initialize wineprefix
  if [ -d "$WINEPREFIX" ]; then
    echo "WINEPREFIX($WINEPREFIX) directory already exists. Delete and reinitialize it?(Y/n)"
    echo -n "> "
    read line
    if [ "n" != "${line,,}" ]; then
      echo -n "Deleteing WINEPREFIX($WINEPREFIX) ... "
      rm -rf "$WINEPREFIX"
      echo "Done"
    fi
  fi

  echo Initializing wine.. this takes few minutes.
  wineserver -kw
  wineboot -i
  wineserver -w

  # setting japanese fonts
  font_replace_exist=$(cat "$WINEPREFIX/user.reg" | tr -d '\r' | grep -o '\[Software\\\\Wine\\\\Fonts\\\\Replacements\]')
  if [ -z "$font_replace_exist" ]; then
    cat "$DIR_TEMPLATES/font_replace.reg" >> "$WINEPREFIX/user.reg"
  fi

  # install wine-mono and wine-gecko
  echo Installing Wine-Mono
  wine msiexec /i "$DIR_WINECACHE/$msi_mono"

  echo Installing Wine-Gecko
  wine msiexec /i "$DIR_WINECACHE/$msi_gecko"

  export WINEDEBUG=$WINEDEBUG_OLD
  export DISPLAY=$DISPLAY_OLD
}

#####################################################
# Clean needless files
#####################################################
function clean_needless_files {
  sudo apt-get -y autoremove
  sudo apt-get -y clean
  rm "$DIR_WINECACHE/$msi_mono"
  rm "$DIR_WINECACHE/$msi_gecko"
  if [ -e "$DIR_WINECACHE/winehq.key" ]; then
    rm "$DIR_WINECACHE/winehq.key"
  fi
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
install_packages_needed_by_graphical_report
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
