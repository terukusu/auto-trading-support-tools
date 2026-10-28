#!/bin/bash
#
# Release helper for maintainers (run on master; see docs/RELEASE.md).
#
#   scripts/release.sh vX.Y.Z [--dry-run]
#     Creates the annotated tag vX.Y.Z, sends only that tag to origin, downloads the GitHub archive
#     zip of the tag, writes its sha256 and the version into scripts/init_atst.sh (ATST_VERSION /
#     ATST_ZIP_SHA256, nothing else), and prints a release note draft and the remaining steps.
#   scripts/release.sh --refresh-sha vX.Y.Z [--dry-run]
#     For an existing tag on origin whose archive bytes changed on the GitHub side: downloads the zip
#     again and rewrites the same two lines. No tag is created or sent.
#
# It never commits, never sends a branch and never edits the gist: the rewritten init_atst.sh goes in
# through a normal PR, and the gist is updated from master afterwards.
# The sha256 must come from the archive GitHub serves after the tag is on origin: a zip made locally
# with "git archive" has different bytes (compression, timestamps, export attributes).
# The repository is the one this file is in (not the current directory).

ATST_REPO_URL=https://github.com/terukusu/auto-trading-support-tools

set -u

usage() {
  echo "Usage: release.sh vX.Y.Z [--dry-run]"
  echo "       release.sh --refresh-sha vX.Y.Z [--dry-run]"
  echo "  --dry-run      check the preconditions and print the plan; change nothing"
  echo "  --refresh-sha  re-download the archive of an existing tag and rewrite the sha256 only"
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
  [ -n "${TMPD:-}" ] && rm -rf "${TMPD:?}"
}

# Prints the highest existing vN[.N...] tag (2-part tags included), or nothing.
latest_tag() {
  git -C "$REPO" tag -l 'v*' | grep -E '^v[0-9]+(\.[0-9]+)*$' | sort -V | tail -n 1
}

print_next_steps() {
  local v="$1"

  echo
  echo "Next steps (see docs/RELEASE.md):"
  echo "  1. create a branch release/${v} and commit only scripts/init_atst.sh"
  echo "  2. publish the branch, open a PR (gh pr create), wait for CI and merge it"
  echo "  3. update the gist from master: gh gist edit <gist-id> -f init_atst.sh scripts/init_atst.sh"
  echo "  4. check it: gh gist view <gist-id> --raw -f init_atst.sh | diff - scripts/init_atst.sh"
}

main() {
  local v="" dry=0 refresh=0 nver=0 init status_out remote_tag latest prev url zip sha head_c origin_c

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --dry-run) dry=1 ;;
      --refresh-sha) refresh=1 ;;
      -*) usage_error "unknown option: $1" ;;
      *) v=$1; nver=$((nver + 1)) ;;
    esac
    shift
  done
  [ "$nver" -eq 1 ] || usage_error "give exactly one version (vX.Y.Z)"

  # P1: version format.
  [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be vX.Y.Z (three numbers): ${v}"

  REPO=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel) || die "not inside a git repository"
  init="$REPO/scripts/init_atst.sh"

  # P2: the two lines to rewrite exist exactly once (checked before any tag is made).
  [ -f "$init" ] || die "scripts/init_atst.sh not found"
  [ "$(grep -c '^ATST_VERSION=' "$init")" -eq 1 ] || die "scripts/init_atst.sh must have exactly one ATST_VERSION= line"
  [ "$(grep -c '^ATST_ZIP_SHA256=' "$init")" -eq 1 ] || die "scripts/init_atst.sh must have exactly one ATST_ZIP_SHA256= line"

  # P3: no change to tracked files (untracked files do not go into a tag).
  status_out=$(git -C "$REPO" status --porcelain --untracked-files=no) || die "git status failed"
  [ -z "$status_out" ] || die "the working tree has uncommitted changes to tracked files"

  # P4: the tag must not exist yet (normal) / must exist on origin (--refresh-sha).
  remote_tag=$(git -C "$REPO" ls-remote --tags origin "refs/tags/${v}") || die "cannot reach origin (git ls-remote failed)"
  if [ "$refresh" -eq 1 ]; then
    [ -n "$remote_tag" ] || die "tag ${v} is not on origin; --refresh-sha only works for a released tag"
  else
    ! git -C "$REPO" rev-parse -q --verify "refs/tags/${v}" > /dev/null || die "tag ${v} already exists locally"
    [ -z "$remote_tag" ] || die "tag ${v} already exists on origin"

    # P5: newer than every existing version tag.
    latest=$(latest_tag)
    if [ -n "$latest" ]; then
      if [ "$latest" = "$v" ] || [ "$(printf '%s\n%s\n' "$latest" "$v" | sort -V | tail -n 1)" != "$v" ]; then
        die "${v} is not newer than the latest tag ${latest}"
      fi
    fi

    # P6: tag only what is already on origin's master.
    git -C "$REPO" fetch -q origin "+refs/heads/master:refs/remotes/origin/master" || die "git fetch origin master failed"
    head_c=$(git -C "$REPO" rev-parse -q --verify HEAD) || die "no HEAD commit"
    origin_c=$(git -C "$REPO" rev-parse -q --verify refs/remotes/origin/master) || die "origin/master not found"
    [ "$head_c" = "$origin_c" ] || die "HEAD is not origin/master; switch to master and pull it first"
  fi

  url="${ATST_REPO_URL}/archive/refs/tags/${v}.zip"

  if [ "$dry" -eq 1 ]; then
    echo "[dry-run] nothing is changed. Plan:"
    if [ "$refresh" -eq 1 ]; then
      echo "  tag:      ${v} (existing on origin; not created, not sent)"
    else
      prev=$latest
      echo "  tag:      ${v} (annotated) on $(git -C "$REPO" log -1 --format='%h %s' HEAD)"
      echo "  send:     origin refs/tags/${v} (the tag only, no branch)"
    fi
    echo "  fetch:    ${url}"
    echo "  rewrite:  scripts/init_atst.sh (ATST_VERSION / ATST_ZIP_SHA256)"
    if [ "$refresh" -eq 0 ]; then
      echo "  previous: ${prev:-(none)}"
      echo
      echo "### Changes since ${prev:-the beginning}"
      if [ -n "$prev" ]; then
        git -C "$REPO" log --oneline --no-merges "${prev}..HEAD"
      else
        git -C "$REPO" log --oneline --no-merges HEAD
      fi
    fi
    exit 0
  fi

  if [ "$refresh" -eq 0 ]; then
    prev=$latest
    git -C "$REPO" tag -a "$v" -m "atst ${v}" || die "git tag failed"
    # Only the tag goes to origin. On failure, drop the local tag so that a re-run works.
    if ! git -C "$REPO" push origin "refs/tags/${v}"; then
      git -C "$REPO" tag -d "$v" > /dev/null
      die "could not send tag ${v} to origin; the local tag was removed"
    fi
  fi

  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/atst-release.XXXXXX") || die "cannot create a temporary directory"
  trap cleanup EXIT
  zip="$TMPD/archive.zip"
  if ! curl -fsSL --proto '=https' --max-time 120 --retry 5 --retry-delay 3 -o "$zip" "$url" < /dev/null \
    || [ ! -s "$zip" ]; then
    die "tag ${v} is on origin but its archive could not be fetched (${url}); re-run: scripts/release.sh --refresh-sha ${v}"
  fi
  sha=$(sha256sum "$zip" | cut -d' ' -f1)
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "could not compute the sha256 of the archive"

  # $v and $sha were validated above and contain no sed metacharacters.
  sed -i -e "s/^ATST_VERSION=.*/ATST_VERSION=${v}/" -e "s/^ATST_ZIP_SHA256=.*/ATST_ZIP_SHA256=${sha}/" "$init" \
    || die "could not rewrite scripts/init_atst.sh"
  [ "$(grep -cx "ATST_VERSION=${v}" "$init")" -eq 1 ] && [ "$(grep -cx "ATST_ZIP_SHA256=${sha}" "$init")" -eq 1 ] \
    || die "scripts/init_atst.sh was not rewritten as expected"

  echo "[info] scripts/init_atst.sh now pins ${v} (sha256 ${sha}); it is not committed."
  if [ "$refresh" -eq 0 ]; then
    echo
    echo "## atst ${v}"
    echo "- archive: ${url}"
    echo "- sha256: ${sha}"
    echo
    echo "### Changes since ${prev:-the beginning}"
    if [ -n "$prev" ]; then
      git -C "$REPO" log --oneline --no-merges "${prev}..${v}"
    else
      git -C "$REPO" log --oneline --no-merges "$v"
    fi
  fi
  print_next_steps "$v"
}

main "$@"
