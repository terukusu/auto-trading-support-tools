#!/usr/bin/env bats
# No window manager on the VNC desktop (ADR 0002): the xstartup template starts none, the installer no
# longer installs wm2, and disable_window_manager_in_xstartup comments out the line the old template
# wrote in an existing ~/.vnc/xstartup (keeping a backup) and leaves any other file alone.
# The function is cut out of the installer with sed (it is defined after the source-only guard); HOME
# is the sandbox.

load test_helper

setup() {
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  I="$repo/install_required_for_mt.sh"
  mkdir -p "$HOME/.vnc"
  FN="$ATST_TEST_SANDBOX/fn.sh"
  sed -n '/^function disable_window_manager_in_xstartup/,/^}/p' "$I" > "$FN"
  [ "$(grep -c '^function ' "$FN")" -eq 1 ]
}

teardown() {
  atst_test_teardown_sandbox
}

# dw: runs disable_window_manager_in_xstartup cut out of the installer.
dw() {
  run bash -c '. "$1" && disable_window_manager_in_xstartup' _ "$FN"
}

old_xstartup() {
  cat > "$HOME/.vnc/xstartup" <<'EOS'
#!/bin/sh
xsetroot -solid grey -cursor_name left_ptr
vncconfig -iconic &
x-window-manager &
EOS
  chmod 755 "$HOME/.vnc/xstartup"
}

@test "XS-1: the template starts no window manager and the installer does not install wm2" {
  [ "$(grep -c '^[^#]*x-window-manager' "$repo/templates/xstartup")" -eq 0 ]
  [ "$(grep -c '^[^#]*\bwm2\b' "$I")" -eq 0 ]
  grep -q 'vncconfig -iconic &' "$repo/templates/xstartup"
}

@test "XS-2: the old line is commented out, the rest is kept, a backup is left and the mode stays" {
  old_xstartup
  cp "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/orig"
  dw
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disabled the window manager"* ]] || false
  [ "$(grep -c '^x-window-manager' "$HOME/.vnc/xstartup")" -eq 0 ]
  grep -q '^# x-window-manager &' "$HOME/.vnc/xstartup"
  grep -q '^vncconfig -iconic &$' "$HOME/.vnc/xstartup"
  [ "$(stat -c %a "$HOME/.vnc/xstartup")" = 755 ]
  local b
  b=$(ls "$HOME/.vnc/" | grep '^xstartup\.bak\.[0-9]\{14\}$')
  [ "$(printf '%s\n' "$b" | wc -l)" -eq 1 ]
  cmp -s "$HOME/.vnc/$b" "$ATST_TEST_SANDBOX/orig"
}

@test "XS-3: a second run changes nothing and makes no second backup" {
  old_xstartup
  dw
  cp "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/after1"
  dw
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp -s "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/after1"
  [ "$(ls "$HOME/.vnc/" | grep -c '^xstartup\.bak\.')" -eq 1 ]
}

@test "XS-4: an xstartup without the exact line, a missing one and a symlink are left alone" {
  printf '#!/bin/sh\nx-window-manager -display :1 &\nexec startlxde\n' > "$HOME/.vnc/xstartup"
  cp "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/custom"
  dw
  [ "$status" -eq 0 ]
  cmp -s "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/custom"

  rm "$HOME/.vnc/xstartup"
  dw
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.vnc/xstartup" ]

  old_xstartup
  mv "$HOME/.vnc/xstartup" "$ATST_TEST_SANDBOX/real"
  ln -s "$ATST_TEST_SANDBOX/real" "$HOME/.vnc/xstartup"
  dw
  [ "$status" -eq 0 ]
  grep -q '^x-window-manager &$' "$ATST_TEST_SANDBOX/real"
  [ "$(ls "$HOME/.vnc/" | grep -c '^xstartup\.bak\.')" -eq 0 ]
}

@test "XS-5: setup_vncserver calls it after installing xstartup" {
  local body
  body=$(sed -n '/^function setup_vncserver/,/^}/p' "$I")
  [ -n "$body" ]
  printf '%s\n' "$body" | grep -A2 'install -m 755 -D "$DIR_TEMPLATES/xstartup"' | grep -q 'disable_window_manager_in_xstartup'
}
