#!/usr/bin/env bats
# scripts/release.sh (#138): preconditions change nothing when they fail, --dry-run changes nothing,
# the real run creates an annotated tag, sends only the tag to origin and rewrites the two pinned lines
# of scripts/init_atst.sh with the sha256 of the archive; --refresh-sha rewrites them for an existing
# tag. Everything runs in a sandbox: work/ is a fresh git repository holding a copy of scripts/, origin
# is a bare repository in the sandbox, and curl is the stub returning a dummy zip. The copy in work/ is
# what runs, so the script only ever acts on the sandbox repository (it uses the repository it is in).

load test_helper

setup() {
  atst_test_setup_sandbox
  S=$ATST_TEST_SANDBOX
  export TMPDIR="$S/tmp" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  mkdir -p "$TMPDIR" "$S/dl" "$S/elsewhere"
  REAL_TAGS=$(git -C "$BATS_TEST_DIRNAME/.." tag -l | wc -l)
  git init -q --bare "$S/origin.git"
  git init -q "$S/work"
  git -C "$S/work" symbolic-ref HEAD refs/heads/master
  git -C "$S/work" config user.name "atst test"
  git -C "$S/work" config user.email test@example.invalid
  mkdir "$S/work/scripts"
  cp "$BATS_TEST_DIRNAME"/../scripts/*.sh "$S/work/scripts/"
  printf 'readme\n' > "$S/work/README.md"
  git -C "$S/work" add -A
  git -C "$S/work" commit -qm "initial"
  git -C "$S/work" tag -a v1.0.0 -m "atst v1.0.0"
  printf 'more\n' >> "$S/work/README.md"
  git -C "$S/work" commit -qam "second change after v1.0.0"
  git -C "$S/work" remote add origin "$S/origin.git"
  git -C "$S/work" push -q origin master refs/tags/v1.0.0
  cp "$S/work/scripts/init_atst.sh" "$S/init.orig"
  atst_test_make_dummy_zip "$S/dl/rel.zip" auto-trading-support-tools-9.9.9
  REL_SHA=$(sha256sum "$S/dl/rel.zip" | cut -d' ' -f1)
  export ATST_TEST_CURL_FILE="$S/dl/rel.zip"
  R="$S/work/scripts/release.sh"
  # The repository the copy acts on is the sandbox one.
  case "$(git -C "$S/work" rev-parse --show-toplevel)" in
    "$S"/*) ;;
    *) return 1 ;;
  esac
}

teardown() {
  atst_test_teardown_sandbox
}

# rl_exec <args>...: runs the sandbox copy from a directory outside any repository.
rl_exec() {
  run bash -c 'cd "$1" && shift && exec bash "$@"' _ "$S/elsewhere" "$R" "$@"
}

# rl_stdout <args>... / rl_stderr <args>...: the same, keeping only stdout / stderr in $output.
rl_stdout() {
  run bash -c 'cd "$1" && shift && bash "$@" 2>/dev/null' _ "$S/elsewhere" "$R" "$@"
}

rl_stderr() {
  run bash -c 'cd "$1" && shift && bash "$@" 2>&1 >/dev/null' _ "$S/elsewhere" "$R" "$@"
}

tags_work() {
  git -C "$S/work" tag -l | wc -l
}

tags_origin() {
  git -C "$S/origin.git" tag -l | wc -l
}

no_curl() {
  [ ! -s "$ATST_TEST_CURL_LOG" ]
}

init_unchanged() {
  cmp "$S/init.orig" "$S/work/scripts/init_atst.sh"
}

real_repo_untouched() {
  [ "$(git -C "$BATS_TEST_DIRNAME/.." tag -l | wc -l)" -eq "$REAL_TAGS" ]
}

# leak_free: $output (sandbox paths replaced) has no home path, IPv4 address or token-like text.
leak_free() {
  local o=${output//"$S"/SANDBOX}
  [ "$(printf '%s\n' "$o" | grep -cE '/home/|[0-9]{1,3}(\.[0-9]{1,3}){3}|Bearer|\.line_token')" -eq 0 ]
}

@test "RL-01 RL-18: --dry-run prints the plan and changes nothing" {
  local head0 short
  head0=$(git -C "$S/origin.git" rev-parse master)
  short=$(git -C "$S/work" rev-parse --short HEAD)
  rl_exec v9.9.9 --dry-run
  [ "$status" -eq 0 ]
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
  init_unchanged
  no_curl
  [ "$(git -C "$S/origin.git" rev-parse master)" = "$head0" ]
  [[ "$output" == *v9.9.9* ]]
  [[ "$output" == *"archive/refs/tags/v9.9.9.zip"* ]]
  [[ "$output" == *"scripts/init_atst.sh"* ]]
  [[ "$output" == *v1.0.0* ]]
  [[ "$output" == *"$short"* ]]
  [[ "$output" == *"second change after v1.0.0"* ]]
  leak_free
  real_repo_untouched
}

@test "RL-02: the real run tags both repositories, pins the archive sha256 and prints the note draft" {
  rl_stdout v9.9.9
  [ "$status" -eq 0 ]
  [ "$(git -C "$S/work" tag -l v9.9.9)" = v9.9.9 ]
  [ "$(git -C "$S/origin.git" tag -l v9.9.9)" = v9.9.9 ]
  [ "$(git -C "$S/work" cat-file -t v9.9.9)" = tag ]
  [ "$(git -C "$S/work" rev-parse 'v9.9.9^{commit}')" = "$(git -C "$S/work" rev-parse HEAD)" ]
  [ "$(git -C "$S/work" tag -l --format='%(contents:subject)' v9.9.9)" = "atst v9.9.9" ]
  [ "$(grep -cx 'ATST_VERSION=v9.9.9' "$S/work/scripts/init_atst.sh")" -eq 1 ]
  [ "$(grep -cx "ATST_ZIP_SHA256=$REL_SHA" "$S/work/scripts/init_atst.sh")" -eq 1 ]
  [[ "$output" == *"## atst v9.9.9"* ]]
  [[ "$output" == *"- sha256: $REL_SHA"* ]]
  [[ "$output" == *"### Changes since v1.0.0"* ]]
  [[ "$output" == *"second change after v1.0.0"* ]]
  [[ "$output" == *"gh gist edit"* ]]
  [ "$(grep -cF 'archive/refs/tags/v9.9.9.zip' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  real_repo_untouched
}

@test "RL-03: a version that is not vX.Y.Z is refused" {
  local v
  for v in 1.0 v1.0 v1.0.0.0 v1.0.0-rc1; do
    rl_exec "$v"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[error]"* ]]
  done
  rl_stderr v1.0
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
  no_curl
}

@test "RL-04: changes to tracked files (unstaged or staged) are refused" {
  echo x >> "$S/work/README.md"
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  git -C "$S/work" add README.md
  rl_stderr v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
  no_curl
  [ "$(tail -n 1 "$S/work/README.md")" = x ]
}

@test "RL-05: an existing tag (local and origin, origin only, local only) is refused" {
  rl_exec v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]

  git -C "$S/work" tag -a v2.0.0 -m x
  git -C "$S/work" push -q origin refs/tags/v2.0.0
  git -C "$S/work" tag -d v2.0.0 > /dev/null
  rl_exec v2.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 2 ]

  git -C "$S/work" tag -a v3.0.0 -m x
  rl_exec v3.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 2 ]
  [ "$(tags_origin)" -eq 2 ]
  no_curl
}

@test "RL-06: a version older than the latest tag is refused" {
  rl_exec v0.9.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
  no_curl
}

@test "RL-07: HEAD that is not origin/master is refused" {
  git -C "$S/work" commit -q --allow-empty -m local-only
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
  no_curl
}

@test "RL-08: a refused tag push removes the local tag and rewrites nothing" {
  printf '#!/bin/sh\nexit 1\n' > "$S/origin.git/hooks/pre-receive"
  chmod 755 "$S/origin.git/hooks/pre-receive"
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ -z "$(git -C "$S/work" tag -l v9.9.9)" ]
  [ -z "$(git -C "$S/origin.git" tag -l v9.9.9)" ]
  init_unchanged
  no_curl
}

@test "RL-09: --refresh-sha rewrites the pinned lines for an existing tag without tagging" {
  rl_stdout --refresh-sha v1.0.0
  [ "$status" -eq 0 ]
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
  [ "$(grep -cx 'ATST_VERSION=v1.0.0' "$S/work/scripts/init_atst.sh")" -eq 1 ]
  [ "$(grep -cx "ATST_ZIP_SHA256=$REL_SHA" "$S/work/scripts/init_atst.sh")" -eq 1 ]
  [ "$(grep -cF 'archive/refs/tags/v1.0.0.zip' "$ATST_TEST_CURL_LOG")" -eq 1 ]
  [[ "$output" == *"gh gist edit"* ]]
  [[ "$output" != *"### Changes since"* ]]
  # The option may also come after the version.
  git -C "$S/work" checkout -q -- scripts/init_atst.sh
  rl_exec v1.0.0 --refresh-sha
  [ "$status" -eq 0 ]
  [ "$(grep -cx "ATST_ZIP_SHA256=$REL_SHA" "$S/work/scripts/init_atst.sh")" -eq 1 ]
  [ "$(tags_work)" -eq 1 ]
  real_repo_untouched
}

@test "RL-10: a failed download keeps the sent tag, points to --refresh-sha, and that recovers" {
  export ATST_TEST_CURL_EXIT=22
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [[ "$output" == *"--refresh-sha v9.9.9"* ]]
  init_unchanged
  [ "$(git -C "$S/work" tag -l v9.9.9)" = v9.9.9 ]
  [ "$(git -C "$S/origin.git" tag -l v9.9.9)" = v9.9.9 ]
  unset ATST_TEST_CURL_EXIT
  rl_exec --refresh-sha v9.9.9
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'ATST_VERSION=v9.9.9' "$S/work/scripts/init_atst.sh")" -eq 1 ]
  [ "$(grep -cx "ATST_ZIP_SHA256=$REL_SHA" "$S/work/scripts/init_atst.sh")" -eq 1 ]
}

@test "RL-11: bad arguments exit 2 with the usage on stderr; -h prints it on stdout" {
  rl_stderr
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qi usage
  rl_stderr v9.9.9 v9.9.10
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qi usage
  rl_stderr --bogus v9.9.9
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qi usage
  rl_stderr --dry-run
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qi usage
  rl_stdout -h
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qi usage
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
  no_curl
}

@test "RL-12: only the two pinned lines change" {
  rl_exec v9.9.9
  [ "$status" -eq 0 ]
  run diff "$S/init.orig" "$S/work/scripts/init_atst.sh"
  [ "$(printf '%s\n' "$output" | grep -c '^<')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c '^>')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -E '^[<>]' | grep -cvE '^[<>] ATST_(VERSION|ZIP_SHA256)=')" -eq 0 ]
}

@test "RL-13 RL-18: no commit and no branch is sent; the output leaks nothing" {
  local h om
  h=$(git -C "$S/work" rev-parse HEAD)
  om=$(git -C "$S/origin.git" rev-parse master)
  rl_exec v9.9.9
  [ "$status" -eq 0 ]
  leak_free
  [ "$(git -C "$S/work" rev-parse HEAD)" = "$h" ]
  [ "$(git -C "$S/origin.git" rev-parse master)" = "$om" ]
  [ "$(git -C "$S/work" status --porcelain)" = " M scripts/init_atst.sh" ]
  [ "$(git -C "$S/origin.git" for-each-ref refs/heads | wc -l)" -eq 1 ]
  real_repo_untouched
}

@test "RL-14: untracked files do not count as changes" {
  echo u > "$S/work/untracked.txt"
  rl_exec v9.9.9 --dry-run
  [ "$status" -eq 0 ]
}

@test "RL-15: --refresh-sha refuses a tag that is not on origin" {
  rl_exec --refresh-sha v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  git -C "$S/work" tag -a v9.9.9 -m x
  rl_exec --refresh-sha v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  no_curl
  init_unchanged
}

@test "RL-16: an init_atst.sh that cannot be rewritten is detected before tagging" {
  local f="$S/work/scripts/init_atst.sh"
  sed -i '/^ATST_VERSION=/p' "$f"
  git -C "$S/work" commit -qam dup-version
  git -C "$S/work" push -q origin master
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]

  cp "$S/init.orig" "$f"
  sed -i '/^ATST_ZIP_SHA256=/d' "$f"
  git -C "$S/work" commit -qam no-sha
  git -C "$S/work" push -q origin master
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]

  git -C "$S/work" rm -q scripts/init_atst.sh
  git -C "$S/work" commit -qm no-init
  git -C "$S/work" push -q origin master
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]

  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
  no_curl
}

@test "RL-17: running the same version again stops" {
  local n
  rl_exec v9.9.9
  [ "$status" -eq 0 ]
  git -C "$S/work" commit -qam bump
  git -C "$S/work" push -q origin master
  n=$(wc -l < "$ATST_TEST_CURL_LOG")
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 2 ]
  [ "$(tags_origin)" -eq 2 ]
  [ "$(wc -l < "$ATST_TEST_CURL_LOG")" -eq "$n" ]
}

@test "RL-19: an unreachable origin is not taken as 'no such tag'" {
  git -C "$S/work" remote set-url origin "$S/nonexistent.git"
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [ "$(tags_work)" -eq 1 ]
  no_curl
}

@test "RL-20: an empty download is a failure and no sha is written" {
  : > "$S/dl/empty.zip"
  export ATST_TEST_CURL_FILE="$S/dl/empty.zip"
  rl_exec v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  [[ "$output" == *"--refresh-sha"* ]]
  init_unchanged
}

@test "RL-21: two-part tags take part in the version comparison" {
  git -C "$S/work" tag -a v1.4 -m x
  git -C "$S/work" push -q origin refs/tags/v1.4
  rl_exec v1.5.0 --dry-run
  [ "$status" -eq 0 ]
  rl_exec v1.3.0 --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
}

@test "RL-22: --refresh-sha with --dry-run changes nothing" {
  rl_exec --refresh-sha v1.0.0 --dry-run
  [ "$status" -eq 0 ]
  no_curl
  init_unchanged
  [ "$(tags_work)" -eq 1 ]
  [ "$(tags_origin)" -eq 1 ]
}

@test "RL-23: --refresh-sha also needs a clean working tree" {
  echo x >> "$S/work/README.md"
  rl_exec --refresh-sha v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"[error]"* ]]
  init_unchanged
  no_curl
}

@test "RL-24: the repository is the one the script is in, not the current directory" {
  rl_exec v9.9.9 --dry-run
  [ "$status" -eq 0 ]
  git init -q "$S/other"
  run bash -c 'cd "$1" && bash "$2" v9.9.9 --dry-run' _ "$S/other" "$R"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$S/other" tag -l)" ]
  [ -z "$(git -C "$S/other" status --porcelain)" ]
}

@test "RL-25: the archive is fetched over https only, with a timeout and retries" {
  rl_exec v9.9.9
  [ "$status" -eq 0 ]
  local line
  line=$(grep -F 'archive/refs/tags/v9.9.9.zip' "$ATST_TEST_CURL_LOG")
  [[ "$line" == *"--proto =https"* ]]
  [[ "$line" == *"--max-time 120"* ]]
  [[ "$line" == *"--retry 5"* ]]
  [[ "$line" == *"-o "* ]]
  [[ "$line" == *"https://github.com/terukusu/auto-trading-support-tools/archive/refs/tags/v9.9.9.zip"* ]]
}
