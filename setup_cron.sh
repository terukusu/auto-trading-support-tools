#!/bin/bash

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"


crontab_old=$(crontab -l 2>/dev/null)

# What the current crontab already runs (comment lines do not count).
active_lines=$(printf '%s\n' "$crontab_old" | grep -v '^[[:space:]]*#')
has_legacy=0
has_atst=0
has_runner=0
case "$(atst_crontab_form_of "$crontab_old")" in
  legacy) has_legacy=1 ;;
  new) has_runner=1 ;;
  mixed) has_legacy=1; has_runner=1 ;;
esac
if grep -qE '(check_[a-z]+|heartbeat|wrapper|mtctl|report_image|truncate_monitoring|run_with_targets|sleep_random)\.sh' <<< "$active_lines"; then
  has_atst=1
fi

# backup_crontab
# Saves the current crontab (crontab -l, as it is) to ~/.atst/crontab.bak.<YYYYmmddHHMMSS> with mode 600
# and prints the path. Never overwrites a file: when the name is taken (two runs in one second) it waits
# a second and takes the time again, up to 3 times. Returns 1 (after removing a partial file) when the
# crontab could not be saved; the caller then writes no crontab. Backups are never removed here.
function backup_crontab() {
  local i ts bak

  for i in 1 2 3; do
    ts=$(date +%Y%m%d%H%M%S)
    bak="$ATST_CONFIG_DIR/crontab.bak.$ts"
    if [ ! -e "$bak" ]; then
      if ( umask 077; set -C; crontab -l > "$bak" ) 2>/dev/null; then
        echo "crontab の退避: $bak"
        return 0
      fi
      # The name was free just before, so a file there now is the partial one of this run.
      rm -f -- "$bak"
      return 1
    fi
    [ "$i" -lt 3 ] && sleep 1
  done
  return 1
}

# append_targets
# Appends "ATST_TARGETS=<value>" to the end of ~/.atst/config when the config has no ATST_TARGETS line,
# the old TARGET lines hold exactly one distinct value, and that value is a one-line array of '...' or
# "..." elements (the form atst_config_parse accepts). The value is never evaluated. Otherwise it only
# says why (the config is left as it is). Returns 1 only when the append itself failed.
function append_targets() {
  local config="$ATST_CONFIG_DIR/config" v u
  local -a uniq=()
  local tab=$'\t'
  # One element: "..." without " \ $ ` inside, or '...' without ' inside; never empty (an empty name
  # would only start nothing and hide the "write ATST_TARGETS" notice below).
  local re_elem='("[^"\$`]+"|'"'"'[^'"'"']+'"'"')'
  local re="^\\([ ${tab}]*${re_elem}([ ${tab}]+${re_elem})*[ ${tab}]*\\)\$"

  if grep -qE '^[[:space:]]*(export[[:space:]]+)?ATST_TARGETS\+?=' "$config" 2>/dev/null; then
    echo "[info] ~/.atst/config に ATST_TARGETS が既にあるため追記しませんでした。crontab の TARGET と同じ MetaTrader を指しているか確認してください"
    return 0
  fi
  for v in "${target_values[@]}"; do
    for u in "${uniq[@]}"; do
      [ "$u" = "$v" ] && continue 2
    done
    uniq+=("$v")
  done
  if [ "${#uniq[@]}" -ne 1 ] || [[ "${uniq[0]}" == *[$'\r\n']* ]] || ! [[ "${uniq[0]}" =~ $re ]]; then
    echo "[info] TARGET の値は自動では追記できません。上の 1 行を ~/.atst/config の末尾に手で書いてください"
    return 0
  fi
  if [ -s "$config" ] && [ -n "$(tail -c1 "$config")" ]; then
    printf '\n' >> "$config" || return 1
  fi
  printf 'ATST_TARGETS=%s\n' "${uniq[0]}" >> "$config" || return 1
  printf 'ATST_TARGETS を ~/.atst/config の末尾に追記しました: ATST_TARGETS=%s\n' "${uniq[0]}"
  targets_appended=1
  return 0
}

target_values=()
targets_appended=0

if [ "$has_legacy" -eq 1 ]; then
  echo '[info] crontab に旧形式の行 (TARGET と wrapper.sh "$TARGET" ...) があります。'
  echo '       README の「既存の crontab からの移行」を参照して、旧形式の行を新しい行に置き換えてください。'
  echo '       上書き (Y) を選ぶと crontab 全体が新しいテンプレートに置き換わり、独自に追加した行も消えます。'
  echo '       このスクリプトは旧形式の行を自動では削除しません。'
  echo "       旧形式は ${ATST_LEGACY_CRONTAB_DEADLINE} まで動きます (期限後も監視は止まりませんが、毎朝の報告に注意が付き doctor.sh が NG になります)。"
  echo '       Y を選ぶと、元の crontab を ~/.atst/crontab.bak.<日時> に退避してから置き換え、TARGET の値を ~/.atst/config の末尾に ATST_TARGETS として追記します (追記できる形のときだけ)。'
  # Show the old TARGET value as the line to put in the config (shown only; never evaluated, and
  # neither the config nor the crontab is changed here).
  while IFS= read -r target_line; do
    target_value=${target_line#*TARGET=}
    target_value=${target_value%"${target_value##*[![:space:]]}"}
    if [ "${#target_value}" -ge 2 ]; then
      case "$target_value" in
        \"*\"|\'*\') target_value=${target_value:1:${#target_value}-2} ;;
      esac
    fi
    echo '       crontab の TARGET の値は、~/.atst/config の末尾に次の 1 行として書けます:'
    printf '         ATST_TARGETS=%s\n' "$target_value"
    target_values+=("$target_value")
  done < <(grep -E '^[[:space:]]*TARGET=' <<< "$active_lines")
fi

is_overwrite=1

if [ -n "$crontab_old" ]; then
  echo "Your crontab is not empty. Overwrite it? (Y/n)('n' means append.) "
  # No answer at all (stdin closed, unattended) must not replace the user's crontab (P13).
  if ! IFS= read -r line && [ -z "$line" ]; then
    echo "応答が無かったため crontab を変更しませんでした。" 1>&2
    exit 1
  fi

  if [ "${line,,}" == "n" ]; then
    is_overwrite=0
  fi
fi

# The template with %%ATST_HOME%% replaced. \ / & in the path are escaped for sed.
home_esc=$(printf '%s' "$ATST_HOME" | sed -e 's/[\/&]/\\&/g')
if ! new_lines=$(sed -e "s/%%ATST_HOME%%/$home_esc/g" "$ATST_TEMPLATES_DIR/crontab.txt") || [ -z "$new_lines" ]; then
  echo "[error] cannot read $ATST_TEMPLATES_DIR/crontab.txt" 1>&2
  exit 2
fi

# Before the crontab is written: save it (#143), and on an old-style crontab replaced with Y append
# ATST_TARGETS first (a failure then breaks nothing, and check_all.sh never runs without it). The old
# lines do not read ATST_TARGETS, so appending it first does not change what they monitor.
function save_before_write() {
  if [ -n "$crontab_old" ] && ! backup_crontab; then
    echo "[error] cannot save the current crontab to ~/.atst/ (the crontab was not changed)" 1>&2
    exit 2
  fi
}

if [ "$is_overwrite" == "1" ]; then
  save_before_write
  if [ "$has_legacy" -eq 1 ] && ! append_targets; then
    echo "[error] cannot append ATST_TARGETS to ~/.atst/config (the crontab was not changed)" 1>&2
    exit 2
  fi
  echo "adding task to crontab..."
  printf '%s\n' "$new_lines" | crontab -
  rc=$?
elif [ "$has_atst" -eq 0 ]; then
  save_before_write
  echo "adding task to crontab..."
  printf '%s\n' "$crontab_old" "$new_lines" | crontab -
  rc=$?
elif [ "$has_runner" -eq 1 ] && [ "$has_legacy" -eq 0 ]; then
  echo "新しい形式の行 (check_all.sh) は登録済みです。crontab は変更しませんでした。"
  rc=0
else
  # Appending next to atst lines would register the jobs twice (@reboot start, the daily image and
  # report would run twice).
  echo "crontab に atst の行が既にあるため、追記しませんでした (二重登録になるため)。" 1>&2
  echo "README の「既存の crontab からの移行」を参照して、crontab -e で行を置き換えてください。" 1>&2
  exit 1
fi

if [ "$rc" -ne 0 ]; then
  echo "[error] failed to write the crontab (crontab exited with $rc)" 1>&2
  exit 2
fi

# After an append this run still holds the ATST_TARGETS read before it: no advice then.
if [ "$targets_appended" -eq 0 ] && ! atst_has_targets; then
  echo "[info] ~/.atst/config に ATST_TARGETS (監視する MetaTrader のフォルダ名) を書いてください。例: ATST_TARGETS=('Land Prime')"
fi

echo "done"
