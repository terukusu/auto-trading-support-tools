#!/usr/bin/env bats
# IceWM on the VNC desktop (ADR 0003): the xstartup template starts icewm, the installer installs icewm
# (not wm2) and sets Wine's Decorated=N, and use_icewm_in_xstartup replaces the two exact lines older
# versions wrote (wm2's "x-window-manager &" and v1.7.0's commented-out line) in an existing
# ~/.vnc/xstartup with "icewm &" (keeping a backup), leaving any other file alone.
# The function is cut out of the installer with sed (it is defined after the source-only guard); HOME
# is the sandbox.

load test_helper

V170='# x-window-manager &   # disabled by atst: MetaTrader froze under wm2 (ADR 0002)'

setup() {
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  I="$repo/install_required_for_mt.sh"
  mkdir -p "$HOME/.vnc"
  FN="$ATST_TEST_SANDBOX/fn.sh"
  sed -n '/^function use_icewm_in_xstartup/,/^}/p' "$I" > "$FN"
  [ "$(grep -c '^function ' "$FN")" -eq 1 ]
}

teardown() {
  atst_test_teardown_sandbox
}

# ui: runs use_icewm_in_xstartup cut out of the installer.
ui() {
  run bash -c '. "$1" && use_icewm_in_xstartup' _ "$FN"
}

# xs <line>: an xstartup like the old template, ending with <line>.
xs() {
  printf '#!/bin/sh\nxsetroot -solid grey -cursor_name left_ptr\nvncconfig -iconic &\n%s\n' "$1" > "$HOME/.vnc/xstartup"
  chmod 755 "$HOME/.vnc/xstartup"
}

@test "XS-1: the template starts icewm, the installer installs icewm and not wm2, and sets Decorated=N" {
  [ "$(grep -cx 'icewm &' "$repo/templates/xstartup")" -eq 1 ]
  [ "$(grep -c '^[^#]*x-window-manager' "$repo/templates/xstartup")" -eq 0 ]
  [ "$(grep -c '^[^#]*\bwm2\b' "$I")" -eq 0 ]
  grep -q 'apt-get $APT_OPT install --no-install-recommends icewm' "$I"
  grep -qF "wine reg add 'HKCU\\Software\\Wine\\X11 Driver' /v Decorated /t REG_SZ /d N /f" "$I"
}

@test "XS-2: wm2's line becomes icewm, the rest is kept, a backup is left and the mode stays" {
  xs 'x-window-manager &'
  cp "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/orig"
  ui
  [ "$status" -eq 0 ]
  [[ "$output" == *"Switched the window manager"* ]] || false
  [ "$(grep -cx 'icewm &' "$HOME/.vnc/xstartup")" -eq 1 ]
  [ "$(grep -c 'x-window-manager' "$HOME/.vnc/xstartup")" -eq 0 ]
  grep -q '^vncconfig -iconic &$' "$HOME/.vnc/xstartup"
  [ "$(stat -c %a "$HOME/.vnc/xstartup")" = 755 ]
  local b
  b=$(ls "$HOME/.vnc/" | grep '^xstartup\.bak\.[0-9]\{14\}$')
  [ "$(printf '%s\n' "$b" | wc -l)" -eq 1 ]
  cmp -s "$HOME/.vnc/$b" "$ATST_TEST_SANDBOX/orig"
}

@test "XS-3: v1.7.0's commented-out line also becomes icewm" {
  xs "$V170"
  ui
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'icewm &' "$HOME/.vnc/xstartup")" -eq 1 ]
  [ "$(grep -c 'x-window-manager' "$HOME/.vnc/xstartup")" -eq 0 ]
}

@test "XS-3b: a v1.7.0 template (no window manager) gets icewm in place of its comment" {
  cat > "$HOME/.vnc/xstartup" <<'EOS'
#!/bin/sh

# Uncomment the following two lines for normal desktop:
# unset SESSION_MANAGER
# exec /etc/X11/xinit/xinitrc

[ -x /etc/vnc/xstartup ] && exec /etc/vnc/xstartup
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources
xsetroot -solid grey -cursor_name left_ptr
vncconfig -iconic &
# No window manager: MetaTrader on Wine froze under wm2 and clicks landed off target (ADR 0002).
# Windows have no frame and cannot be moved; MetaTrader fills the screen as it is.
EOS
  chmod 755 "$HOME/.vnc/xstartup"
  ui
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'icewm &' "$HOME/.vnc/xstartup")" -eq 1 ]
  [ "$(grep -c 'No window manager\|Windows have no frame' "$HOME/.vnc/xstartup")" -eq 0 ]
  [ "$(tail -n 1 "$HOME/.vnc/xstartup")" = 'icewm &' ]
  grep -q '^vncconfig -iconic &$' "$HOME/.vnc/xstartup"
}

@test "XS-4: a second run changes nothing and makes no second backup" {
  xs 'x-window-manager &'
  ui
  cp "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/after1"
  ui
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp -s "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/after1"
  [ "$(ls "$HOME/.vnc/" | grep -c '^xstartup\.bak\.')" -eq 1 ]
}

@test "XS-5: a custom xstartup, a missing one and a symlink are left alone" {
  printf '#!/bin/sh\nx-window-manager -display :1 &\nexec startlxde\n' > "$HOME/.vnc/xstartup"
  cp "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/custom"
  ui
  [ "$status" -eq 0 ]
  cmp -s "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/custom"

  rm "$HOME/.vnc/xstartup"
  ui
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.vnc/xstartup" ]

  xs 'x-window-manager &'
  mv "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/real"
  ln -s "$ATST_TEST_SANDBOX/real" "$HOME/.vnc/xstartup"
  ui
  [ "$status" -eq 0 ]
  grep -qx 'x-window-manager &' "$ATST_TEST_SANDBOX/real"
  [ "$(ls "$HOME/.vnc/" | grep -c '^xstartup\.bak\.')" -eq 0 ]
}

@test "XS-6: an xstartup that already starts icewm is left alone even with the old line" {
  printf '#!/bin/sh\nicewm &\nx-window-manager &\n' > "$HOME/.vnc/xstartup"
  cp "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/both"
  ui
  [ "$status" -eq 0 ]
  cmp -s "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/both"
}

@test "XS-7: setup_vncserver calls it after installing xstartup" {
  local body
  body=$(sed -n '/^function setup_vncserver/,/^}/p' "$I")
  [ -n "$body" ]
  printf '%s\n' "$body" | grep -A2 'install -m 755 -D "$DIR_TEMPLATES/xstartup"' | grep -q 'use_icewm_in_xstartup'
}
