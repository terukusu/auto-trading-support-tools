#!/usr/bin/env bats
# scripts/init_atst.sh (#138): the tag channel extracts and runs install_required_for_mt.sh only when
# the archive matches the pinned sha256; --channel master fetches master.zip with a [warn]. Also the
# curl stub's ATST_TEST_CURL_FILE (CS-*) and atst_test_make_dummy_zip (HL-*).
# init_atst.sh is copied into the sandbox and its two pinned lines are rewritten with sed there; curl is
# the stub (it copies a dummy zip made in the sandbox), sudo / apt-get are recording stubs, and the
# script runs with the sandbox run/ as its working directory. Nothing reaches the network.

load test_helper

setup() {
  atst_test_setup_sandbox
  S=$ATST_TEST_SANDBOX
  export TMPDIR="$S/tmp"
  mkdir -p "$TMPDIR" "$S/run" "$S/dl" "$S/bin"
  PATH="$S/bin:$PATH"
  export PATH
  hash -r
  atst_test_stub_script "$S/bin" sudo record
  atst_test_stub_script "$S/bin" apt-get record
  atst_test_make_dummy_zip "$S/dl/good.zip" auto-trading-support-tools-9.9.9
  ZIP_SHA=$(sha256sum "$S/dl/good.zip" | cut -d' ' -f1)
  export ATST_TEST_CURL_FILE="$S/dl/good.zip"
  DEST="$S/run/auto-trading-support-tools-master"
  BAD_SHA=$(printf 'f%.0s' {1..64})
}

teardown() {
  atst_test_teardown_sandbox
}

# ia_prepare <sha> [<version>]: the sandbox copy of init_atst.sh pinned to <version> (v9.9.9) / <sha>.
ia_prepare() {
  cp "$BATS_TEST_DIRNAME/../scripts/init_atst.sh" "$S/init_atst.sh"
  sed -i -e "s/^ATST_VERSION=.*/ATST_VERSION=${2:-v9.9.9}/" -e "s/^ATST_ZIP_SHA256=.*/ATST_ZIP_SHA256=$1/" \
    "$S/init_atst.sh"
  [ "$(grep -cx "ATST_ZIP_SHA256=$1" "$S/init_atst.sh")" -eq 1 ]
}

# ia_exec <args>...: runs the sandbox copy with the working directory $S/run.
ia_exec() {
  run bash -c 'cd "$1" && shift && exec bash "$@"' _ "$S/run" "$S/init_atst.sh" "$@"
}

# count <fixed string> <file>: matching lines (0 without the file).
count() {
  if [ -e "$2" ]; then
    grep -cF -- "$1" "$2" || true
  else
    echo 0
  fi
}

no_curl() {
  [ ! -s "$ATST_TEST_CURL_LOG" ]
}

no_apt() {
  [ ! -e "$S/calls.log" ] || [ "$(grep -cE '^(sudo|apt-get) ' "$S/calls.log")" -eq 0 ]
}

tmp_empty() {
  [ -z "$(ls -A "$TMPDIR")" ]
}

# leak_free: $output (sandbox paths replaced) has no home path, IPv4 address or token-like text.
leak_free() {
  local o=${output//"$S"/SANDBOX}
  [ "$(printf '%s\n' "$o" | grep -cE '/home/|[0-9]{1,3}(\.[0-9]{1,3}){3}|Bearer|\.line_token')" -eq 0 ]
}

# ia_min_path <uid>: $PMIN without unzip / sha256sum / the real sudo / apt-get, and an id that prints
# <uid> for -u (sudo / apt-get stay the recording stubs in $S/bin).
ia_min_path() {
  local f n
  mkdir -p "$S/min"
  for f in /usr/bin/* /bin/*; do
    n=${f##*/}
    case "$n" in
      unzip|sha256sum|sudo|apt-get|id) continue ;;
    esac
    [ -e "$S/min/$n" ] || ln -s "$f" "$S/min/$n"
  done
  printf '#!/bin/bash\n[ "${1:-}" = -u ] && { echo %s; exit 0; }\nexit 1\n' "$1" > "$S/bin/id"
  chmod 755 "$S/bin/id"
  PMIN="$S/bin:$BATS_TEST_DIRNAME/stubs:$S/min"
}

ia_exec_min() {
  run env PATH="$PMIN" bash -c 'cd "$1" && bash "$2"' _ "$S/run" "$S/init_atst.sh"
}

@test "IA-01: default channel fetches the pinned tag zip once with --max-time and https only" {
  ia_prepare "$ZIP_SHA"
  ia_exec
  [ "$status" -eq 0 ]
  [ "$(count 'archive/refs/tags/v9.9.9.zip' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(count 'master.zip' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  grep -qF -- '--max-time 300' "$ATST_TEST_CURL_LOG"
  grep -qF -- '--proto =https' "$ATST_TEST_CURL_LOG"
  grep -qF -- '-o ' "$ATST_TEST_CURL_LOG"
  [ "$(wc -l < "$ATST_TEST_CURL_LOG")" -eq 1 ]
}

@test "IA-02: --channel master fetches master.zip with a [warn] on stderr and no sha check" {
  ia_prepare "$BAD_SHA"
  ia_exec --channel master
  [ "$status" -eq 0 ]
  [ "$(count 'archive/master.zip' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(count 'refs/tags/' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [[ "$output" == *"[warn]"* ]]
  [[ "$output" == *integrity* ]]
  [ -e "$S/marker" ]
  # The [warn] is on stderr.
  run bash -c 'cd "$1" && bash "$2" --channel master 2>&1 >/dev/null' _ "$S/run" "$S/init_atst.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn]"* ]]
}

@test "IA-03 IA-29: sha mismatch stops before extracting, removes the archive and leaks nothing" {
  ia_prepare "$BAD_SHA"
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [[ "$output" == *"sha256 mismatch"* ]]
  [[ "$output" == *"expected $BAD_SHA"* ]]
  [[ "$output" == *"got $ZIP_SHA"* ]]
  [[ "$output" == *"Not extracting"* ]]
  [ ! -e "$DEST" ]
  [ ! -e "$S/marker" ]
  tmp_empty
  leak_free
  # [error] is on stderr.
  run bash -c 'cd "$1" && bash "$2" 2>&1 >/dev/null' _ "$S/run" "$S/init_atst.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
}

@test "IA-04 IA-29: sha match extracts into -master, keeps other files, runs the installer without apt-get" {
  mkdir -p "$DEST"
  echo keep > "$DEST/keep.txt"
  echo old > "$DEST/README.md"
  ia_prepare "$ZIP_SHA"
  ia_exec
  [ "$status" -eq 0 ]
  [ -f "$DEST/install_required_for_mt.sh" ]
  [ -e "$S/marker" ]
  [ "$(cat "$DEST/keep.txt")" = keep ]
  [ "$(grep -cx old "$DEST/README.md")" -eq 0 ]
  [ ! -e "$S/run/auto-trading-support-tools-9.9.9" ]
  [ "$(ls "$S/run")" = auto-trading-support-tools-master ]
  no_apt
  tmp_empty
  printf '%s\n' "$output" | grep 'v9.9.9' | grep -qF "$ZIP_SHA"
  [ "$(wc -l < "$S/install.log")" -eq 1 ]
  leak_free
}

@test "IA-05: a failed download (curl exit 22) extracts nothing" {
  ia_prepare "$ZIP_SHA"
  export ATST_TEST_CURL_EXIT=22
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [[ "$output" == *"download failed"* ]]
  [ ! -e "$DEST" ]
  [ ! -e "$S/marker" ]
  tmp_empty
  run bash -c 'cd "$1" && bash "$2" 2>&1 >/dev/null' _ "$S/run" "$S/init_atst.sh"
  [[ "$output" == *"[error]"* ]]
}

@test "IA-06: the placeholder pin stops before downloading" {
  # The repository pins a release since v1.5.0; the test makes the placeholder form itself.
  sed -e 's/^ATST_VERSION=.*/ATST_VERSION=v0.0.0/' \
    -e 's/^ATST_ZIP_SHA256=.*/ATST_ZIP_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$BATS_TEST_DIRNAME/../scripts/init_atst.sh" > "$S/init_atst.sh"
  [ "$(grep -c '^ATST_ZIP_SHA256=0\{64\}$' "$S/init_atst.sh")" -eq 1 ]
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [[ "$output" == *"no release is pinned yet"* ]]
  [[ "$output" == *"--channel master"* ]]
  no_curl
  no_apt
  [ ! -e "$DEST" ]
}

@test "IA-07: a bad argument exits 2 with [error] and usage on stderr, before downloading" {
  ia_prepare "$ZIP_SHA"
  for args in "--channel foo" "--bogus" "--channel"; do
    # shellcheck disable=SC2086 # split the test arguments on purpose
    ia_exec $args
    [ "$status" -eq 2 ]
    [[ "$output" == *"[error]"* ]]
    printf '%s\n' "$output" | grep -qi usage
  done
  run bash -c 'cd "$1" && bash "$2" --channel foo 2>&1 >/dev/null' _ "$S/run" "$S/init_atst.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"[error]"* ]]
  printf '%s\n' "$output" | grep -qi usage
  no_curl
  [ ! -e "$DEST" ]
}

@test "IA-08: an archive with two top directories is rejected" {
  mkdir -p "$S/w/a" "$S/w/b"
  printf '#!/bin/bash\ntouch "$ATST_TEST_SANDBOX/marker"\n' > "$S/w/a/install_required_for_mt.sh"
  cp "$S/w/a/install_required_for_mt.sh" "$S/w/b/"
  (cd "$S/w" && zip -qr "$S/dl/two.zip" a b)
  export ATST_TEST_CURL_FILE="$S/dl/two.zip"
  ia_prepare "$(sha256sum "$S/dl/two.zip" | cut -d' ' -f1)"
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ ! -e "$DEST" ]
  [ ! -e "$S/marker" ]
  tmp_empty
}

@test "IA-09: entries with .. or an absolute path are rejected before extracting" {
  command -v python3 > /dev/null || skip "python3 not found"
  local name zip
  for name in 'auto-trading-support-tools-9.9.9/../../evil' '/absevil'; do
    zip="$S/dl/evil.$RANDOM.zip"
    python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("auto-trading-support-tools-9.9.9/install_required_for_mt.sh","#!/bin/bash\ntouch \"$ATST_TEST_SANDBOX/marker\"\n"); z.writestr(sys.argv[2],"x"); z.close()' \
      "$zip" "$name"
    export ATST_TEST_CURL_FILE="$zip"
    ia_prepare "$(sha256sum "$zip" | cut -d' ' -f1)"
    ia_exec
    [ "$status" -eq 1 ]
    [[ "$output" == *"unsafe path"* ]]
    [ ! -e "$S/evil" ]
    [ ! -e "$S/run/evil" ]
    [ ! -e "$S/absevil" ]
    [ ! -e "$DEST" ]
    [ ! -e "$S/marker" ]
    tmp_empty
  done
}

@test "IA-10: an install directory that is a symbolic link is refused before downloading" {
  mkdir "$S/linktarget"
  ln -s "$S/linktarget" "$DEST"
  ia_prepare "$ZIP_SHA"
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ -z "$(ls -A "$S/linktarget")" ]
  [ -L "$DEST" ]
  no_curl
  [ ! -e "$S/marker" ]
}

@test "IA-11: an archive containing a symbolic link is rejected" {
  local top="$S/w/auto-trading-support-tools-9.9.9"
  mkdir -p "$top" "$S/outside"
  printf '#!/bin/bash\ntouch "$ATST_TEST_SANDBOX/marker"\n' > "$top/install_required_for_mt.sh"
  ln -s "$S/outside" "$top/link"
  (cd "$S/w" && zip -qry "$S/dl/link.zip" auto-trading-support-tools-9.9.9)
  unzip -Z "$S/dl/link.zip" | grep -q '^l'
  export ATST_TEST_CURL_FILE="$S/dl/link.zip"
  ia_prepare "$(sha256sum "$S/dl/link.zip" | cut -d' ' -f1)"
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ ! -e "$DEST" ]
  [ ! -e "$S/marker" ]
}

@test "IA-12: an install directory that is a regular file is refused and left as is" {
  echo file > "$DEST"
  ia_prepare "$ZIP_SHA"
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(cat "$DEST")" = file ]
  no_curl
}

@test "IA-13: an archive without install_required_for_mt.sh is rejected" {
  mkdir -p "$S/w/top"
  echo r > "$S/w/top/README.md"
  (cd "$S/w" && zip -qr "$S/dl/noinst.zip" top)
  export ATST_TEST_CURL_FILE="$S/dl/noinst.zip"
  ia_prepare "$(sha256sum "$S/dl/noinst.zip" | cut -d' ' -f1)"
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ ! -e "$S/marker" ]
}

@test "IA-14: the installer's exit code is returned" {
  atst_test_make_dummy_zip "$S/dl/x7.zip" auto-trading-support-tools-9.9.9 \
    $'#!/bin/bash\ntouch "$ATST_TEST_SANDBOX/marker"\nexit 7'
  export ATST_TEST_CURL_FILE="$S/dl/x7.zip"
  ia_prepare "$(sha256sum "$S/dl/x7.zip" | cut -d' ' -f1)"
  ia_exec
  [ "$status" -eq 7 ]
  [ -e "$S/marker" ]
}

@test "IA-15: the installer runs through bash even without the exec bit" {
  mkdir -p "$S/w/t"
  printf '#!/bin/bash\ntouch "$ATST_TEST_SANDBOX/marker"\npwd >> "$ATST_TEST_SANDBOX/install.log"\n' \
    > "$S/w/t/install_required_for_mt.sh"
  chmod 644 "$S/w/t/install_required_for_mt.sh"
  (cd "$S/w" && zip -qr "$S/dl/noexec.zip" t)
  export ATST_TEST_CURL_FILE="$S/dl/noexec.zip"
  ia_prepare "$(sha256sum "$S/dl/noexec.zip" | cut -d' ' -f1)"
  ia_exec
  [ "$status" -eq 0 ]
  [ -e "$S/marker" ]
  [ "$(wc -l < "$S/install.log")" -eq 1 ]
}

@test "IA-16: missing commands are installed with apt-get through sudo, only the missing packages" {
  ia_prepare "$ZIP_SHA"
  ia_min_path 1000
  ia_exec_min
  grep -E '^sudo ' "$S/calls.log" | grep -qF '[apt-get] [update]'
  grep -E '^sudo ' "$S/calls.log" | grep -F '[apt-get] [install] [-y]' | grep -F '[unzip]' | grep -qF '[coreutils]'
  [ "$(grep -F '[install]' "$S/calls.log" | grep -cF '[curl]')" -eq 0 ]
  [ "$(grep -cE '^apt ' "$S/calls.log")" -eq 0 ]
  # The apt-get stub installs nothing, so the commands are still missing.
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ ! -e "$S/marker" ]
  no_curl
}

@test "IA-17: as root, apt-get is called without sudo" {
  ia_prepare "$ZIP_SHA"
  ia_min_path 0
  ia_exec_min
  grep -E '^apt-get ' "$S/calls.log" | grep -qF '[update]'
  grep -E '^apt-get ' "$S/calls.log" | grep -F '[install] [-y]' | grep -qF '[unzip]'
  [ "$(grep -cE '^sudo ' "$S/calls.log")" -eq 0 ]
  [ "$status" -eq 1 ]
}

@test "IA-18: not root and no sudo stops with [error] without apt-get or downloading" {
  ia_prepare "$ZIP_SHA"
  ia_min_path 1000
  rm "$S/bin/sudo"
  ia_exec_min
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  no_apt
  no_curl
}

@test "IA-19: a failing apt-get stops before downloading" {
  ia_prepare "$ZIP_SHA"
  ia_min_path 0
  atst_test_stub_script "$S/bin" apt-get fail
  ia_exec_min
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  grep -E '^apt-get ' "$S/calls.log" | grep -qF '[update]'
  [ "$(grep -cF '[install]' "$S/calls.log")" -eq 0 ]
  no_curl
  [ ! -e "$DEST" ]
}

@test "IA-20: -h / --help print the usage on stdout and exit 0" {
  ia_prepare "$ZIP_SHA"
  run bash -c 'bash "$1" --help 2>/dev/null' _ "$S/init_atst.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qi usage
  ia_exec -h
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qi usage
  no_curl
}

@test "IA-21: --channel=master and an explicit --channel tag are accepted" {
  ia_prepare "$ZIP_SHA"
  ia_exec --channel=master
  [ "$status" -eq 0 ]
  [ "$(count 'archive/master.zip' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [[ "$output" == *"[warn]"* ]]
  rm -f "$ATST_TEST_CURL_LOG"
  ia_exec --channel tag
  [ "$status" -eq 0 ]
  [ "$(count 'archive/refs/tags/v9.9.9.zip' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(count 'master.zip' "$ATST_TEST_CURL_LOG")" -eq 0 ]
}

@test "IA-22: environment variables cannot change the version, sha, URL or install directory" {
  ia_prepare "$ZIP_SHA"
  run env ATST_VERSION=v8.8.8 ATST_ZIP_SHA256="$(printf 'e%.0s' {1..64})" ATST_REPO_URL=https://example.invalid \
    ATST_DEST_NAME=other bash -c 'cd "$1" && bash "$2"' _ "$S/run" "$S/init_atst.sh"
  [ "$status" -eq 0 ]
  [ "$(count 'github.com/terukusu/auto-trading-support-tools/archive/refs/tags/v9.9.9.zip' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [ "$(count 'v8.8.8' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ "$(count 'example.invalid' "$ATST_TEST_CURL_LOG")" -eq 0 ]
  [ -f "$DEST/install_required_for_mt.sh" ]
  [ ! -e "$S/run/other" ]
}

@test "IA-23: a malformed pinned version or sha stops before downloading" {
  local upper
  upper=$(printf '%s' "$ZIP_SHA" | tr a-f A-F)
  ia_prepare "$ZIP_SHA" v1.0
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  ia_prepare "$upper"
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  ia_prepare abc
  ia_exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  no_curl
}

@test "IA-24: unzip is not called until the sha256 matches" {
  local real
  real=$(command -v unzip)
  printf '#!/bin/bash\necho "unzip $*" >> "%s/calls.log"\nexec %q "$@"\n' "$S" "$real" > "$S/bin/unzip"
  chmod 755 "$S/bin/unzip"
  hash -r
  ia_prepare "$BAD_SHA"
  ia_exec
  [ "$status" -eq 1 ]
  [ ! -e "$S/calls.log" ] || [ "$(grep -c '^unzip' "$S/calls.log")" -eq 0 ]
  # Control: with the right sha, unzip is called.
  ia_prepare "$ZIP_SHA"
  ia_exec
  [ "$status" -eq 0 ]
  [ "$(grep -c '^unzip' "$S/calls.log")" -ge 1 ]
}

@test "IA-25: an empty download is a failed download" {
  : > "$S/dl/empty.zip"
  export ATST_TEST_CURL_FILE="$S/dl/empty.zip"
  ia_prepare "$ZIP_SHA"
  ia_exec --channel master
  [ "$status" -eq 1 ]
  [[ "$output" == *"download failed"* ]]
  [ ! -e "$DEST" ]
}

@test "IA-26: running twice works and leaves no temporary directory behind" {
  ia_prepare "$ZIP_SHA"
  ia_exec
  [ "$status" -eq 0 ]
  ia_exec
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$S/install.log")" -eq 2 ]
  tmp_empty
  [ "$(ls "$S/run" | wc -l)" -eq 1 ]
}

@test "IA-27: a truncated copy (without the last line) does nothing" {
  ia_prepare "$ZIP_SHA"
  grep -v '^[[:space:]]*$' "$S/init_atst.sh" | sed '$d' > "$S/trunc.sh"
  run bash -c 'cd "$1" && bash "$2"' _ "$S/run" "$S/trunc.sh"
  [ "$status" -eq 0 ]
  no_curl
  [ ! -e "$DEST" ]
  tmp_empty
  [ ! -e "$S/calls.log" ]
}

@test "IA-28: running from standard input (curl | bash) works the same" {
  ia_prepare "$ZIP_SHA"
  run bash -c 'cd "$1" && bash < "$2"' _ "$S/run" "$S/init_atst.sh"
  [ "$status" -eq 0 ]
  [ -e "$S/marker" ]
  [ "$(count 'archive/refs/tags/v9.9.9.zip' "$ATST_TEST_CURL_LOG")" -eq 1 ]
}

@test "CS-02: curl stub copies ATST_TEST_CURL_FILE to -o, prints no body and logs the call" {
  export ATST_TEST_CURL_BODY=bodytext
  run "$BATS_TEST_DIRNAME/stubs/curl" -fsSL -o "$S/out" https://example.invalid/x
  [ "$status" -eq 0 ]
  cmp "$S/out" "$S/dl/good.zip"
  [ -z "$output" ]
  [ "$(wc -l < "$ATST_TEST_CURL_LOG")" -eq 1 ]
  grep -qF -- "-o $S/out" "$ATST_TEST_CURL_LOG"
}

@test "CS-03: curl stub does not copy when it exits non-zero" {
  export ATST_TEST_CURL_BODY=bodytext ATST_TEST_CURL_EXIT=22
  run "$BATS_TEST_DIRNAME/stubs/curl" -fsSL -o "$S/out" https://example.invalid/x
  [ "$status" -eq 22 ]
  [ ! -e "$S/out" ]
}

@test "CS-04: curl stub without -o prints the body as before" {
  export ATST_TEST_CURL_BODY=bodytext
  run "$BATS_TEST_DIRNAME/stubs/curl" -s https://example.invalid/x
  [ "$status" -eq 0 ]
  [ "$output" = bodytext ]
  [ ! -e "$S/out" ]
}

@test "CS-05: curl stub without ATST_TEST_CURL_LOG does nothing" {
  run env -u ATST_TEST_CURL_LOG ATST_TEST_CURL_FILE="$S/dl/good.zip" "$BATS_TEST_DIRNAME/stubs/curl" -o "$S/out" x
  [ "$status" -eq 1 ]
  [ ! -e "$S/out" ]
}

@test "CS-06: curl stub fails when the copy fails" {
  export ATST_TEST_CURL_FILE="$S/dl/nonexistent.zip"
  run "$BATS_TEST_DIRNAME/stubs/curl" -o "$S/out" x
  [ "$status" -ne 0 ]
}

@test "CS-07: curl stub still prints the -w code with ATST_TEST_CURL_FILE" {
  export ATST_TEST_CURL_BODY=bodytext ATST_TEST_CURL_HTTP_CODE=200
  run "$BATS_TEST_DIRNAME/stubs/curl" -o "$S/out" -w '%{http_code}' x
  [ "$status" -eq 0 ]
  [[ "$output" == *200 ]]
  [[ "$output" != *bodytext* ]]
  cmp "$S/out" "$S/dl/good.zip"
}

@test "HL-01: atst_test_make_dummy_zip makes one top directory with the installer and README.md" {
  run unzip -Z1 "$S/dl/good.zip"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'auto-trading-support-tools-9.9.9/install_required_for_mt.sh'
  printf '%s\n' "$output" | grep -qx 'auto-trading-support-tools-9.9.9/README.md'
  [ "$(printf '%s\n' "$output" | cut -d/ -f1 | sort -u | wc -l)" -eq 1 ]
}

@test "HL-02: the default dummy installer writes the marker and one install.log line" {
  mkdir "$S/hx"
  unzip -q "$S/dl/good.zip" -d "$S/hx"
  run bash "$S/hx/auto-trading-support-tools-9.9.9/install_required_for_mt.sh" a1
  [ "$status" -eq 0 ]
  [ -e "$S/marker" ]
  [ "$(wc -l < "$S/install.log")" -eq 1 ]
  grep -q a1 "$S/install.log"
}

@test "HL-03: atst_test_make_dummy_zip refuses a path outside the sandbox" {
  local out="$BATS_TMPDIR/atst-hl03-$$.zip"
  rm -f "$out"
  run atst_test_make_dummy_zip "$out" top
  local st=$status
  [ ! -e "$out" ] || { rm -f "$out"; false; }
  [ "$st" -eq 1 ]
}

@test "HL-04: atst_test_make_dummy_zip checks the top name and the argument count" {
  local top
  for top in .. a/b . ''; do
    run atst_test_make_dummy_zip "$S/dl/h.zip" "$top"
    [ "$status" -eq 1 ]
    [ ! -e "$S/dl/h.zip" ]
  done
  run atst_test_make_dummy_zip "$S/dl/h.zip"
  [ "$status" -eq 1 ]
  run atst_test_make_dummy_zip "$S/dl/h.zip" t body extra
  [ "$status" -eq 1 ]
  [ ! -e "$S/dl/h.zip" ]
}

@test "HL-05: atst_test_make_dummy_zip uses the given installer body" {
  atst_test_make_dummy_zip "$S/dl/b.zip" t $'#!/bin/bash\nexit 7'
  run unzip -p "$S/dl/b.zip" t/install_required_for_mt.sh
  [[ "$output" == *"exit 7"* ]]
  [[ "$output" != *marker* ]]
}

@test "HL-06: the dummy installer has the exec bit" {
  unzip -Z "$S/dl/good.zip" | grep 'install_required_for_mt.sh$' | grep -q '^-rwx'
}

@test "HL-07: atst_test_make_dummy_zip refuses when HOME is not the sandbox" {
  run bash -c 'HOME=/nonexistent-atst; . "$1"; atst_test_make_dummy_zip "$2" top' _ \
    "$BATS_TEST_DIRNAME/test_helper.bash" "$S/dl/h.zip"
  [ "$status" -eq 1 ]
  [ ! -e "$S/dl/h.zip" ]
}
