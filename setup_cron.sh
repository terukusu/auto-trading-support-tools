#!/bin/bash

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"


crontab_old=$(crontab -l 2>/dev/null)

# What the current crontab already runs (comment lines do not count).
active_lines=$(printf '%s\n' "$crontab_old" | grep -v '^[[:space:]]*#')
has_legacy=0
has_atst=0
has_runner=0
if grep -q 'wrapper\.sh' <<< "$active_lines"; then
  has_legacy=1
fi
if grep -qE '(check_[a-z]+|heartbeat|wrapper|mtctl|report_image|truncate_monitoring|run_with_targets|sleep_random)\.sh' <<< "$active_lines"; then
  has_atst=1
fi
if grep -q 'check_all\.sh' <<< "$active_lines"; then
  has_runner=1
fi

if [ "$has_legacy" -eq 1 ]; then
  echo '[info] crontab に旧形式の行 (TARGET と wrapper.sh "$TARGET" ...) があります。'
  echo '       README の「既存の crontab からの移行」を参照して、旧形式の行を新しい行に置き換えてください。'
  echo '       上書き (Y) を選ぶと crontab 全体が新しいテンプレートに置き換わり、独自に追加した行も消えます。'
  echo '       このスクリプトは旧形式の行を自動では削除しません。'
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

if [ "$is_overwrite" == "1" ]; then
  echo "adding task to crontab..."
  printf '%s\n' "$new_lines" | crontab -
  rc=$?
elif [ "$has_atst" -eq 0 ]; then
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

if ! atst_has_targets; then
  echo "[info] ~/.atst/config に ATST_TARGETS (監視する MetaTrader のフォルダ名) を書いてください。例: ATST_TARGETS=('Land Prime')"
fi

echo "done"
