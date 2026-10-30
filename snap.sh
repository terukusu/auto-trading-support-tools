#!/bin/bash
# snap.sh: takes one picture of the VNC desktop (:1) with vncsnapshot (#148).
# Saves it as ~/.atst/snap/YYYYmmdd-HHMMSS.jpg (mode 600; a new directory is made 700, an existing one
# keeps its mode) and prints its absolute path as the only line on stdout, so that it can be fetched
# from a phone with ssh / scp instead of opening VNC. [error] / [notice] lines go to stderr.
# Keeps the newest ATST_SNAP_KEEP (1-1000, default 10) pictures: only regular files directly in
# ~/.atst/snap/ named like YYYYmmdd-HHMMSS.jpg are ever removed, never the one just taken.
# --line also sends it to LINE through ImgBB (the picture shows the account number and the balance and
# can be seen by anyone with its URL until ATST_IMGBB_EXPIRATION). Without an ImgBB key nothing is
# taken. ATST_IMAGE_REPORT_DESKTOP (the daily report) is not looked at. Never prompts.
# Exit codes: 0 done, 1 wrong arguments, 2 failed (nothing taken, or the LINE push failed).

snap_usage() {
  echo "Usage: $(basename "$0") [--line]"
  echo "  takes one picture of the VNC desktop (:1) into ~/.atst/snap/ and prints its path."
  echo "  --line: also send it to LINE via ImgBB (the picture shows the account number and balance)."
}

# Checked before common.sh is read, so a wrong call does not even create ~/.atst/config.
snap_line=0
if [ "$#" -eq 1 ] && [ "$1" = "-h" ]; then
  snap_usage
  exit 0
elif [ "$#" -eq 1 ] && [ "$1" = "--line" ]; then
  snap_line=1
elif [ "$#" -ne 0 ]; then
  snap_usage 1>&2
  exit 1
fi

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# After common.sh: ~/.atst itself is made as before. The picture shows the account.
umask 077

if ! command -v vncsnapshot >/dev/null 2>&1; then
  echo "[error] vncsnapshot not found. please install vncsnapshot package." 1>&2
  exit 2
fi

if [ ! -r "$HOME/.vnc/passwd" ]; then
  echo "[error] the VNC password file (~/.vnc/passwd) is not readable. nothing is taken." 1>&2
  exit 2
fi

if [ "$snap_line" = 1 ] && ! atst_has_imgbb_key; then
  echo "[error] ImgBB API key is not set (run setup_imgbb.sh). nothing is sent." 1>&2
  exit 2
fi

if [ -z "$ATST_CONFIG_DIR" ]; then
  echo "[error] ATST_CONFIG_DIR is empty. nothing is taken." 1>&2
  exit 2
fi
snap_dir="$ATST_CONFIG_DIR/snap"
# A symlink would carry the writing and the removal somewhere else (P1).
if [ -L "$snap_dir" ]; then
  echo "[error] ~/.atst/snap is a symbolic link. nothing is taken." 1>&2
  exit 2
fi
if [ ! -d "$snap_dir" ] && ! mkdir -p -- "$snap_dir" 2>/dev/null; then
  echo "[error] cannot create ~/.atst/snap. nothing is taken." 1>&2
  exit 2
fi

snap_file="$snap_dir/$(date +%Y%m%d-%H%M%S).jpg"
timeout 30 vncsnapshot -quiet -passwd "$HOME/.vnc/passwd" -quality 75 -nocursor :1 "$snap_file" < /dev/null > /dev/null 2>&1
snap_rc=$?
if [ "$snap_rc" -ne 0 ] || [ ! -s "$snap_file" ]; then
  rm -f -- "${snap_dir:?}/${snap_file##*/}"
  echo "[error] vncsnapshot failed (exit $snap_rc). is the VNC server (:1) running?" 1>&2
  exit 2
fi
chmod 600 -- "$snap_file" 2>/dev/null

# Old pictures: names hold the time, so the name order is the time order (fixed-length digits).
snap_keep=${ATST_SNAP_KEEP:-10}
if [[ "$snap_keep" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$snap_keep))" -ge 1 ] && [ "$((10#$snap_keep))" -le 1000 ]; then
  snap_keep=$((10#$snap_keep))
else
  snap_keep=10
fi
snap_old=()
for snap_f in "$snap_dir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].jpg; do
  # An unmatched glob stays as the pattern and fails -f. The picture just taken is never removed.
  if [ -f "$snap_f" ] && [ ! -L "$snap_f" ] && [ "$snap_f" != "$snap_file" ]; then
    snap_old+=("$snap_f")
  fi
done
snap_i=0
while [ "$((${#snap_old[@]} - snap_i))" -gt "$((snap_keep - 1))" ]; do
  rm -f -- "${snap_dir:?}/${snap_old[snap_i]##*/}"
  snap_i=$((snap_i + 1))
done

printf '%s\n' "$snap_file"

if [ "$snap_line" = 1 ]; then
  echo "[notice] 口座番号・残高が写る画像を ImgBB (URL を知っていれば誰でも見られる。ATST_IMGBB_EXPIRATION 秒で消える) に置いて LINE に送ります" 1>&2
  # stdout stays the path only.
  if ! printf '%s\n' "デスクトップ画像($(date +"%Y/%m/%d %H:%M:%S"))" | atst_send_to_line "$snap_file" 1>&2; then
    echo "[error] failed to send to LINE (see ~/.atst/line_error.log). the picture is kept." 1>&2
    exit 2
  fi
fi

exit 0
