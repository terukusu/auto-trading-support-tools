#!/bin/bash
#
# Downloads atst and runs install_required_for_mt.sh (the gist "init_atst.sh" is this same file).
#
# By default it fetches the GitHub archive zip of the release tag pinned below, checks it against the
# pinned sha256, and only on a match extracts it into ./auto-trading-support-tools-master/ (the same
# directory name as before, so existing crontab lines keep working) and runs install_required_for_mt.sh
# from there. "--channel master" fetches the latest master instead, without any integrity check.
#
# The two lines below are the only ones scripts/release.sh rewrites (keep them exactly in this form).
# The version and the sha256 cannot be changed by arguments or environment variables on purpose.
# A tag vX.Y.Z contains the init_atst.sh of the release before it; the gist is always updated from
# scripts/init_atst.sh on master (see docs/RELEASE.md).
ATST_VERSION=v1.5.0
ATST_ZIP_SHA256=e5196f103d74da542f23376f46eae6a6e8ff48aa4a20d402de8a84ab05152226

ATST_REPO_URL=https://github.com/terukusu/auto-trading-support-tools
ATST_DEST_NAME=auto-trading-support-tools-master
ATST_CURL_MAX_TIME=300

usage() {
  echo "Usage: init_atst.sh [--channel tag|master]"
  echo "  --channel tag     (default) download release ${ATST_VERSION}, verify its sha256, then install"
  echo "  --channel master  download the latest master without any integrity check, then install"
  echo "Extracts into ./${ATST_DEST_NAME}/ and runs install_required_for_mt.sh from there."
}

usage_error() {
  echo "[error] $1" >&2
  usage >&2
  exit 2
}

die() {
  echo "[error] $1" >&2
  exit 1
}

cleanup() {
  [ -n "${WORK:-}" ] && rm -rf "${WORK:?}"
}

# Installs only the missing commands among curl / unzip / sha256sum (apt-get, never apt: P8).
ensure_deps() {
  local missing=() pkgs=() SUDO=""

  command -v curl >/dev/null 2>&1 || { missing+=(curl); pkgs+=(curl); }
  command -v unzip >/dev/null 2>&1 || { missing+=(unzip); pkgs+=(unzip); }
  command -v sha256sum >/dev/null 2>&1 || { missing+=(sha256sum); pkgs+=(coreutils); }
  [ "${#missing[@]}" -eq 0 ] && return 0

  echo "[info] installing missing commands: ${missing[*]}"
  if [ "$(id -u)" != 0 ]; then
    command -v sudo >/dev/null 2>&1 \
      || die "missing commands: ${missing[*]}. Run as root, or install them (apt-get install -y ${pkgs[*]}) and re-run."
    SUDO=sudo
  fi
  # $SUDO is empty for root and must then expand to nothing.
  # shellcheck disable=SC2086 # intentional word splitting of $SUDO (empty or one word)
  $SUDO apt-get update < /dev/null || die "apt-get update failed"
  # shellcheck disable=SC2086 # intentional word splitting of $SUDO (empty or one word)
  $SUDO apt-get install -y "${pkgs[@]}" < /dev/null || die "apt-get install -y ${pkgs[*]} failed"

  hash -r
  command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 \
    || die "still missing after apt-get install: ${missing[*]}"
}

# Rejects archives that could write outside the extraction directory or are not shaped like a GitHub
# archive (exactly one top directory, no symbolic links). Prints the top directory name.
inspect_zip() {
  local zip="$1" names name tops

  names=$(unzip -Z1 "$zip" 2>/dev/null) && [ -n "$names" ] || die "cannot list the archive"
  while IFS= read -r name; do
    if [ -z "$name" ] || [[ "$name" == /* ]] || [[ "$name" =~ (^|/)\.\.(/|$) ]]; then
      die "unsafe path in archive: ${name}"
    fi
  done <<< "$names"

  tops=$(printf '%s\n' "$names" | cut -d/ -f1 | sort -u)
  if [ "$(printf '%s\n' "$tops" | wc -l)" -ne 1 ] || [ -z "$tops" ] || [ "$tops" = "." ] || [ "$tops" = ".." ]; then
    die "the archive must have exactly one top directory"
  fi

  if unzip -Z "$zip" 2>/dev/null | grep -q '^l'; then
    die "symbolic link in archive"
  fi
  printf '%s\n' "$tops"
}

main() {
  local channel=tag url label actual top DEST

  set -u

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --channel)
        [ "$#" -ge 2 ] || usage_error "--channel needs a value (tag or master)"
        channel=$2
        shift 2
        ;;
      --channel=*) channel=${1#--channel=}; shift ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
  case "$channel" in
    tag|master) ;;
    *) usage_error "unknown channel: ${channel} (tag or master)" ;;
  esac

  if [ "$channel" = tag ]; then
    # Not released yet: stop before downloading anything.
    [[ "$ATST_ZIP_SHA256" =~ ^0+$ ]] \
      && die "no release is pinned yet (ATST_ZIP_SHA256 is a placeholder). Use --channel master, or wait for the first release."
    [[ "$ATST_ZIP_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "ATST_ZIP_SHA256 is not 64 lowercase hex digits"
    [[ "$ATST_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ATST_VERSION is not vX.Y.Z: ${ATST_VERSION}"
    url="${ATST_REPO_URL}/archive/refs/tags/${ATST_VERSION}.zip"
    label="${ATST_VERSION} (sha256 ${ATST_ZIP_SHA256})"
  else
    url="${ATST_REPO_URL}/archive/master.zip"
    label="master (not verified)"
  fi

  ensure_deps

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/atst-init.XXXXXX") || die "cannot create a temporary directory"
  trap cleanup EXIT

  # Never write through a symbolic link or over a file in place of the install directory.
  DEST="$PWD/$ATST_DEST_NAME"
  if [ -L "$DEST" ] || { [ -e "$DEST" ] && [ ! -d "$DEST" ]; }; then
    die "./${ATST_DEST_NAME} exists but is not a plain directory"
  fi

  if [ "$channel" = master ]; then
    echo "[warn] --channel master: downloading the latest master without any integrity check" >&2
  fi
  if ! curl -fsSL --proto '=https' --max-time "$ATST_CURL_MAX_TIME" --retry 2 -o "$WORK/archive.zip" "$url" < /dev/null \
    || [ ! -s "$WORK/archive.zip" ]; then
    die "download failed: ${url}"
  fi

  # Nothing is extracted until the archive matches the pinned sha256.
  if [ "$channel" = tag ]; then
    if ! printf '%s  %s\n' "$ATST_ZIP_SHA256" "$WORK/archive.zip" | sha256sum -c --status - ; then
      actual=$(sha256sum "$WORK/archive.zip" | cut -d' ' -f1)
      echo "[error] sha256 mismatch for ${ATST_VERSION}: expected ${ATST_ZIP_SHA256}, got ${actual}. Not extracting." >&2
      echo "        See the recovery steps in docs/RELEASE.md of the repository, or report it as an Issue." >&2
      exit 1
    fi
  fi

  top=$(inspect_zip "$WORK/archive.zip") || exit 1
  unzip -q -o "$WORK/archive.zip" -d "$WORK/x" < /dev/null || die "cannot extract the archive"
  [ -f "$WORK/x/$top/install_required_for_mt.sh" ] && [ ! -L "$WORK/x/$top/install_required_for_mt.sh" ] \
    || die "install_required_for_mt.sh is not in the archive"

  # Overwrite only; files already in the install directory that are not in the archive stay.
  mkdir -p "$DEST" || die "cannot create ./${ATST_DEST_NAME}"
  cp -a "$WORK/x/$top/." "$DEST/" || die "cannot copy into ./${ATST_DEST_NAME}"

  echo "[info] extracted ${label} into ./${ATST_DEST_NAME}"
  cleanup
  trap - EXIT
  # Through bash: works without the exec bit; its exit code becomes ours.
  exec bash "$DEST/install_required_for_mt.sh"
}

# Everything runs from here, so a truncated download (or curl | bash) cannot run half of the script.
main "$@"
