#!/bin/bash

########################################
# Setup shell/environment variables
########################################

VNC_PASSWORD=123123
TARGET_LOCALE=ja_JP.UTF-8

# MetaTrader installer to download and launch.
# MetaQuotes no longer distributes MT4; its own mt4setup.exe actually installs MT5.
# So we use a broker that still ships a real MT4 build. Default: Land Prime (formerly LandFX),
# whose installer creates the "Land Prime MetaTrader 4 Terminal" folder.
# To use a different broker/platform, replace this URL with that broker's installer.
MT_INSTALLER_URL='https://download.mql5.com/cdn/web/land.prime.ltd/mt4/landprime4setup.exe'

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
  # Fallback for old os-release files without VERSION_CODENAME.
  # Only currently-supported (non-EOL) codenames are listed; older releases are no longer supported.
  VERSION_CODENAME=`echo -n $VERSION | tr '[A-Z]' '[a-z]' | grep -Eo 'focal|jammy|noble|bullseye|bookworm|trixie'`
fi

# Only currently-supported (non-EOL) releases are handled. Fail clearly on an unknown or empty
# codename instead of writing a broken sources.list entry that would later break apt.
case "$VERSION_CODENAME" in
  focal|jammy|noble|bullseye|bookworm|trixie) : ;;
  *) echo "[error] unsupported or undetected release: VERSION_CODENAME='$VERSION_CODENAME' (supported: focal/jammy/noble/bullseye/bookworm/trixie)" >&2; exit 1 ;;
esac

# APT signing keys (apt-key is removed on modern distros; store dearmored keys here and
# reference them with signed-by. Works on apt 1.1+, i.e. Ubuntu 16.04+ / Debian 9+).
APT_KEYRINGS_DIR=/etc/apt/keyrings
WINE_KEY_URL=https://dl.winehq.org/wine-builds/winehq.key
WINE_KEYRING=$APT_KEYRINGS_DIR/winehq-archive.gpg
FAUDIO_KEYRING=$APT_KEYRINGS_DIR/winehq-faudio-archive.gpg
WINE_LIST=/etc/apt/sources.list.d/winehq.list
FAUDIO_LIST=/etc/apt/sources.list.d/winehq-faudio.list

WINE_REPOS="deb [signed-by=$WINE_KEYRING arch=amd64,i386] https://dl.winehq.org/wine-builds/$ID/ $VERSION_CODENAME main"

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

  sudo -E apt-get $APT_OPT install cron

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
# MT4/5 need neither .NET (mono) nor embedded IE (gecko); disable both so Wine never pops a
# download dialog at runtime (keeps mtctl / cron-launched MT unattended).
export WINEDLLOVERRIDES="mscoree=;mshtml="

if [ -e \$HOME/.bashrc ]; then
  . \$HOME/.bashrc
fi
EOS
  fi

  # Profiles written by older versions have WINEARCH but no WINEDLLOVERRIDES; add just that line.
  if ! grep -q 'WINEDLLOVERRIDES' "$bash_profile" 2>/dev/null; then
    echo 'export WINEDLLOVERRIDES="mscoree=;mshtml="' >> "$bash_profile"
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
# Keep sshd reachable (P14)
########################################
function ensure_sshd_alive() {
  # On OpenVZ containers, upgrading systemd / openssh-server can stop ssh.service, and /run/sshd
  # (tmpfs) is not recreated, so sshd never comes back and the VPS is locked out. The @reboot
  # crontab entry only helps after a reboot, so restore sshd right after every package operation.
  [ -n "$IS_SYSTEMD" ] || return 0
  dpkg -s openssh-server >/dev/null 2>&1 || return 0

  # The privilege separation dir must exist even if a unit is already "active" (socket-activated
  # sshd fails per connection without it).
  sudo install -d -m 0755 /run/sshd

  # Start only what is missing. On focal/jammy/Debian ssh.socket conflicts with ssh.service, so
  # blindly starting the socket would stop a healthy sshd; use the socket only where it is enabled.
  if ! systemctl is-active --quiet ssh.socket && ! systemctl is-active --quiet ssh; then
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      sudo systemctl start ssh.socket >/dev/null 2>&1
    else
      sudo systemctl start ssh >/dev/null 2>&1
    fi
  fi

  local port
  port=$(sudo sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
  port=${port:-22}
  if ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
    return 0
  fi

  echo "[error] sshd is not listening on port ${port}. Keep your current SSH session open and run: sudo install -d -m0755 /run/sshd && sudo systemctl start ssh" >&2
  return 1
}

########################################
# Wine package group (P15)
########################################
# winehq-stable / wine-stable / wine-stable-amd64 / wine-stable-i386 must always have the same
# version. Letting the generic "apt upgrade" move them corrupts dpkg: e.g. wine 10 -> 11 moved
# /opt/wine-stable/bin/wine from wine-stable-i386 to wine-stable without a Replaces:, so dpkg refuses
# the overwrite and every later apt run fails. Keep them out of the generic upgrade and update them
# in their own transaction (see install_wine_packages).
WINE_PKGS="winehq-stable wine-stable wine-stable-amd64 wine-stable-i386:i386"

function installed_wine_pkgs() {
  local p
  for p in $WINE_PKGS; do
    dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -q '^install ok installed' && echo "$p"
  done
}

function install_wine_packages() {
  # Own transaction; --force-overwrite only here, for the file moved between wine packages.
  # Note: it also applies to the recommends pulled in by this single command (accepted trade-off;
  # the generic upgrade and every other install run without it).
  sudo -E apt-get $APT_OPT -o Dpkg::Options::=--force-overwrite install --install-recommends winehq-stable

  local versions
  versions=$(for p in $WINE_PKGS; do dpkg-query -W -f='${Version}\n' "$p" 2>/dev/null; done | sort -u)
  if ! sudo apt-get check >/dev/null 2>&1 || [ "$(printf '%s\n' "$versions" | grep -c .)" -ne 1 ]; then
    echo "[error] wine packages are inconsistent (versions: $(echo $versions)). Try: sudo apt-get -f install -o Dpkg::Options::=--force-overwrite" >&2
    return 1
  fi
}

########################################
# Upgrade existing packages
########################################
# Wine packages this script put on hold; released by release_wine_hold (also from the EXIT trap,
# so an interrupted run never leaves them held). Packages the user had already held are untouched.
WINE_HELD_BY_US=""

function release_wine_hold() {
  [ -n "$WINE_HELD_BY_US" ] && sudo apt-mark unhold $WINE_HELD_BY_US >/dev/null
  WINE_HELD_BY_US=""
}

function upgrade_existing_packages {
  # upgrade packages, holding the wine group so it is not partially upgraded (P15).
  local p already
  already=" $(apt-mark showhold 2>/dev/null | tr '\n' ' ') "
  for p in $(installed_wine_pkgs); do
    case "$already" in *" ${p%%:*} "*|*" $p "*) ;; *) WINE_HELD_BY_US="$WINE_HELD_BY_US $p" ;; esac
  done
  [ -n "$WINE_HELD_BY_US" ] && sudo apt-mark hold $WINE_HELD_BY_US >/dev/null

  sudo apt-get update
  sudo -E apt-get $APT_OPT -f install
  sudo -E apt-get $APT_OPT --with-new-pkgs upgrade   # same behaviour as "apt upgrade" (P15)

  release_wine_hold
  ensure_sshd_alive
}

########################################
# Install and setup Japanese locale, Timezone
########################################
function set_up_locale_and_timezone() {
  sudo -E apt-get $APT_OPT install dbus

  # setting local and timezone.
  sudo -E apt-get $APT_OPT install tzdata

  if [ "$ID" == "debian" ]; then
    # for debian
    sudo -E apt-get $APT_OPT install task-japanese locales
  else
    sudo -E apt-get $APT_OPT install language-pack-ja
  fi

  # Add the target locale without wiping locales the system already generates.
  if ! grep -qE "^${TARGET_LOCALE} UTF-8" /etc/locale.gen 2>/dev/null; then
    echo "${TARGET_LOCALE} UTF-8" | sudo tee -a /etc/locale.gen > /dev/null
  fi

  sudo locale-gen
  sudo update-locale LANG=$TARGET_LOCALE
  sudo timedatectl set-timezone Asia/Tokyo
}

#####################################################
# Time synchronization (P8 / P15)
#####################################################
function ensure_time_sync() {
  # In containers (OpenVZ/LXC) the clock belongs to the host and cannot be adjusted from inside.
  if systemd-detect-virt --container --quiet 2>/dev/null; then
    echo "Time is managed by the container host ($(systemd-detect-virt --container)); not installing a time daemon."
    return 0
  fi

  # Keep whatever time daemon is already there; chrony conflicts with ntp/ntpsec (time-daemon).
  local p
  for p in chrony ntp ntpsec systemd-timesyncd; do
    if systemctl is-active --quiet "$p" 2>/dev/null; then
      echo "Time sync already provided by $p; not installing chrony."
      return 0
    fi
  done
  for p in chrony ntp ntpsec systemd-timesyncd; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then
      # Installed but not running: do not add a conflicting daemon, but do not stay silent either.
      if [ "$p" = "systemd-timesyncd" ]; then
        sudo timedatectl set-ntp true >/dev/null 2>&1
        systemctl is-active --quiet systemd-timesyncd 2>/dev/null && { echo "Enabled systemd-timesyncd."; return 0; }
      fi
      echo "[warn] $p is installed but not running; time may not be synchronized. Start it: sudo systemctl enable --now $p" >&2
      return 0
    fi
  done

  # Nothing present: install chrony in its own transaction so a failure here cannot block others.
  if ! sudo -E apt-get $APT_OPT install chrony; then
    echo "[warn] failed to install chrony; time synchronization is not configured." >&2
  fi
  return 0
}

#####################################################
# Install packages required by MetaTrader
#####################################################
function install_packages_misc_and_needed_by_mt4() {
  # install misc
  # gnupg (gpg --dearmor) and wget are needed for the keyring/repo setup below.
  # (Time sync is handled separately by ensure_time_sync so a conflict there cannot sink this line.)
  # jq lets atst_send_to_line build LINE payloads with full JSON escaping (P6).
  sudo -E apt-get $APT_OPT install unattended-upgrades apt-transport-https gnupg wget jq psmisc file bc vim nano less tmux curl net-tools lsof

  ensure_time_sync

  # install gui
  sudo -E apt-get $APT_OPT install tightvncserver fonts-vlgothic xterm wm2

  # install wine
  sudo dpkg --add-architecture i386
  sudo install -d -m 0755 "$APT_KEYRINGS_DIR"

  # WineHQ repository (keyring + signed-by instead of the removed apt-key).
  # Skip entirely if WineHQ is already configured in any form — adding a second definition with a
  # different signed-by keyring makes apt fail with "Conflicting values set for option Signed-By".
  # Only real apt source files count (not *.save / *.distUpgrade backups left in the directory).
  if grep -qsE 'winehq|wine-builds' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null; then
    echo "WineHQ repository already configured; skipping key/list setup."
  elif [ ! -e "$WINE_LIST" ]; then
    wget -q --timeout=30 --tries=3 -O - "$WINE_KEY_URL" | sudo gpg --dearmor --yes -o "$WINE_KEYRING"
    sudo chmod 0644 "$WINE_KEYRING"
    # Only write the repo list once the key is actually present; otherwise apt would break with
    # NO_PUBKEY and the leftover list would make every re-run skip the key step (permanent break).
    if [ -s "$WINE_KEYRING" ]; then
      echo "$WINE_REPOS" | sudo tee "$WINE_LIST" > /dev/null
    else
      echo "[error] failed to fetch/import WineHQ key from $WINE_KEY_URL; not writing $WINE_LIST" >&2
    fi
  fi

  # FAudio (libfaudio0) is a dependency of winehq. Newer releases (Ubuntu 22.04+/Debian 12+)
  # ship it in the distro, so we only add the external opensuse repo on older releases that
  # don't provide it. (The opensuse repo exists for 24.04 too, so we must decide by distro
  # availability, not by whether the repo URL exists.)
  if [ ! -e "$FAUDIO_LIST" ] && ! LC_ALL=C apt-cache policy libfaudio0 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    WEB_REPOS_EXITS=$(curl -s --max-time 30 --head "$FAUDIO_REPOS/" | head -n1 | cut -d' ' -f2 | grep -oe '^2')
    if [ -n "$WEB_REPOS_EXITS" ]; then
      wget -q --timeout=30 --tries=3 -O - "$FAUDIO_REPOS/Release.key" | sudo gpg --dearmor --yes -o "$FAUDIO_KEYRING"
      sudo chmod 0644 "$FAUDIO_KEYRING"
      # Same rule as the WineHQ key: never leave a list behind without a usable key.
      if [ -s "$FAUDIO_KEYRING" ]; then
        echo "deb [signed-by=$FAUDIO_KEYRING] $FAUDIO_REPOS ./" | sudo tee "$FAUDIO_LIST" > /dev/null
      else
        echo "[error] failed to fetch/import FAudio key from $FAUDIO_REPOS; not writing $FAUDIO_LIST" >&2
      fi
    fi
  fi

  sudo -E apt-get $APT_OPT update
  install_wine_packages || exit 1   # the EXIT trap still restores sshd / releases holds
  ensure_sshd_alive
}

#####################################################
# Install packages required by graphical report
#####################################################
install_packages_needed_by_graphical_report() {
  sudo -E apt-get $APT_OPT install gnuplot-nox vncsnapshot
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
# Setup Wine (initialize WINEPREFIX). Wine-Mono / Wine-Gecko are intentionally NOT installed;
# they are disabled via WINEDLLOVERRIDES because MetaTrader does not need them.
#####################################################
function setup_wine {
  #####################################################
  # Setup Wine (it must be exec without GUI.)
  #####################################################

  DISPLAY_OLD=$DISPLAY
  WINEDEBUG_OLD=$WINEDEBUG

  export WINEDEBUG=-all
  export DISPLAY=""

  # An existing WINEPREFIX holds the installed MetaTrader, account settings and EAs. Never delete it
  # by default (P13): keep it while MT is running or when there is no terminal to answer, and only
  # delete on an explicit "y".
  if [ -d "$WINEPREFIX" ]; then
    # Wine runs MT with a Windows path argument (C:\...\terminal.exe); requiring the backslash and
    # our own uid avoids matching unrelated command lines that merely contain "terminal.exe".
    if pgrep -u "$(id -u)" -f '\\terminal(64)?\.exe' >/dev/null 2>&1; then
      # Continuing would run "wineserver -kw" below and kill the live MetaTrader (P1/P13).
      echo "[error] MetaTrader is running in $WINEPREFIX. Aborting so it is not stopped." >&2
      echo "        Stop it explicitly first (e.g. mtctl.sh stop <name>) and re-run if you really intend to." >&2
      exit 1
    elif [ ! -t 0 ]; then
      echo "WINEPREFIX($WINEPREFIX) already exists (non-interactive run); keeping it."
    else
      echo "WINEPREFIX($WINEPREFIX) already exists."
      echo "Delete it and reinitialize? Installed MetaTrader, account settings and EAs in it will be LOST. (y/N)"
      echo -n "> "
      read -r line
      if [ "y" = "${line,,}" ]; then
        echo -n "Deleting WINEPREFIX($WINEPREFIX) ... "
        rm -rf "${WINEPREFIX:?}"
        echo "Done"
      else
        echo "Keeping existing WINEPREFIX."
      fi
    fi
  fi

  # MetaTrader 4/5 are native Win32 apps and need neither Wine-Mono (.NET / mscoree) nor
  # Wine-Gecko (embedded IE / mshtml). Disabling both stops wineboot from prompting for or
  # downloading them, which keeps this headless install unattended, lighter and free of a
  # fragile network dependency. (If the in-terminal HTML views are ever needed, install gecko
  # later with: winetricks gecko)
  echo Initializing wine.. this takes few minutes.
  unset WINEDLLOVERRIDES_OLD
  [ -n "${WINEDLLOVERRIDES+x}" ] && WINEDLLOVERRIDES_OLD="$WINEDLLOVERRIDES"
  export WINEDLLOVERRIDES="mscoree=;mshtml="
  wineserver -kw
  wineboot -i
  wineserver -w
  if [ -n "${WINEDLLOVERRIDES_OLD+x}" ]; then
    export WINEDLLOVERRIDES="$WINEDLLOVERRIDES_OLD"
  else
    unset WINEDLLOVERRIDES
  fi

  # setting japanese fonts
  font_replace_exist=$(cat "$WINEPREFIX/user.reg" | tr -d '\r' | grep -o '\[Software\\\\Wine\\\\Fonts\\\\Replacements\]')
  if [ -z "$font_replace_exist" ]; then
    cat "$DIR_TEMPLATES/font_replace.reg" >> "$WINEPREFIX/user.reg"
  fi

  export WINEDEBUG=$WINEDEBUG_OLD
  export DISPLAY=$DISPLAY_OLD
}

#####################################################
# Clean needless files
#####################################################
function clean_needless_files {
  sudo apt-get -y autoremove
  sudo apt-get -y clean
  "$ABS_PWD/minimize_wine.sh"
}

#####################################################
# Download MT4 and start installer
#####################################################
function download_and_start_mt4_installer() {
  local installer="$DIR_WINECACHE/$(basename "$MT_INSTALLER_URL")"

  echo Downloading MetaTrader installer ...
  if [ -f "$installer" ]; then
    rm "$installer"
  fi

  wget -q --timeout=30 --tries=3 -N -P "$DIR_WINECACHE" "$MT_INSTALLER_URL"

  if [ ! -f "$installer" ]; then
    echo "[error] MT installer download failed: $MT_INSTALLER_URL" >&2
    return 1
  fi

  echo Staring MetaTrader installer...
  # Disable mono/gecko here too so the installer never blocks on a download dialog.
  WINEDLLOVERRIDES="mscoree=;mshtml=" WINEDEBUG=-all wine start /unix "$installer"
}

# Whatever happens below (including an early exit), never leave wine packages held by us and
# never leave the VPS without sshd.
function on_exit() {
  release_wine_hold
  ensure_sshd_alive
}
trap on_exit EXIT

# Upgrading wine / reinitializing the prefix under a running MetaTrader would break live trading (P1).
if pgrep -u "$(id -u)" -f '\\terminal(64)?\.exe' >/dev/null 2>&1; then
  echo "[error] MetaTrader is running. Stop it first (e.g. mtctl.sh stop <name>), then re-run this installer." >&2
  exit 1
fi

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
