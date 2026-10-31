# shellcheck shell=bash
# Sourced by common.sh only (ATST_HOME is set there). Do not source this file on its own.
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

# atst_mask_tail4 <value>
# Prints ****<last 4 characters of <value>>, or only **** when <value> is shorter than 8 characters (the
# last 4 would be most of it). No newline. Run it in $(...): the value never stays in a variable of the
# calling shell (doctor.sh, setup_heartbeat.sh).
function atst_mask_tail4() {
  local s="$1"

  if [ "${#s}" -ge 8 ]; then
    s=${s: -4}
  else
    s=''
  fi
  printf '****%s' "$s"
}

function atst_read_file() {
  # shellcheck disable=SC2034  # unused local kept as in common.sh before #147 (mechanical split; the body is not changed)
  local path="$1"
  cat "$1" | sed -re 's/\r//g'
}

# $ATST_CONFIG_DIR/.imgbb_key (setup_imgbb.sh で設定) に ImgBB の API キーがあれば 0、無ければ 1。
# ATST_CONFIG_DIR が空・ファイル無し・空・改行だけ・読めないときは「無し」。atst_upload_image が curl に
# 渡すキーと同じ基準 (CR/LF を除く) で判定する。何も出力しない (キーの値を出さない。P5)。
function atst_has_imgbb_key() {
  [ -n "$ATST_CONFIG_DIR" ] || return 1
  [ -s "$ATST_CONFIG_DIR/.imgbb_key" ] || return 1
  # The braces also silence bash's own "Permission denied" for the redirection.
  [ -n "$({ tr -d '\r\n' < "$ATST_CONFIG_DIR/.imgbb_key"; } 2>/dev/null)" ]
}

# 画像を ImgBB にアップロードし、公開 URL を出力する。LINE の画像メッセージは公開 HTTPS の URL が要る。
# LINE のサーバーが認証なしで取りに来るので、URL を知っていれば誰でも見られる。
# 送る画像に秘匿したいものを含めないこと。
# ImgBB の API キー ($ATST_CONFIG_DIR/.imgbb_key、setup_imgbb.sh で設定) が無ければアップロードせず 1 を返す
# (curl を呼ばない)。画像は $ATST_IMGBB_EXPIRATION 秒 (既定 24 時間) で消える。
function atst_upload_image() {
  local file="$1"

  if [ ! -f "$file" ]; then
    echo "Error: File not found: $file" >&2
    return 1
  fi

  if ! atst_has_imgbb_key; then
    # Not logged to line_error.log: a missing key is a setting (doctor.sh shows it), not a failure.
    echo "Error: ImgBB API key is not set (run setup_imgbb.sh)" >&2
    return 1
  fi

  local response body code url key
  key=$(tr -d '\r\n' < "$ATST_CONFIG_DIR/.imgbb_key")

  # ImgBB: JSON like {"data": {..., "url": "https:\/\/i.ibb.co\/xxxx\/a.png", ...}, "success": true}
  # The key is read by curl from a pipe so that it does not show up in ps.
  # IPv4: some VPS have a broken IPv6 route.
  response=$(curl --max-time 60 --connect-timeout 10 -4 -s -w "\n%{http_code}" \
    -F "key=<"<(printf '%s' "$key") -F "expiration=${ATST_IMGBB_EXPIRATION:-86400}" \
    -F "image=@$file" "https://api.imgbb.com/1/upload" 2>/dev/null)
  code=${response##*$'\n'}
  body=${response%$'\n'*}
  url=$(atst_json_first_url "$body")
  if [ "$code" == "200" ] && [ -n "$url" ]; then
    echo "$url"
    return 0
  fi

  # cron discards stderr; leave a trace where LINE failures are logged (000 = timeout etc.).
  atst_log_line_error "upload:imgbb=$code" "$body" "画像アップロード失敗: $(basename "$file")"
  echo "Error: Upload failed" >&2
  return 1
}

# Prints the first "url": "https://..." value in a JSON text (with "\/" unescaped), or nothing.
# Other keys ending in url ("display_url" etc.) are not matched. jq is not required.
function atst_json_first_url() {
  local url
  url=$(printf '%s' "$1" | tr -d '\\' | grep -o '"url": *"https://[^"[:space:]]*"' | head -n 1 | sed -E 's/^"url": *"(.*)"$/\1/')
  [[ "$url" =~ ^https://[^[:space:]]+$ ]] && printf '%s\n' "$url"
  return 0
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

# atst_line_send_failing <n>
# Returns 0 when LINE looks dead: the last <n> headings of line_error.log (written by
# atst_log_line_error; failed image uploads "http=upload:..." do not count, "no_alert_status" does) are
# all there and the oldest of them is at most 60 minutes old. A success leaves no line, so "in a row" is
# taken as "within the last hour". Returns 1 otherwise (no or unreadable log, fewer headings, an older
# one, an empty ATST_CONFIG_DIR, a date that cannot be read). <n> is a positive integer. Prints nothing
# and changes no file (heartbeat.sh calls it every minute).
function atst_line_send_failing() {
  local n="$1" log heads ts t now

  [ -n "$ATST_CONFIG_DIR" ] || return 1
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
  log="$ATST_CONFIG_DIR/line_error.log"
  [ -r "$log" ] || return 1
  heads=$(grep -aE '^\[[0-9-]+ [0-9:]+\] LINE send failed' "$log" 2>/dev/null \
    | grep -av '^\[[0-9-]* [0-9:]*\] LINE send failed: http=upload:' | tail -n "$n")
  [ -n "$heads" ] || return 1
  [ "$(printf '%s\n' "$heads" | wc -l)" -ge "$n" ] || return 1
  ts=$(printf '%s\n' "$heads" | sed -nE '1s/^\[([0-9-]+ [0-9:]+)\].*/\1/p')
  t=$(date -d "$ts" +%s 2>/dev/null) || return 1
  [[ "$t" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  [ "$t" -ge $(( now - 3600 )) ]
}
