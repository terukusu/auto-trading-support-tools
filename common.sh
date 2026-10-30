#!/bin/bash

ATST_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/atst_config.sh
. "$ATST_HOME/lib/atst_config.sh"
# shellcheck source=lib/atst_line.sh
. "$ATST_HOME/lib/atst_line.sh"
# shellcheck source=lib/atst_mt.sh
. "$ATST_HOME/lib/atst_mt.sh"
# shellcheck source=lib/atst_notify.sh
. "$ATST_HOME/lib/atst_notify.sh"

# atst_is_weekend_epoch <epoch>
# Returns 0 when the epoch (seconds, UTC) is in the weekend of the FX market: Friday 20:00:00 to Monday
# 00:00:00 (exclusive), UTC. Returns 1 otherwise, and for anything but 1 to 12 digits (empty, not a number,
# negative, too long). Holidays are not known. Plain arithmetic, not GNU date: the same on every
# distribution and whatever the host time zone is (1970-01-01 was a Thursday). Prints nothing.
function atst_is_weekend_epoch() {
  local e dow hour

  [[ "${1-}" =~ ^[0-9]{1,12}$ ]] || return 1
  e=$((10#$1))
  dow=$(( (e / 86400 + 4) % 7 ))   # 0 = Sunday ... 6 = Saturday
  hour=$(( e % 86400 / 3600 ))
  [ "$dow" -eq 6 ] || [ "$dow" -eq 0 ] || { [ "$dow" -eq 5 ] && [ "$hour" -ge 20 ]; }
}

# atst_crontab_form_of <crontab text>
# Prints one word on one line for the form of the crontab text: "new" (check_all.sh), "legacy"
# (wrapper.sh), "mixed" (both) or "none" (neither). Comment lines do not count. Never prints the text.
# Returns 0.
function atst_crontab_form_of() {
  local active has_new=0 has_old=0

  active=$(printf '%s\n' "${1-}" | grep -v '^[[:space:]]*#')
  if grep -q 'check_all\.sh' <<< "$active"; then
    has_new=1
  fi
  if grep -q 'wrapper\.sh' <<< "$active"; then
    has_old=1
  fi
  if [ "$has_new" -eq 1 ] && [ "$has_old" -eq 1 ]; then
    echo mixed
  elif [ "$has_new" -eq 1 ]; then
    echo new
  elif [ "$has_old" -eq 1 ]; then
    echo legacy
  else
    echo none
  fi
  return 0
}

# atst_crontab_form
# Reads the user's crontab (timeout 10 crontab -l) and prints the word of atst_crontab_form_of, or
# "unknown" when crontab -l fails (no crontab, an error, the timeout). Never prints the crontab, writes
# nothing, prints nothing on stderr. Returns 0.
function atst_crontab_form() {
  local out

  if ! out=$(timeout 10 crontab -l 2>/dev/null); then
    echo unknown
    return 0
  fi
  atst_crontab_form_of "$out"
}

# atst_has_targets
# Returns 0 when ATST_TARGETS (~/.atst/config) has at least one element and none of them is empty,
# 1 otherwise (unset, (), ('') or ('a' '')). A scalar counts as one element. Prints nothing.
function atst_has_targets() {
  local t

  [ "${#ATST_TARGETS[@]}" -ge 1 ] || return 1
  for t in "${ATST_TARGETS[@]}"; do
    [ -n "$t" ] || return 1
  done
  return 0
}

atst_load_mt_list
