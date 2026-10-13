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

# WineHQ stable version to install and pin (apt preferences glob). Wine 11 makes the MT4/MT5
# installers' anti-debugger check fire, so they exit silently; stay on 10 until that is fixed.
# See docs/adr/0001-wine10-pin-and-win64.md and issue #66.
WINE_PIN_VERSION='10.0.*'

ABS_PWD=$(cd "$(dirname "$BASH_SOURCE")"; pwd)
ORG_USER=${SUDO_USER:-$USER}
IS_SYSTEMD=$(which systemctl)
DIR_TEMPLATES="$ABS_PWD/templates"
DIR_WINECACHE=$HOME/.cache/wine
APT_OPT='-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'

export DEBIAN_FRONTEND=noninteractive
# New prefixes are 64-bit: current MT4/MT5 installers are 64-bit (they still install a 32-bit
# MT4, which runs via WoW64). An existing prefix keeps its own arch (see setup_wine).
export WINEARCH=win64
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
WINE_PIN_FILE=/etc/apt/preferences.d/winehq-stable-pin

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

    # An existing prefix keeps its arch (see setup_wine); write that one, not the default, so a
    # run that stops halfway never leaves the profile and the prefix disagreeing.
    local arch
    arch=$(wineprefix_arch)
    arch=${arch:-$WINEARCH}

    # write WINE param to the .bash_profile
    cat << EOS >> "$bash_profile"

export WINEARCH=$arch
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

function pin_wine_version() {
  # Pin the wine group to WINE_PIN_VERSION so no later apt run (manual "apt upgrade",
  # unattended-upgrades, ...) moves it. Priority > 1000 also brings an already newer wine back.
  # Keep the ":i386" qualifier: without it apt applies the pin to the native arch only.
  local pin
  pin=$(printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n' "$WINE_PKGS" "$WINE_PIN_VERSION")
  if [ "$(cat "$WINE_PIN_FILE" 2>/dev/null)" != "$pin" ]; then
    printf '%s\n' "$pin" | sudo tee "$WINE_PIN_FILE" > /dev/null
    echo "Pinned wine to $WINE_PIN_VERSION ($WINE_PIN_FILE)."
  fi
}

function install_wine_packages() {
  pin_wine_version

  # Own transaction; --force-overwrite only here, for the file moved between wine packages.
  # Note: it also applies to the recommends pulled in by this single command (accepted trade-off;
  # the generic upgrade and every other install run without it).
  # --allow-downgrades: a newer wine already installed is brought back to the pinned version.
  sudo -E apt-get $APT_OPT -o Dpkg::Options::=--force-overwrite install --allow-downgrades --install-recommends winehq-stable

  local versions
  versions=$(for p in $WINE_PKGS; do dpkg-query -W -f='${Version}\n' "$p" 2>/dev/null; done | sort -u)
  local held
  held=$(apt-mark showhold 2>/dev/null | grep -E '^(winehq|wine)-stable' | tr '\n' ' ')
  if ! sudo apt-get check >/dev/null 2>&1 || [ "$(printf '%s\n' "$versions" | grep -c .)" -ne 1 ]; then
    echo "[error] wine packages are inconsistent (versions: $(echo $versions)). Try: sudo apt-get -f install -o Dpkg::Options::=--force-overwrite" >&2
    [ -n "$held" ] && echo "        These wine packages are held: $held— release them first: sudo apt-mark unhold $held" >&2
    return 1
  fi
  # shellcheck disable=SC2254  # WINE_PIN_VERSION is a glob on purpose
  case "$versions" in
    $WINE_PIN_VERSION) ;;
    *) echo "[error] wine $versions is installed, but $WINE_PIN_VERSION is required (pin: $WINE_PIN_FILE)." >&2
       [ -n "$held" ] && echo "        These wine packages are held: $held— release them first: sudo apt-mark unhold $held" >&2
       return 1 ;;
  esac
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

  # A failed update (e.g. one unreachable mirror) only means older lists; keep going. A failed
  # install/upgrade means dpkg may be half-configured, so stop instead of piling more on it (P13).
  sudo apt-get update || echo "[warn] apt-get update reported errors; continuing with the current package lists." >&2
  local rc=0
  sudo -E apt-get $APT_OPT -f install || rc=1
  [ $rc -eq 0 ] && { sudo -E apt-get $APT_OPT --with-new-pkgs upgrade || rc=1; }   # same as "apt upgrade" (P15)

  release_wine_hold
  ensure_sshd_alive
  return $rc
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
  sudo -E apt-get $APT_OPT install unattended-upgrades apt-transport-https gnupg wget jq psmisc file bc vim nano less tmux curl net-tools lsof \
    || { echo "[error] failed to install base packages." >&2; return 1; }

  ensure_time_sync

  # install gui
  sudo -E apt-get $APT_OPT install tightvncserver fonts-vlgothic xterm wm2 \
    || { echo "[error] failed to install the VNC server / desktop packages." >&2; return 1; }

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
  install_wine_packages || return 1
  ensure_sshd_alive   # reported again (as NG) by verify_and_report; not a reason to stop here
  return 0
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

    # Install the unit, and also update an existing one that differs from the current template
    # (so fixes reach already-set-up servers). The previous unit is kept as a backup.
    local unit="/etc/systemd/system/vncserver@:1.service" rendered
    rendered=$(mktemp)
    sed -e 's/%%USER_NAME%%/'"$ORG_USER"'/g' "$DIR_TEMPLATES/vncserver@:1.service" > "$rendered"
    if ! sudo cmp -s "$rendered" "$unit"; then
      if [ -f "$unit" ]; then
        local backup="$unit.bak.$(date +%Y%m%d%H%M%S)"
        sudo cp -p "$unit" "$backup"
        echo "Updating $unit from the template (previous unit saved as $backup)."
      fi
      sudo install -o root -g root -m 644 -D "$rendered" "$unit"
      sudo systemctl daemon-reload
    fi
    rm -f "$rendered"

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
# Architecture of the existing WINEPREFIX (win32 / win64), empty if there is none.
#####################################################
function wineprefix_arch() {
  local arch
  arch=$(sed -n 's/^#arch=//p' "$WINEPREFIX/system.reg" 2>/dev/null | head -n 1 | tr -d '\r')
  # Some wine versions do not write "#arch" for a 32-bit prefix; fall back to its layout.
  if [ -z "$arch" ] && [ -d "$WINEPREFIX/drive_c/windows" ]; then
    if [ -d "$WINEPREFIX/drive_c/windows/syswow64" ]; then arch=win64; else arch=win32; fi
  fi
  echo "$arch"
}

# True when the WINEPREFIX is fully initialized (registry files written, system32 populated).
function wineprefix_ok() {
  [ -s "$WINEPREFIX/system.reg" ] && [ -s "$WINEPREFIX/user.reg" ] \
    && [ -n "$(ls -A "$WINEPREFIX/drive_c/windows/system32" 2>/dev/null)" ]
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

  # A kept prefix stays in its own arch (wine refuses to open a 32-bit prefix with WINEARCH=win64
  # and vice versa); only a new prefix gets the default from the top of this script.
  local prefix_arch
  prefix_arch=$(wineprefix_arch)
  if [ -n "$prefix_arch" ]; then
    export WINEARCH=$prefix_arch
  fi
  if [ "$prefix_arch" = "win32" ]; then
    echo "[warn] $WINEPREFIX is a 32-bit prefix. MetaTrader already installed in it keeps working, but" >&2
    echo "       current MT4/MT5 installers are 64-bit and cannot run there, so the installer is not started." >&2
    echo "       To install MT, re-run in a terminal and recreate the prefix (answer y)." >&2
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
  export WINEDEBUG=$WINEDEBUG_OLD
  export DISPLAY=$DISPLAY_OLD

  # wineboot can fail without a useful exit code (e.g. an X error half-way leaves an empty
  # system32); check the result instead of writing into a broken prefix.
  if ! wineprefix_ok; then
    echo "[error] wine prefix initialization failed: $WINEPREFIX is incomplete. Check 'wine --version' and run 'wineboot -i' to see the error." >&2
    return 1
  fi

  # setting japanese fonts
  font_replace_exist=$(cat "$WINEPREFIX/user.reg" | tr -d '\r' | grep -o '\[Software\\\\Wine\\\\Fonts\\\\Replacements\]')
  if [ -z "$font_replace_exist" ]; then
    cat "$DIR_TEMPLATES/font_replace.reg" >> "$WINEPREFIX/user.reg"
  fi

  # ~/.bash_profile may still export the arch of a previous (e.g. deleted 32-bit) prefix; a
  # mismatch makes every wine call from a login shell fail, so keep it in line with the prefix.
  local bash_profile=$HOME/.bash_profile
  prefix_arch=$(wineprefix_arch)
  if [ -n "$prefix_arch" ] && grep -q '^export WINEARCH=' "$bash_profile" 2>/dev/null \
      && ! grep -qx "export WINEARCH=$prefix_arch" "$bash_profile"; then
    sed -i -e "s/^export WINEARCH=.*/export WINEARCH=$prefix_arch/" "$bash_profile"
    echo "Updated WINEARCH in $bash_profile to $prefix_arch."
  fi
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
# Result of download_and_start_mt4_installer, reported by verify_and_report:
# running / exited / download-failed / skipped-win32
INSTALLER_STATUS=""

function download_and_start_mt4_installer() {
  local name installer
  name=$(basename "$MT_INSTALLER_URL")
  installer="$DIR_WINECACHE/$name"

  if [ "$(wineprefix_arch)" = "win32" ]; then
    INSTALLER_STATUS=skipped-win32
    return 1
  fi

  echo Downloading MetaTrader installer ...
  if [ -f "$installer" ]; then
    rm "$installer"
  fi

  # A cut-off download can leave a partial file; drop it so it is reported as a download failure.
  wget -q --timeout=30 --tries=3 -N -P "$DIR_WINECACHE" "$MT_INSTALLER_URL" || rm -f "$installer"

  if [ ! -f "$installer" ]; then
    echo "[error] MT installer download failed: $MT_INSTALLER_URL" >&2
    INSTALLER_STATUS=download-failed
    return 1
  fi

  echo Staring MetaTrader installer...
  # Disable mono/gecko here too so the installer never blocks on a download dialog.
  WINEDLLOVERRIDES="mscoree=;mshtml=" WINEDEBUG=-all wine start /unix "$installer"

  # "wine start" returns at once. An installer that refuses to run (e.g. its anti-debugger check
  # on an unsupported wine) exits silently within seconds, so confirm it is still alive.
  sleep 15
  if pgrep -u "$(id -u)" -f -- "$name" >/dev/null 2>&1; then
    INSTALLER_STATUS=running
  else
    INSTALLER_STATUS=exited
    return 1
  fi
}

#####################################################
# Reboot recommendation
#####################################################
# Prints the reason a reboot is advisable, or nothing.
function reboot_required_reason() {
  if [ -f /var/run/reboot-required ]; then
    echo "updated packages request it (/var/run/reboot-required)"
    return 0
  fi
  # systemd (PID 1) or a library it uses was upgraded on disk but the old one is still running.
  # Only real files count; PID 1 also maps anonymous memfd regions that are always "(deleted)".
  # locale-archive is regenerated by locale-gen on every run and is not a reason to reboot.
  if [ -n "$(sudo grep -sE ' /(usr/)?(lib|lib64|bin|sbin)/[^ ]* \(deleted\)$' /proc/1/maps | grep -v '/locale-archive ')" ]; then
    echo "the running init (PID 1) still uses replaced files from before the upgrade"
  fi
}

#####################################################
# Final verification and result (P13): report success only when it is true.
#####################################################
function verify_and_report() {
  local ng=0 v

  echo ""
  echo "====================================================="
  echo " Result"
  echo "====================================================="

  if v=$(wine --version 2>/dev/null) && [ -n "$v" ]; then
    echo "[ OK ] wine: $v"
  else
    echo "[ NG ] wine: 'wine --version' failed"; ng=1
  fi

  if wineprefix_ok; then
    echo "[ OK ] wine prefix: $WINEPREFIX ($(wineprefix_arch))"
  else
    echo "[ NG ] wine prefix: $WINEPREFIX is missing or incomplete"; ng=1
  fi

  if [ -n "$IS_SYSTEMD" ]; then
    if systemctl is-active --quiet "vncserver@:1" && ss -tln 2>/dev/null | grep -qE '[:.]5901[[:space:]]'; then
      echo "[ OK ] VNC: vncserver@:1 is listening on 5901"
    else
      echo "[ NG ] VNC: vncserver@:1 is not running / not listening on 5901 (see: systemctl status vncserver@:1)"; ng=1
    fi
  fi

  if [ -z "$IS_SYSTEMD" ]; then
    echo "[ -- ] sshd: not checked (no systemd)"
  elif ensure_sshd_alive; then
    echo "[ OK ] sshd: listening"
  else
    echo "[ NG ] sshd: not listening"; ng=1
  fi

  case "$INSTALLER_STATUS" in
    running)         echo "[ OK ] MetaTrader installer: running on VNC (DISPLAY=:1, port 5901)" ;;
    skipped-win32)   echo "[ NG ] MetaTrader installer: not started ($WINEPREFIX is 32-bit; see the warning above)"; ng=1 ;;
    download-failed) echo "[ NG ] MetaTrader installer: download failed ($MT_INSTALLER_URL)"; ng=1 ;;
    exited)          echo "[ NG ] MetaTrader installer: exited right after start (check the wine version: $WINE_PIN_VERSION is required)"; ng=1 ;;
    *)               echo "[ NG ] MetaTrader installer: not started"; ng=1 ;;
  esac

  local reboot
  reboot=$(reboot_required_reason)
  if [ -n "$reboot" ]; then
    echo ""
    echo "[note] A reboot is recommended: $reboot. Reboot when MetaTrader is not trading: sudo reboot"
  fi

  echo "====================================================="
  if [ $ng -ne 0 ]; then
    echo "[error] Setup is NOT complete. Fix the NG items above and re-run this script." >&2
    return 1
  fi
  echo "Now MetaTrader installer is running on VNC(GUI) !!"
  echo "====================================================="
}

function die() {
  echo "[error] $*" >&2
  exit 1   # the EXIT trap still restores sshd / releases holds
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
upgrade_existing_packages || die "upgrading packages failed. Fix apt first (sudo apt-get -f install), then re-run."
set_up_locale_and_timezone

export LANG=$TARGET_LOCALE

install_packages_misc_and_needed_by_mt4 || die "installing required packages failed (see the messages above)."
install_packages_needed_by_graphical_report || echo "[warn] graphical report packages were not installed; image reports will not work." >&2
setup_auto_update_package_list
setup_vncserver
setup_wine || die "setting up wine failed (see the messages above)."
start_vncserver_service
clean_needless_files
download_and_start_mt4_installer

verify_and_report || exit 1
