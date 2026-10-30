# shellcheck shell=bash
# Sourced by common.sh only (ATST_HOME is set there). Do not source this file on its own.
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

# Prints the index of the first MetaTrader whose folder name (mt_name) starts with the
# argument, ignoring the case of ASCII letters; prints nothing when none matches or the
# argument is empty. The argument is plain text, not a pattern: spaces, quotes and
# characters such as . * ? [ ] ( ) | \ match only themselves.
#
function atst_find_mt_index() {
  local target_mt_name="$1"
  local upper_target i

  [ -n "$target_mt_name" ] || return 0

  # Same ASCII-only upper-casing as mt_name (atst_load_mt_list).
  upper_target=$(printf '%s' "$target_mt_name" | atst_to_upper)

  for i in "${!mt_name[@]}"; do
    # The quoted right-hand side is compared literally; only the trailing * is a pattern.
    if [[ ${mt_name[i]} == "$upper_target"* ]]; then
      echo "$i"
      return 0
    fi
  done
  return 0
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

# atst_auto_attach_enabled
# Returns 0 when ATST_AUTO_ATTACH_EA is exactly 1 (mtctl.sh start attaches the monitoring EA by the
# StartUp ini, #133), 1 otherwise (unset, empty, 0, yes, 01, " 1", ...). Prints nothing.
function atst_auto_attach_enabled() {
  [ "${ATST_AUTO_ATTACH_EA:-0}" = 1 ]
}

# atst_startup_ini_path <MT name>
# Prints "<prefix>/drive_c/atst/startup_<n>.ini", the StartUp ini of <MT name> (the name given to
# mtctl.sh start / ATST_TARGETS, not the folder name): <n> is the name in lower case with each byte
# other than a-z 0-9 _ turned into _, <prefix> the logical path of WINEPREFIX without a trailing /
# (cd && pwd, the form of mt_term). The ini lives in drive_c so that MetaTrader reads it as
# C:\atst\startup_<n>.ini without the Z: drive (#145). Prints nothing and returns 1 when the name is
# empty or WINEPREFIX is empty / not a directory. Creates nothing (only mtctl.sh start writes it).
function atst_startup_ini_path() {
  local prefix_l n

  [ -n "$1" ] && [ -n "${WINEPREFIX:-}" ] || return 1
  prefix_l=$(cd "$WINEPREFIX" 2>/dev/null && pwd) || return 1
  [ -n "$prefix_l" ] || return 1
  n=$(printf '%s' "$1" | atst_to_lower | LC_ALL=C tr -c 'a-z0-9_' '_')
  printf '%s\n' "$prefix_l/drive_c/atst/startup_$n.ini"
}

# atst_startup_ini_win_path <MT name>
# Prints the Windows form of atst_startup_ini_path (C:\atst\startup_<n>.ini) by atst_to_win_path: pure
# string work, winepath is not run. Prints nothing and returns 1 when there is none.
function atst_startup_ini_win_path() {
  local ini prefix_l win

  ini=$(atst_startup_ini_path "$1") || return 1
  prefix_l=$(cd "$WINEPREFIX" 2>/dev/null && pwd) || return 1
  win=$(atst_to_win_path "$ini" "$prefix_l")
  [ -n "$win" ] || return 1
  printf '%s\n' "$win"
}

# atst_startup_ini_arg <MT4|MT5> <Windows path of the ini>
# Prints the terminal.exe argument that passes the StartUp ini: the bare path for MT4
# (C:\atst\startup_<n>.ini; MT4 build 1492 on Wine 10.0 ignores /config:, checked on the real host,
# #133) and /config:<path> for MT5 (the MetaQuotes MT5 form, not checked on a real host yet). Prints
# nothing and returns 1 for another type or an empty path.
function atst_startup_ini_arg() {
  [ -n "$2" ] || return 1
  case $1 in
    MT4) printf '%s\n' "$2" ;;
    MT5) printf '%s\n' "/config:$2" ;;
    *) return 1 ;;
  esac
}

# atst_startup_ini_content <MT4|MT5> <symbol> <period>
# Prints the StartUp ini of mtctl.sh start: 5 lines ending with CRLF (ASCII, no BOM, no time, so the
# same arguments give the same bytes). Only [StartUp] Symbol / Period / Expert: no [Common] (account),
# [Experts], [Charts], Template= or ExpertParameters=. Checks first and prints nothing (stdout and
# stderr) when a value is wrong: returns 2 for the symbol (^[A-Za-z0-9._#&!@-]{1,32}$), 3 for the
# period (M1 M5 M15 M30 H1 H4 D1 W1 MN) and 4 for the type. Write it with "> file", not through $(...),
# which drops the last LF.
function atst_startup_ini_content() {
  local type="$1" symbol="$2" period="$3" expert
  local re='^[A-Za-z0-9._#&!@-]{1,32}$'

  [[ $symbol =~ $re ]] || return 2
  case $period in
    M1|M5|M15|M30|H1|H4|D1|W1|MN) ;;
    *) return 3 ;;
  esac
  case $type in
    MT4) expert='TerminalMonitoring' ;;
    MT5) expert='Advisors\TerminalMonitoring' ;;
    *) return 4 ;;
  esac
  printf '%s\r\n' \
    '; generated by atst mtctl.sh start (ATST_AUTO_ATTACH_EA=1). overwritten on every start.' \
    '[StartUp]' \
    "Symbol=$symbol" \
    "Period=$period" \
    "Expert=$expert"
}

# atst_find_pid <MT name>
# Prints the pid of the running MetaTrader whose folder name starts with <MT name> (atst_find_terminal),
# or nothing. Several matches print the smallest pid. Always returns 0 and never writes to stderr.
# Reads $ATST_PROC_ROOT/<pid>/ (default /proc; tests point it elsewhere) with bash builtins only:
# neither winepath (it starts Wine) nor ps/grep is run. A process matches when all of these hold:
#  - its effective uid (status, Uid:) is ours. Processes of other users are ignored on purpose:
#    mtctl stop can only kill our own, and WINEPREFIX lives under our HOME.
#  - argv[0] (argv[1] when argv[0] is wine/wine64/wine-preloader/wine64-preloader), ignoring case,
#    is mt_term or its Windows form (atst_to_win_path), optionally inside ", either alone or followed
#    by a blank / tab and anything (Wine may show the arguments joined to argv[0], e.g. the StartUp ini
#    argument of mtctl.sh start, #133); what follows the blank is ignored. "...\MT AB\terminal.exe" or
#    "...\terminal.exe.bak" (with or without a tail) is not "...\MT A\terminal.exe". In theory an
#    exe under a folder named "...\terminal.exe <blank>..." would match; no such folder is expected.
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
      u=${x^^}
      # The right-hand sides are quoted, so ', blanks, [ and * in a folder name are not a pattern.
      if [[ $u == "$t_unix" || $u == "\"$t_unix\"" || $u == "$t_unix"[[:space:]]* || $u == "\"$t_unix\""[[:space:]]* ]]; then
        form=unix
        break
      fi
      if [ -n "$t_win" ] && [[ $u == "$t_win" || $u == "\"$t_win\"" || $u == "$t_win"[[:space:]]* || $u == "\"$t_win\""[[:space:]]* ]]; then
        form=win
        break
      fi
      [[ $x == \"*\" ]] && [ "${#x}" -ge 2 ] && x=${x:1:${#x}-2}
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
