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
# These settings come from ~/.atst/config only. A value left in the environment (a manual run, a test)
# would hide that an existing user's config lacks them (check_all.sh reports unset ATST_TARGETS).
unset ATST_TARGETS ATST_CHECK_TIMEOUT ATST_ORDER_CHECK_INTERVAL
# ATST_NOTIFY_SPOOL (the spool of one check_all.sh run, see atst_spool_begin) comes from the
# environment only: a value written in ~/.atst/config would make every check keep its notices in a
# spool nobody sends (P1). Keep the inherited value across the source and drop the config's.
_atst_spool_env=${ATST_NOTIFY_SPOOL-}
# shellcheck source=/dev/null  # ~/.atst/config lives outside the repository
if ! . "$ATST_CONFIG_FILE"; then
  # A syntax error (an unclosed quote or parenthesis) stops reading the config at that line, so the
  # settings after it are missing. Say so; the caller goes on as before.
  echo "[warn] ~/.atst/config may not have been read completely (syntax error or a failing line)" 1>&2
fi
if [ -n "$_atst_spool_env" ]; then
  export ATST_NOTIFY_SPOOL="$_atst_spool_env" 2>/dev/null
else
  unset ATST_NOTIFY_SPOOL 2>/dev/null
fi
unset _atst_spool_env

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

  local user_id="$ATST_LINE_ID"

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

  atst_line_post "$payload" "$text"
}

# atst_line_post <payload> <log_text>
# Sends one push with the finished JSON <payload>. On anything but 200 writes <log_text> (what was
# meant to be sent) to line_error.log. Returns 0 on 200, 2 when LINE rejected this message itself
# (4xx except 401/403/429; sending it again will fail again), 1 otherwise (network, timeout=000, 429,
# 5xx, and 401/403 until the token is fixed).
function atst_line_post() {
  local payload="$1" log_text="$2"
  local api_endpoint="https://api.line.me/v2/bot/message/push"

  # メッセージ送信。トークンはコマンドライン引数に載せない (ps で見えるため)。ヘッダはファイル記述子から渡す。
  local response result
  response=$(curl --max-time 30 --connect-timeout 10 -X POST "$api_endpoint" \
    -s -w "\n%{http_code}" \
    -H @<(printf 'Authorization: Bearer %s\n' "$ATST_LINE_TOKEN") \
    -H "Content-Type: application/json" \
    -d "$payload")
  result=${response##*$'\n'}

  if [ "$result" == "200" ]; then
    return 0
  fi

  # 失敗の痕跡を残す (cron は MAILTO="" で出力も捨てるため、ここに書かないと何も残らない)。
  # curl 自体の失敗 (タイムアウト等) は HTTP コード 000 になる。
  atst_log_line_error "$result" "${response%$'\n'*}" "$log_text"

  case "$result" in
    4??) [ "$result" != 401 ] && [ "$result" != 403 ] && [ "$result" != 429 ] && return 2 ;;
  esac
  return 1
}

# atst_line_texts_payload <to> <text1> [<text2> .. <text5>]
# Prints the push JSON with one text message per argument, in order (LINE takes up to 5 messages per
# push and counts the push as one, however many it holds). Returns 2 (printing nothing) unless there
# are 1 to 5 texts. The texts are passed to jq as --arg data, never as part of the filter (P6).
function atst_line_texts_payload() {
  if [ "$#" -lt 2 ] || [ "$#" -gt 6 ]; then
    echo "atst_line_texts_payload: 1 to 5 texts are needed ($(( $# > 0 ? $# - 1 : 0 )) given)" 1>&2
    return 2
  fi
  local to="$1" t i=1
  shift

  if command -v jq >/dev/null 2>&1; then
    local args=() list=""
    for t in "$@"; do
      args+=(--arg "t$i" "$t")
      list+="${list:+,}\$t$i"
      i=$((i + 1))
    done
    jq -cn --arg to "$to" "${args[@]}" "{to:\$to, messages:([$list] | map({type:\"text\",text:.}))}"
  else
    local to_e t_e messages=""
    to_e=$(printf '%s' "$to" | atst_escape_text)
    for t in "$@"; do
      t_e=$(printf '%s' "$t" | atst_escape_text)
      messages+="${messages:+,}"'{"type":"text","text":"'"$t_e"'"}'
    done
    printf '%s\n' '{"to":"'"$to_e"'","messages":['"$messages"']}'
  fi
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
# ATST_CONFIG_DIR が空なら何も書かずに 1 を返す ("/line_error.log" を作らない。#110)。
function atst_log_line_error() {
  local http_code="$1" body="$2" text="$3"
  [ -n "$ATST_CONFIG_DIR" ] || return 1
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
# atst_set_alert_status <key> <value>
# Returns 0 when recorded, 1 on an empty key, an empty ATST_ALERT_STATUS_FILE, or a lock/write failure.
# With an empty ATST_ALERT_STATUS_FILE (a broken ~/.atst/config) it does nothing: no stdin is read and
# no file is created (#110).
function atst_set_alert_status() {
  local key=$1
  local value=$2

  if [ -z "$key" ]; then
    echo "alert status key should not be empty" 1>&2
    return 1
  fi
  # Before the subshell: its "9>>" redirection would create ".lock" in the current directory.
  if [ -z "$ATST_ALERT_STATUS_FILE" ]; then
    echo "atst_set_alert_status: ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken); $key is not recorded" 1>&2
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

# atst_alert_lock_file <key>
# Prints the per-key lock file shared by atst_update_alert and atst_spool_flush. Creates nothing.
# Prints nothing and returns 1 when ATST_CONFIG_DIR is empty (#110).
function atst_alert_lock_file() {
  [ -n "$ATST_CONFIG_DIR" ] || return 1
  local lock_key="${1//[^A-Za-z0-9_]/_}"
  printf '%s\n' "$ATST_CONFIG_DIR/alert_update.${lock_key:0:200}.lock"
}

# atst_update_alert <key> <verdict> <fire_msg> <recover_msg>
# Sends fire_msg or recover_msg (one push) when atst_alert_transition says so, and records the new
# state only when the send succeeded, so a failed send is tried again on the next run.
# Inside a check_all.sh run (a valid ATST_NOTIFY_SPOOL, see atst_spool_dir) a due notice is added to
# the run's spool instead (no lock, no send, no record; returns 0) and atst_spool_flush decides again,
# sends it with the other notices of the run in one push and records it when that push succeeded.
# Returns 0 when nothing was due or both the send and the record succeeded, 1 when the send or the
# record failed or the per-key lock was not free within 35 seconds, or a notice was due while
# ATST_ALERT_STATUS_FILE is empty (nothing sent, nothing recorded, one line in line_error.log; #110),
# 2 on invalid arguments (nothing sent, nothing recorded).
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

  # Inside a check_all.sh run (#96) the notice goes to the run's spool and atst_spool_flush decides
  # again, sends and records it. When it cannot be spooled, go on and send it now (P1).
  if [ "$transition" == "1" ]; then
    msg="$fire_msg"
  else
    msg="$recover_msg"
  fi
  # The state cannot be recorded (#110): sending would repeat the same notice every run. Leave a trace
  # in line_error.log, as cron drops stderr (P1).
  if [ -z "$ATST_ALERT_STATUS_FILE" ]; then
    echo "atst_update_alert: ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken); $key is not sent" 1>&2
    atst_log_line_error no_alert_status "ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken)" "$msg"
    return 1
  fi
  if atst_spool_add "$key" "$verdict" "$msg"; then
    return 0
  fi

  # An old-style crontab line and check_all.sh (#95) can see the same transition at the same time and
  # would both send it. Serialise decide-send-record per key and decide again inside the lock, so the
  # later run reads the state the first one recorded. Only a due transition takes the lock: the usual
  # "nothing to send" path stays as cheap as before, and other keys are never held up.
  local lock
  lock=$(atst_alert_lock_file "$key")

  (
    if { exec 8>> "$lock"; } 2>/dev/null; then
      if ! flock -w 35 8; then
        # The holder is handling this very key; leave it to the next run (nothing sent or recorded).
        echo "atst_update_alert: cannot lock $lock; $key is left for the next run" 1>&2
        exit 1
      fi
      transition=$(atst_alert_transition "$key" "$verdict") || exit 2
      if [ -z "$transition" ]; then
        exit 0
      fi
    else
      # A duplicate notice is better than none (P1).
      echo "atst_update_alert: cannot open $lock; sending without the lock" 1>&2
    fi

    if [ "$transition" == "1" ]; then
      msg="$fire_msg"
    else
      msg="$recover_msg"
    fi

    if ! printf '%s\n' "$msg" | atst_send_to_line; then
      exit 1
    fi
    atst_set_alert_status "$key" "$transition" || exit 1
    exit 0
  )
}

# Notices of one check_all.sh run (#96)
# LINE counts one push as one message however many texts it holds (the free plan has 200 a month), so
# check_all.sh collects the notices of a run in a spool and sends them together:
#   atst_spool_begin -> the checks (atst_update_alert / atst_notify_text add items) -> atst_spool_flush
#   -> atst_spool_end.
# The spool is $ATST_CONFIG_DIR/check_all.spool/run.<epoch>.<runner pid>/, one file per notice named
# <6-digit sequence>.<random>: line 1 = key (empty for a text-only notice), line 2 = verdict (1/0,
# empty for a text-only notice), the rest = the text. Only check_all.sh sets ATST_NOTIFY_SPOOL; any
# other run (a check started directly or by wrapper.sh, send_to_line.sh) sends at once as before.
# atst_send_to_line always sends at once (check_order.sh needs its result to clear .pending).

# atst_spool_dir
# Prints ATST_NOTIFY_SPOOL and returns 0 when it is the spool of a running check_all.sh: exactly
# "$ATST_CONFIG_DIR/check_all.spool/run.<digits>.<digits>", an existing directory owned by us, neither
# it nor check_all.spool a symlink. Otherwise prints nothing and returns 1 (the caller sends at once).
function atst_spool_dir() {
  local dir="${ATST_NOTIFY_SPOOL-}" root="$ATST_CONFIG_DIR/check_all.spool"

  [ -n "$dir" ] && [ -n "$ATST_CONFIG_DIR" ] || return 1
  case "$dir" in
    "$root"/*) ;;
    *) return 1 ;;
  esac
  [[ "${dir#"$root"/}" =~ ^run\.[0-9]+\.[0-9]+$ ]] || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  printf '%s\n' "$dir"
}

# atst_spool_add <key> <verdict> <text>
# Adds one notice to the spool (key and verdict both empty for a text-only notice). Written to a
# temporary ".tmp.*" file and renamed, so a check killed half way leaves no broken item.
# Returns 0 when added, 1 when not (no valid spool: silently; a bad key or verdict or a failed write:
# with one line on stderr). On 1 the caller sends the notice at once.
function atst_spool_add() {
  local key="$1" verdict="$2" text="$3"
  local dir tmp f n last=0

  dir=$(atst_spool_dir) || return 1
  if [ "$#" -ne 3 ]; then
    echo "Usage: atst_spool_add <key> <verdict> <text>" 1>&2
    return 1
  fi
  case "$key" in
    *$'\n'*|*$'\r'*)
      echo "atst_spool_add: the key has a line break; not spooled" 1>&2
      return 1
      ;;
  esac
  case "$verdict" in
    1|0|'') ;;
    *)
      echo "atst_spool_add: invalid verdict: $verdict; not spooled" 1>&2
      return 1
      ;;
  esac
  if [ -z "$key" ] && [ -n "$verdict" ]; then
    echo "atst_spool_add: a verdict without a key; not spooled" 1>&2
    return 1
  fi

  if ! tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null); then
    echo "atst_spool_add: cannot write to $dir; not spooled" 1>&2
    return 1
  fi
  if ! printf '%s\n%s\n%s' "$key" "$verdict" "$text" > "$tmp"; then
    rm -f -- "$tmp"
    echo "atst_spool_add: cannot write $tmp; not spooled" 1>&2
    return 1
  fi

  # The next number after the largest one. 10#: "000008" is not octal.
  for f in "$dir"/[0-9]*; do
    n=${f##*/}
    n=${n%%.*}
    [[ "$n" =~ ^[0-9]{1,9}$ ]] || continue
    if [ "$(( 10#$n ))" -gt "$last" ]; then
      last=$(( 10#$n ))
    fi
  done
  if ! mv -- "$tmp" "$dir/$(printf '%06d' $(( last + 1 ))).${tmp##*/.tmp.}" 2>/dev/null; then
    rm -f -- "$tmp"
    echo "atst_spool_add: cannot rename $tmp; not spooled" 1>&2
    return 1
  fi
  return 0
}

# atst_notify_text
# Sends the text read from stdin like atst_send_to_line (without images), or adds it to the spool of the
# running check_all.sh run. Returns 0 when spooled, otherwise atst_send_to_line's return value.
function atst_notify_text() {
  local msg
  msg=$(cat -)
  if atst_spool_add '' '' "$msg"; then
    return 0
  fi
  printf '%s\n' "$msg" | atst_send_to_line
}

# atst_spool_begin
# For check_all.sh, holding its lock: removes what an earlier run left (it never sends that), creates
# this run's spool (mode 700) and exports ATST_NOTIFY_SPOOL for the checks. Returns 1 with one line on
# stderr and ATST_NOTIFY_SPOOL unset when the spool cannot be made (every notice is then sent at once).
function atst_spool_begin() {
  # Not "${ATST_CONFIG_DIR:?}": it ends a non-interactive shell, and check_all.sh would run no check.
  if [ -z "$ATST_CONFIG_DIR" ]; then
    echo "atst_spool_begin: ATST_CONFIG_DIR is empty; notices of this run are sent one by one" 1>&2
    unset ATST_NOTIFY_SPOOL
    return 1
  fi
  local root="$ATST_CONFIG_DIR/check_all.spool" run

  run="$root/run.$(date +%s).$$"
  rm -rf -- "${root:?}" 2>/dev/null
  if ! ( umask 077; mkdir -p -- "$root" && mkdir -- "$run" ) 2>/dev/null; then
    echo "atst_spool_begin: cannot create $run; notices of this run are sent one by one" 1>&2
    unset ATST_NOTIFY_SPOOL
    return 1
  fi
  export ATST_NOTIFY_SPOOL="$run"
  if ! atst_spool_dir >/dev/null; then
    echo "atst_spool_begin: $run is not usable; notices of this run are sent one by one" 1>&2
    unset ATST_NOTIFY_SPOOL
    return 1
  fi
  return 0
}

# atst_spool_end
# For check_all.sh at the end of a run: removes the spool and unsets ATST_NOTIFY_SPOOL. Returns 0 (a
# spool left behind is removed by the next run's atst_spool_begin).
function atst_spool_end() {
  # Nothing to remove: atst_spool_begin made no spool without ATST_CONFIG_DIR.
  if [ -z "$ATST_CONFIG_DIR" ]; then
    unset ATST_NOTIFY_SPOOL
    return 0
  fi
  local root="$ATST_CONFIG_DIR/check_all.spool"

  if ! rm -rf -- "${root:?}"; then
    echo "atst_spool_end: cannot remove $root; the next run removes it" 1>&2
  fi
  unset ATST_NOTIFY_SPOOL
  return 0
}

# atst_spool_flush <max_pushes>
# For check_all.sh: sends the notices in the spool, in the order they were added, in as few pushes as
# LINE allows, and records the keyed ones of each push that succeeded. In order:
# - The last notice of a key wins; earlier ones of the same key are dropped.
# - Takes the per-key locks of atst_update_alert (in spool order, each lock file once), waiting 10
#   seconds in all for every lock of this flush. A key whose lock is not free is left for the next run
#   (not sent, not recorded). Decides again inside the lock: a transition another run (an old-style
#   crontab line) has sent and recorded meanwhile is not sent again.
# - Joins the texts with an empty line under one "【host】" heading, up to 4900 characters per message
#   and never splitting a notice (a notice longer than that alone is cut like atst_send_to_line), and
#   up to 5 messages per push. At most <max_pushes> pushes; the rest is not sent nor recorded.
# - Records the keys of a push only when it returned 200; stops at the first failed push.
# - Removes every item it read, sent or not (a keyed notice still due is spooled again next run).
# - A keyed notice is neither sent nor recorded while ATST_ALERT_STATUS_FILE is empty (one line on
#   stderr and in line_error.log, rc 1; #110). Text-only notices are sent.
# Holds the locks until the records are written. Returns 0 when everything due was sent and recorded
# (or nothing was due, or there is no valid spool), 1 when something was left out or failed (one line
# on stderr each), 2 on an invalid <max_pushes> (does nothing).
function atst_spool_flush() {
  local max_pushes="$1" dir

  if ! [[ "$max_pushes" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: atst_spool_flush <max_pushes: 1 or more>" 1>&2
    return 2
  fi
  dir=$(atst_spool_dir) || return 0

  (
    local rc=0 f name i n key verdict text transition lockf fd deadline remain
    local -a files=() keys=() verdicts=() texts=() send=() trans=()
    local -A last_of=() lock_state=()

    # Items in spool order. "[0-9]*" only: a ".tmp.*" file is a write that never finished.
    for f in "$dir"/[0-9]*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || exit 0
    mapfile -t files < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)

    for f in "${files[@]}"; do
      name=${f##*/}
      key="" verdict="" text=""
      if ! [[ "$name" =~ ^[0-9]+\.[A-Za-z0-9]+$ ]] || [ ! -f "$f" ] || [ -L "$f" ] \
        || ! { IFS= read -r key && IFS= read -r verdict && text=$(cat); } < "$f" \
        || { [ -n "$key" ] && [ "$verdict" != 1 ] && [ "$verdict" != 0 ]; } \
        || { [ -z "$key" ] && [ -n "$verdict" ]; }; then
        echo "atst_spool_flush: skipping a broken item: $name" 1>&2
        rc=1
        continue
      fi
      i=${#keys[@]}
      keys+=("$key")
      verdicts+=("$verdict")
      texts+=("$text")
      send+=(1)
      trans+=("")
      [ -z "$key" ] || last_of["$key"]=$i
    done

    # Locks and the decision again, in spool order.
    deadline=$(( $(date +%s%3N) + 10000 ))
    for i in "${!keys[@]}"; do
      key=${keys[$i]}
      [ -n "$key" ] || continue
      if [ "${last_of[$key]}" != "$i" ]; then
        send[$i]=0
        continue
      fi
      # The state cannot be recorded (#110): do not send what would be sent again every run.
      if [ -z "$ATST_ALERT_STATUS_FILE" ]; then
        echo "atst_spool_flush: ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken); $key is not sent" 1>&2
        atst_log_line_error no_alert_status "ATST_ALERT_STATUS_FILE is empty (~/.atst/config may be broken)" "${texts[$i]}"
        send[$i]=0
        rc=1
        continue
      fi
      lockf=$(atst_alert_lock_file "$key")
      if [ -z "${lock_state[$lockf]+x}" ]; then
        if { exec {fd}>> "$lockf"; } 2>/dev/null; then
          remain=$(( deadline - $(date +%s%3N) ))
          if [ "$remain" -gt 0 ]; then
            flock -w "$(( remain / 1000 )).$(printf '%03d' $(( remain % 1000 )))" "$fd"
          else
            flock -n "$fd"
          fi
          if [ $? -eq 0 ]; then
            lock_state["$lockf"]=held
          else
            lock_state["$lockf"]=busy
          fi
        else
          # A duplicate notice is better than none (P1).
          echo "atst_spool_flush: cannot open $lockf; sending $key without the lock" 1>&2
          lock_state["$lockf"]=none
        fi
      fi
      if [ "${lock_state[$lockf]}" == busy ]; then
        echo "atst_spool_flush: cannot lock $lockf; $key is left for the next run" 1>&2
        send[$i]=0
        rc=1
        continue
      fi
      if ! transition=$(atst_alert_transition "$key" "${verdicts[$i]}"); then
        send[$i]=0
        rc=1
        continue
      fi
      if [ -z "$transition" ]; then
        send[$i]=0
        continue
      fi
      trans[$i]=$transition
    done

    # Messages: the texts joined with an empty line, a notice never split.
    local head max_len=4900 omitted="…(以下省略)" cur="" cur_items="" one
    local -a msgs=() msg_items=()
    head="【$(hostname -s)】"
    for i in "${!keys[@]}"; do
      [ "${send[$i]}" == 1 ] || continue
      one="$head${texts[$i]}"
      if [ "$(atst_char_count "$one")" -gt "$max_len" ]; then
        if [ -n "$cur_items" ]; then
          msgs+=("$cur")
          msg_items+=("$cur_items")
        fi
        msgs+=("$(atst_head_chars "$one" "$((max_len - 10))")$omitted")
        msg_items+=("$i")
        cur="" cur_items=""
      elif [ -z "$cur_items" ]; then
        cur=$one
        cur_items=$i
      elif [ "$(atst_char_count "$cur"$'\n\n'"${texts[$i]}")" -le "$max_len" ]; then
        cur+=$'\n\n'"${texts[$i]}"
        cur_items+=" $i"
      else
        msgs+=("$cur")
        msg_items+=("$cur_items")
        cur=$one
        cur_items=$i
      fi
    done
    if [ -n "$cur_items" ]; then
      msgs+=("$cur")
      msg_items+=("$cur_items")
    fi

    # Pushes of up to 5 messages each.
    local p=0 first payload log_text item
    local -a group=()
    for (( first = 0; first < ${#msgs[@]}; first += 5 )); do
      if [ "$p" -ge "$max_pushes" ]; then
        echo "atst_spool_flush: more than $max_pushes push(es) of notices; the rest is left for the next run" 1>&2
        rc=1
        break
      fi
      p=$(( p + 1 ))
      group=("${msgs[@]:first:5}")
      log_text=$(printf '%s\n\n' "${group[@]}")
      if ! payload=$(atst_line_texts_payload "$ATST_LINE_ID" "${group[@]}"); then
        rc=1
        break
      fi
      if ! atst_line_post "$payload" "$log_text"; then
        echo "atst_spool_flush: sending the notices failed; they are left for the next run" 1>&2
        rc=1
        break
      fi
      for (( n = first; n < first + ${#group[@]}; n++ )); do
        for item in ${msg_items[$n]}; do
          [ -n "${keys[$item]}" ] || continue
          atst_set_alert_status "${keys[$item]}" "${trans[$item]}" || rc=1
        done
      done
    done

    rm -f -- "${files[@]}"
    exit "$rc"
  )
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
