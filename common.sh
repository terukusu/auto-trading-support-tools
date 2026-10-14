#!/bin/bash

ATST_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ATST_TEMPLATES_DIR="$ATST_HOME/templates"
ATST_CONFIG_DIR="$HOME/.atst"

if [ ! -e "$ATST_CONFIG_DIR" ];then
  mkdir -p "$ATST_CONFIG_DIR"
fi

if [ ! -e "$ATST_CONFIG_DIR/config" ]; then
  install -m 644 -D "$ATST_TEMPLATES_DIR/config" "$ATST_CONFIG_DIR/config"
fi

ATST_CONFIG_FILE="$ATST_CONFIG_DIR/config"
# shellcheck source=/dev/null  # ~/.atst/config lives outside the repository
. "$ATST_CONFIG_FILE"

# MT4/5 need neither Wine-Mono (.NET) nor Wine-Gecko (embedded IE). Keep both disabled for every
# wine call made from cron (mtctl start, ...) so Wine never opens a download dialog unattended
# (P10). cron does not read ~/.bash_profile, so this must live here.
# A value already set in the environment or ~/.atst/config (even empty, to opt out) wins.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES-mscoree=;mshtml=}"

function atst_random_sleep() {
  local max_sleep=${1:-30}
  local random=$(( $(dd if=/dev/urandom bs=2 count=1 2> /dev/null | cksum | cut -d' ' -f1) % 32767 ))
  local sleep_time=$(($random % $max_sleep))
  sleep $sleep_time
}

function atst_log() {
  echo "[$(date "+%Y-%m-%d %H:%M:%S")] $*"
}

function atst_to_upper() {
  cat - | tr '[a-z]' '[A-Z]'
}

function atst_to_lower() {
  cat - | tr '[A-Z]' '[a-z]'
}

function atst_escape_text() {
  if [ "$OSTYPE" != "${OSTYPE#darwin}" ];then
    # For Mac 改行付加。末尾に最低２個の改行がないと出力が空文字になるので。
    cat - <(echo -en '\n\n') | sed -e 's/\r//g' | sed -e 's/\\/\\\\/g' | sed -e :loop -e 'N; $!b loop' -e 's/\n/\\n/g' | sed -e 's/\"/\\"/g' | sed -e 's/\//\\\//g'
  else
    # For linux (gnu sed)
    cat - | sed -re 's/\r//g' | sed -re 's/\\/\\\\/g' | sed -re ':loop;N;$!b loop;s/\n/\\n/g' | sed -re 's/\"/\\"/g' | sed -re 's/\//\\\//g'
  fi
}

# 文字数 (バイト数ではない) を数える / 先頭 n 文字を取り出す。cron の既定ロケールでは bash の
# ${#var} や cut -c がバイト単位になり、日本語を途中で切ってしまうため UTF-8 ロケールで扱う。
# (サブシェル内でロケールを切り替える。別プロセスに渡すと 128KiB 超の本文で引数長制限に当たる)
function atst_char_count() {
  ( LC_ALL=C.UTF-8; printf %s "${#1}" )
}

function atst_head_chars() {
  ( LC_ALL=C.UTF-8; printf %s "${1:0:$2}" )
}

function atst_read_file() {
  local path="$1"
  cat "$1" | sed -re 's/\r//g'
}

# 画像を一時置き場にアップロードし、公開 URL を出力する。LINE の画像メッセージは公開 HTTPS の URL が要る。
# Litterbox (catbox.moe の一時置き場) に 72 時間だけ置く。URL を知っていれば誰でも見られるので、
# 送る画像に秘匿したいものを含めないこと。(以前の 0x0.st は 2026 年にアップロードを停止した)
function atst_upload_image() {
  local file="$1"
  local api="https://litterbox.catbox.moe/resources/internals/api.php"

  if [ ! -f "$file" ]; then
    echo "Error: File not found: $file" >&2
    return 1
  fi

  local response url code
  # IPv4: some VPS have a broken IPv6 route (kept from the 0x0.st version).
  response=$(curl --max-time 60 --connect-timeout 10 -4 -s -w "\n%{http_code}" \
    -F reqtype=fileupload -F time=72h -F "fileToUpload=@$file" "$api" 2>/dev/null)
  code=${response##*$'\n'}
  url=${response%$'\n'*}

  if [ "$code" == "200" ] && [[ "$url" =~ ^https://[^[:space:]]+$ ]]; then
    echo "$url"
    return 0
  fi

  # cron discards stderr; leave a trace where LINE failures are logged (000 = timeout etc.).
  atst_log_line_error "upload:$code" "$url" "画像アップロード失敗: $(basename "$file")"
  echo "Error: Upload failed" >&2
  return 1
}

# LINE送信関数
# shellcheck disable=SC2120  # image files are optional; atst_update_alert sends text only
function atst_send_to_line() {
  local msg; msg=$(cat -)
  # 画像ファイル (0 〜 4 個)。LINE は 1 回の push を何個のメッセージが入っていても 1 通と数える
  # (無料プランは月 200 通まで) ので、まとめて送れるものはまとめる。1 回の push は最大 5 メッセージ。
  local image_files=("${@:1:4}")

  local channel_access_token="$ATST_LINE_TOKEN"
  local user_id="$ATST_LINE_ID"
  local api_endpoint="https://api.line.me/v2/bot/message/push"

  # 通知本文。MT 由来の値などが含まれるため JSON へはエスケープして埋め込む (P6)。
  local text
  text="【$(hostname -s)】$msg"

  # LINE のテキストは 5000 文字まで。超えると送信自体が失敗して通知が消えるので切り詰める
  # (絵文字等を 2 文字と数える場合に備えて少し余裕を持たせる)。
  local max_len=4900 omitted="…(以下省略)"
  if [ "$(atst_char_count "$text")" -gt "$max_len" ]; then
    text="$(atst_head_chars "$text" "$((max_len - 10))")$omitted"
  fi

  # 画像をアップロード。失敗したものは本文に注記して除く。
  local image_urls=() image_file image_url upload_failed=0
  for image_file in "${image_files[@]}"; do
    [ -n "$image_file" ] || continue
    image_url=$(atst_upload_image "$image_file")
    if [ $? -ne 0 ] || [ -z "$image_url" ]; then
      upload_failed=$((upload_failed + 1))
    else
      image_urls+=("$image_url")
    fi
  done
  if [ "$upload_failed" -gt 0 ]; then
    text="$text (画像アップロード失敗: ${upload_failed}枚)"
  fi

  # ペイロード生成: jq があれば全エスケープを jq に任せる。無ければ atst_escape_text を通す。
  local payload
  if command -v jq >/dev/null 2>&1; then
    payload=$(printf '%s\n' "${image_urls[@]}" | jq -cRn --arg to "$user_id" --arg t "$text" \
      '{to:$to, messages:([{type:"text",text:$t}] + [inputs | select(length > 0) | {type:"image",originalContentUrl:.,previewImageUrl:.}])}')
  else
    local t_e u_e url_e messages
    t_e=$(printf '%s' "$text" | atst_escape_text)
    u_e=$(printf '%s' "$user_id" | atst_escape_text)
    messages='{"type":"text","text":"'"$t_e"'"}'
    for image_url in "${image_urls[@]}"; do
      url_e=$(printf '%s' "$image_url" | atst_escape_text)
      messages+=',{"type":"image","originalContentUrl":"'"$url_e"'","previewImageUrl":"'"$url_e"'"}'
    done
    payload='{"to":"'"$u_e"'","messages":['"$messages"']}'
  fi

  # メッセージ送信。トークンはコマンドライン引数に載せない (ps で見えるため)。ヘッダはファイル記述子から渡す。
  local response result
  response=$(curl --max-time 30 --connect-timeout 10 -X POST "$api_endpoint" \
    -s -w "\n%{http_code}" \
    -H @<(printf 'Authorization: Bearer %s\n' "$channel_access_token") \
    -H "Content-Type: application/json" \
    -d "$payload")
  result=${response##*$'\n'}

  if [ "$result" == "200" ]; then
    return 0
  fi

  # 失敗の痕跡を残す (cron は MAILTO="" で出力も捨てるため、ここに書かないと何も残らない)。
  # curl 自体の失敗 (タイムアウト等) は HTTP コード 000 になる。
  atst_log_line_error "$result" "${response%$'\n'*}" "$text"

  # 2: LINE rejected this message itself (400 etc.); sending it again will fail again.
  # 1: may succeed later (network, timeout=000, 429, 5xx, and 401/403 until the token is fixed).
  case "$result" in
    4??) [ "$result" != 401 ] && [ "$result" != 403 ] && [ "$result" != 429 ] && return 2 ;;
  esac
  return 1
}

# 当月の LINE 送信数と上限を "<送信数> <上限>" で出力する (上限なしのプランは上限を "-")。
# 取得できなければ何も出力せず 1 を返す。
function atst_line_quota() {
  local api="https://api.line.me/v2/bot/message/quota" quota usage limit

  quota=$(curl --max-time 30 --connect-timeout 10 -s -f "$api" \
    -H @<(printf 'Authorization: Bearer %s\n' "$ATST_LINE_TOKEN")) || return 1
  usage=$(curl --max-time 30 --connect-timeout 10 -s -f "$api/consumption" \
    -H @<(printf 'Authorization: Bearer %s\n' "$ATST_LINE_TOKEN")) || return 1

  usage=$(printf '%s' "$usage" | grep -o '"totalUsage" *: *[0-9]*' | grep -o '[0-9]*$')
  [ -n "$usage" ] || return 1
  if printf '%s' "$quota" | grep -q '"type" *: *"limited"'; then
    limit=$(printf '%s' "$quota" | grep -o '"value" *: *[0-9]*' | grep -o '[0-9]*$')
  fi
  echo "$usage ${limit:--}"
}

# LINE 送信失敗を $ATST_CONFIG_DIR/line_error.log に記録する。肥大しないよう末尾 1000 行に保つ。
function atst_log_line_error() {
  local http_code="$1" body="$2" text="$3"
  local log="$ATST_CONFIG_DIR/line_error.log"

  # 通知本文を含むので本人以外に読ませない。
  [ -e "$log" ] || ( umask 077; : > "$log" )
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] LINE send failed: http=$http_code script=$(basename "$0")"
    echo "  response: $(atst_head_chars "$(printf '%s' "$body" | tr -d '\r\n')" 500)"
    echo "  message: $(atst_head_chars "$(printf '%s' "$text" | tr '\r\n' '  ')" 200)"
  } >> "$log"

  if [ "$(wc -l < "$log")" -gt 1000 ]; then
    local tmp
    tmp=$(mktemp "$ATST_CONFIG_DIR/line_error.log.XXXXXX") && tail -n 1000 "$log" > "$tmp" && mv "$tmp" "$log"
  fi
}

function atst_abs_path() {
  local target_dir
  target_dir=$(dirname "$1")
  echo "$(cd "$target_dir" && pwd)/$(basename "$1")"
}

# Prints "<install folder in upper case>\t<data folder>" for every MetaTrader data folder in the prefix.
# Build 600+ keeps MQL4/MQL5 (Files, Experts) in a data folder under AppData when the install folder is
# not writable for it (e.g. Program Files) and records the install folder in its origin.txt (UTF-16LE,
# Windows path). winepath would start wine on every cron run, so "X:\..." is mapped to
# $WINEPREFIX/drive_x/... here.
function atst_gen_mt_origins() {
  # same form as mt_home (atst_abs_path)
  local prefix
  prefix=$(cd "$WINEPREFIX" && pwd)
  local origin win_path origin_path

  for origin in "$prefix"/drive_c/users/*/AppData/Roaming/MetaQuotes/Terminal/*/origin.txt; do
    [ -f "$origin" ] || continue
    win_path=$(iconv -f UTF-16LE -t UTF-8 "$origin" 2>/dev/null | tr -d '\r\n')
    win_path=${win_path#$'\xef\xbb\xbf'}
    [[ "$win_path" =~ ^[A-Za-z]: ]] || continue
    origin_path=${win_path:2}
    origin_path="$prefix/drive_${win_path:0:1}${origin_path//\\//}"
    origin_path=${origin_path%/}
    printf '%s\t%s\n' "${origin_path^^}" "${origin%/origin.txt}"
  done
}

# Prints the data folder of the MetaTrader installed in $1, choosing from $2 (atst_gen_mt_origins).
# Without one (older builds, /portable) the install folder itself is the data folder. When several were
# used (the prefix was copied from another user, switched to /portable later, ...), the one whose logs/
# was updated last wins; MT writes there daily.
function atst_find_mt_data_dir() {
  local mt_home="$1"
  local origins="$2"
  local home_upper=${mt_home^^}
  local path dir data_dir

  while IFS=$'\t' read -r path dir; do
    [ -n "$path" ] && [ "$path" == "$home_upper" ] || continue
    if [ -z "$data_dir" ] || [ "$dir/logs" -nt "$data_dir/logs" ]; then
      data_dir=$dir
    fi
  done <<< "$origins"

  if [ -n "$data_dir" ] && ! [ "$mt_home/logs" -nt "$data_dir/logs" ]; then
    echo "$data_dir"
  else
    echo "$mt_home"
  fi
}

# Detects the MetaTrader installs under $WINEPREFIX/drive_*/Program*/ (terminal*.exe up to 2 levels
# deep) and fills the global arrays mt_term / mt_home / mt_data / mt_name / mt_type, index 0.. in the
# sort order of the terminal*.exe paths. The arrays are emptied first, so calling it again reloads.
# Folder names are never run as shell code (#93). Starts neither wine nor winepath. Always returns 0.
#
#    mt_term[0]='/home/user/.wine/drive_c/Program Files/MetaTrader 4/terminal.exe'
#    mt_home[0]='/home/user/.wine/drive_c/Program Files/MetaTrader 4'
#    mt_data[0]='/home/user/.wine/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/<hash>'
#    mt_name[0]='METATRADER 4'
#    mt_type[0]='MT4'
#
function atst_load_mt_list() {
  mt_term=(); mt_home=(); mt_data=(); mt_name=(); mt_type=()
  [ -d "$WINEPREFIX" ] || return 0

  local origins line home type n=0
  origins=$(atst_gen_mt_origins)

  # NUL-delimited so that any byte in a folder name survives; only the last sort decides the order
  while IFS= read -r -d '' line; do
    line=$(atst_abs_path "$line")
    home=$(dirname "$line")
    if [ -d "$home/MQL4" ]; then
      type=MT4
    elif [ -d "$home/MQL5" ]; then
      type=MT5
    else
      echo "cannot determine MT4/MT5. bcause it don't have MQL4/ML5 folder: '$home'" 1>&2
      continue
    fi
    mt_term[n]=$line
    mt_home[n]=$home
    mt_data[n]=$(atst_find_mt_data_dir "$home" "$origins")
    mt_name[n]=$(basename "$home" | atst_to_upper)
    mt_type[n]=$type
    n=$((n + 1))
  done < <(find "$WINEPREFIX" -maxdepth 1 -type d -name 'drive_*' -print0 | while IFS= read -r -d '' drive; do
    find "$drive" -maxdepth 1 -type d -name 'Program*' -print0 | while IFS= read -r -d '' program_folder; do
      find "$program_folder" -maxdepth 2 -name 'terminal*.exe' -print0
    done
  done | sort -z)
  return 0
}

# return the index of MetaTrader which folder has specified prefix
# return empty when it's not found.
#
function atst_find_mt_index() {
  local target_mt_name="$1"

  i=0
  while [ $i -lt ${#mt_home[@]} ]; do
    match="$(echo ${mt_name[$i]} | grep -ioE "^$target_mt_name")"
    if [ -n "$match" ]; then
      echo $i
      break
    fi
    let i++
  done
}

# return absolute path of the terminal.exe
# Returns the path of the termina.exe with a case-insensitive
# prefix match between argument 1 and the folder name.
#
function atst_find_terminal() {
  local target_mt_name=$1

  local target_mt_index
  target_mt_index=$(atst_find_mt_index "$target_mt_name")

  if [ -n "$target_mt_index" ]; then
    echo "${mt_term[$target_mt_index]}"
  fi
}

# atst_to_win_path <unix path> <prefix>
# Prints the Windows form of <unix path> when it is <prefix>/drive_<x>/<rest>: "<X>:\<rest>" with every
# / turned into \ and the drive letter in upper case. Prints nothing for any other path. <prefix> is
# the logical path without a trailing / (cd "$WINEPREFIX" && pwd, the form of mt_term). Pure string
# work (no winepath, no sed/grep on the path), so ', blanks, [, * and \ survive. Always returns 0.
function atst_to_win_path() {
  local rest drive

  [ "$#" -ge 2 ] && [ -n "$1" ] && [ -n "$2" ] || return 0
  rest=${1#"$2"/drive_}
  [ "$rest" != "$1" ] && [ "${rest:1:1}" = / ] || return 0
  drive=${rest:0:1}
  rest=${rest:1}
  printf '%s\n' "${drive^^}:${rest//\//\\}"
}

# atst_find_pid <MT name>
# Prints the pid of the running MetaTrader whose folder name starts with <MT name> (atst_find_terminal),
# or nothing. Several matches print the smallest pid. Always returns 0 and never writes to stderr.
# Reads $ATST_PROC_ROOT/<pid>/ (default /proc; tests point it elsewhere) with bash builtins only:
# neither winepath (it starts Wine) nor ps/grep is run. A process matches when all of these hold:
#  - its effective uid (status, Uid:) is ours. Processes of other users are ignored on purpose:
#    mtctl stop can only kill our own, and WINEPREFIX lives under our HOME.
#  - argv[0] (argv[1] when argv[0] is wine/wine64/wine-preloader/wine64-preloader), without
#    surrounding ", equals mt_term or its Windows form (atst_to_win_path) ignoring case. Exact match
#    only: "...\MT AB\terminal.exe" or "...\terminal.exe.bak" is not "...\MT A\terminal.exe".
#  - for the Windows form only, its prefix (environ WINEPREFIX, else environ HOME/.wine, else our
#    HOME/.wine) is our WINEPREFIX, both compared as physical paths (cd && pwd -P). A process whose
#    environ cannot be read, or whose prefix is relative, does not match.
# comm, exe and maps are not used: a process started with "exec -a" keeps the comm/exe of the real
# program, and the tests start one so.
function atst_find_pid() {
  local root=${ATST_PROC_ROOT:-/proc}
  local term prefix_l win t_unix t_win my_prefix_p best
  local d pid a0 a1 x u form euid k e rest kv ewp ehome env_ok p cand_p

  term=$(atst_find_terminal "$1")
  [ -n "$term" ] || return 0
  # same logical form as mt_term (atst_abs_path), as in atst_gen_mt_origins
  prefix_l=$(cd "$WINEPREFIX" 2>/dev/null && pwd)
  win=""
  [ -n "$prefix_l" ] && win=$(atst_to_win_path "$term" "$prefix_l")
  t_unix=${term^^}
  t_win=${win^^}
  my_prefix_p=""
  best=""

  for d in "$root"/[0-9]*/; do
    pid=${d%/}
    pid=${pid##*/}
    case $pid in ''|*[!0-9]*) continue ;; esac
    [ -n "$best" ] && [ "$pid" -ge "$best" ] && continue

    # 2>/dev/null comes before < so that a vanished or unreadable file prints nothing
    a0=""
    a1=""
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null < "$d/cmdline"
    [ -n "$a0" ] || continue

    form=""
    for x in "$a0" "$a1"; do
      [[ $x == \"*\" ]] && [ "${#x}" -ge 2 ] && x=${x:1:${#x}-2}
      u=${x^^}
      if [ "$u" = "$t_unix" ]; then
        form=unix
        break
      fi
      if [ -n "$t_win" ] && [ "$u" = "$t_win" ]; then
        form=win
        break
      fi
      # argv[1] is looked at only when argv[0] is the wine loader
      case ${x##*/} in
        wine|wine64|wine-preloader|wine64-preloader) ;;
        *) break ;;
      esac
    done
    [ -n "$form" ] || continue

    euid=""
    { while IFS=$'\t' read -r k _ e rest; do
        if [ "$k" = Uid: ]; then
          euid=$e
          break
        fi
      done; } 2>/dev/null < "$d/status"
    [ "$euid" = "$EUID" ] || continue

    # a unix path already contains the prefix; a Windows path does not
    if [ "$form" = win ]; then
      ewp=""
      ehome=""
      env_ok=0
      { while IFS= read -r -d '' kv || [ -n "$kv" ]; do
          case $kv in
            WINEPREFIX=*) ewp=${kv#WINEPREFIX=} ;;
            HOME=*) ehome=${kv#HOME=} ;;
          esac
        done
        env_ok=1; } 2>/dev/null < "$d/environ"
      [ "$env_ok" = 1 ] || continue
      if [ -n "$ewp" ]; then
        p=$ewp
      elif [ -n "$ehome" ]; then
        p=$ehome/.wine
      else
        p=$HOME/.wine
      fi
      case $p in /*) ;; *) continue ;; esac
      [ -n "$my_prefix_p" ] || my_prefix_p=$(cd "$WINEPREFIX" 2>/dev/null && pwd -P)
      [ -n "$my_prefix_p" ] || continue
      cand_p=$(cd "$p" 2>/dev/null && pwd -P)
      [ -n "$cand_p" ] && [ "$cand_p" = "$my_prefix_p" ] || continue
    fi
    best=$pid
  done

  [ -n "$best" ] && printf '%s\n' "$best"
  return 0
}

function atst_get_monitoring_csv_path() {
  local target_name="$1"
  local target_mt_home
  target_mt_home=$(atst_get_mql_folder_path "$target_name")

  if [ -z "$target_mt_home" ]; then
    return 0
  fi

  echo "$target_mt_home/Files/terminal_monitoring.csv"
}

function atst_get_mql_folder_path() {
  local target_name="$1"

  local target_index
  target_index=$(atst_find_mt_index "$target_name")

  if [ -z "$target_index" ]; then
    return 0;
  fi

  local target_path=${mt_data[$target_index]}
  local target_type=${mt_type[$target_index]}

  local target_mql_folder

  if [ "$target_type" == "MT4" ]; then
    target_mql_folder="MQL4"
  else
    target_mql_folder="MQL5"
  fi

  echo "$target_path/$target_mql_folder"
}

function atst_traverse_mt() {
  local callback_function="$1"
  shift

  local target_names=("$@")

  local target_name target_index target_path target_type target_fullname

  for target_name in "${target_names[@]}"; do
    target_index=$(atst_find_mt_index "$target_name")

    if [ -z "$target_index" ]; then
      continue
    fi

    target_path=${mt_home[$target_index]}
    target_type=${mt_type[$target_index]}
    target_fullname=${mt_name[$target_index]}

    "$callback_function" "$target_name" "$target_fullname" "$target_path" "$target_type"
  done
}

# alert_status は "キー,値,更新時刻(epoch)" の行の集まり。check_* が毎分並行して更新するので、
# 更新は flock で排他し、一時ファイル経由で置き換える (sed -i と >> の競合で行が重複・欠落しないように)。
# キーは正規表現ではなく先頭列の完全一致で探す (PROCESS_X が PROCESS_X_2 に当たらないように)。
function atst_set_alert_status() {
  local key=$1
  local value=$2

  if [ -z "$key" ]; then
    echo "alert status key should not be empty" 1>&2
    return 1
  fi

  (
    flock -w 10 9 || { echo "cannot lock $ATST_ALERT_STATUS_FILE" 1>&2; exit 1; }
    local tmp
    tmp=$(mktemp "$ATST_ALERT_STATUS_FILE.XXXXXX") || exit 1
    touch "$ATST_ALERT_STATUS_FILE"
    awk -F, -v OFS=, -v k="$key" -v v="$value" -v t="$(date +%s)" '
      $1 == k { if (!done) print k, v, t; done = 1; next }
      { print }
      END { if (!done) print k, v, t }
    ' "$ATST_ALERT_STATUS_FILE" > "$tmp" && mv "$tmp" "$ATST_ALERT_STATUS_FILE" || { rm -f "$tmp"; exit 1; }
  ) 9>> "$ATST_ALERT_STATUS_FILE.lock"
}

# 指定キーの列 (2: 値, 3: 更新時刻) を返す。キーが無ければ default。
function atst_get_alert_status_field() {
  local key="$1" field="$2" default="$3" found

  if [ -e "$ATST_ALERT_STATUS_FILE" ]; then
    found=$(awk -F, -v k="$key" -v f="$field" '$1 == k { print $f; exit }' "$ATST_ALERT_STATUS_FILE")
  fi
  echo "${found:-$default}"
}

function atst_get_alert_status() {
  atst_get_alert_status_field "$1" 2 "$2"
}

function atst_get_alert_status_time() {
  atst_get_alert_status_field "$1" 3 "$2"
}

# alert_status records what has been delivered to LINE, not what was observed: a key changes only
# after its message was sent. The message texts belong to the callers (check_*.sh).

# atst_alert_transition <key> <verdict>
# verdict: 1 = abnormal observed, 0 = normal observed, empty = undecided (between the thresholds).
# Prints "1" when the fire message is due (verdict 1 and state is not 1), "0" when the recover
# message is due (verdict 0 and state 1), nothing otherwise. Reads the state only; writes nothing.
# Returns 2 on an empty key or an invalid verdict.
function atst_alert_transition() {
  local key="$1" verdict="$2" state

  if [ -z "$key" ]; then
    echo "atst_alert_transition: key should not be empty" 1>&2
    return 2
  fi
  case "$verdict" in
    1|0) ;;
    '') return 0 ;;
    *)
      echo "atst_alert_transition: invalid verdict: $verdict" 1>&2
      return 2
      ;;
  esac

  state=$(atst_get_alert_status "$key")
  if [ "$verdict" == "1" ] && [ "$state" != "1" ]; then
    echo 1
  elif [ "$verdict" == "0" ] && [ "$state" == "1" ]; then
    echo 0
  fi
  return 0
}

# atst_update_alert <key> <verdict> <fire_msg> <recover_msg>
# Sends fire_msg or recover_msg (one push) when atst_alert_transition says so, and records the new
# state only when the send succeeded, so a failed send is tried again on the next run.
# Returns 0 when nothing was due or both the send and the record succeeded, 1 when the send or the
# record failed, 2 on invalid arguments (nothing sent, nothing recorded).
function atst_update_alert() {
  if [ "$#" -ne 4 ]; then
    echo "Usage: atst_update_alert <key> <verdict> <fire_msg> <recover_msg>" 1>&2
    return 2
  fi

  local key="$1" verdict="$2" fire_msg="$3" recover_msg="$4"
  local transition msg

  transition=$(atst_alert_transition "$key" "$verdict") || return 2
  if [ -z "$transition" ]; then
    return 0
  fi

  if [ "$transition" == "1" ]; then
    msg="$fire_msg"
  else
    msg="$recover_msg"
  fi

  if ! printf '%s\n' "$msg" | atst_send_to_line; then
    return 1
  fi
  atst_set_alert_status "$key" "$transition" || return 1
  return 0
}

atst_load_mt_list
