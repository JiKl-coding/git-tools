#!/usr/bin/env bash
# git-tools.sh
# Small helper for Git workflow (ideal as a backend for git aliases).
# Installation, configuration and aliases: GitToolsSetup.cmd (in the same folder as the source version).
#
# Recommended aliases in ~/.gitconfig:
#   [alias]
#     new      = "!$HOME/git-tools.sh new"
#     sw       = "!$HOME/git-tools.sh sw"
#     del      = "!$HOME/git-tools.sh del"
#     com      = "!$HOME/git-tools.sh com"
#     sync     = "!$HOME/git-tools.sh sync"
#     merg     = "!$HOME/git-tools.sh merg"
#     reb      = "!$HOME/git-tools.sh reb"
#     reb-ai   = "!$HOME/git-tools.sh reb-ai"
#     reb-ac   = "!$HOME/git-tools.sh reb-ac"
#     done     = "!$HOME/git-tools.sh done"
#     gone     = "!$HOME/git-tools.sh gone"
#     up       = "!$HOME/git-tools.sh up"
#     dif      = "!$HOME/git-tools.sh dif"
#     dif-file = "!$HOME/git-tools.sh dif-file"
#     st       = "!$HOME/git-tools.sh st"
#     br       = "!$HOME/git-tools.sh br"
#     cp       = "!$HOME/git-tools.sh cp"
#     ver      = "!$HOME/git-tools.sh ver"
#     h        = "!$HOME/git-tools.sh help"

set -euo pipefail

# === Config loading ===
# Loads values from the config file, if it exists.
# The GITTOOLS_CONFIG_DEFAULT line is rewritten by GitToolsSetup during installation.
GITTOOLS_CONFIG_DEFAULT="J:/config/git-tools.conf"

if [[ -n "${GITTOOLS_CONFIG:-}" && -f "$GITTOOLS_CONFIG" ]]; then
  source "$GITTOOLS_CONFIG"
elif [[ -f "$GITTOOLS_CONFIG_DEFAULT" ]]; then
  source "$GITTOOLS_CONFIG_DEFAULT"
fi

# =========================
# Configuration (can be overridden via env variables)
# These are only FALLBACKS; values are normally taken from git-tools.conf
# =========================
# Prefix for "user" branches
USER_PREFIX="${USER_PREFIX:-user/unknown/}"

# List of "env" branches (space-separated). These branches:
# - are kept as local names (main/dev/...)
# - are normalized to origin/<branch> (with fetch) for diff/rebase base
ENV_BRANCHES="${ENV_BRANCHES:-main dev acc int work}"

# Default base branch for some commands
DEFAULT_BASE="${DEFAULT_BASE:-main}"

# Default dir for dif --log (a file is created there)
DIFF_LOG_DIR="${DIFF_LOG_DIR:-j:/temp}"

# Default prefix for legacy shortcuts (dif-file, com); empty = no prefix
LEGACY_DIR="${LEGACY_DIR:-}"

# =========================
# Helpery
# =========================
die() { echo "ERROR: $*" >&2; exit 2; }

current_branch() {
  git branch --show-current
}

# Returns 0 (true) if $1 is in ENV_BRANCHES, otherwise 1 (false)
is_env_branch() {
  local b="${1:-}"
  local x
  for x in $ENV_BRANCHES; do
    [[ "$b" == "$x" ]] && return 0
  done
  return 1
}

# Returns 0 (true) if it looks like a git ref/commit-ish and must not be prefixed.
# (Prevents HEAD or a hash from becoming USER_PREFIX+HEAD etc.)
is_ref_like() {
  local s="${1:-}"
  [[ -z "$s" ]] && return 1

  # typical refs
  [[ "$s" == "HEAD" ]] && return 0
  [[ "$s" == origin/* ]] && return 0
  [[ "$s" == refs/* ]] && return 0

  # commit-ish syntax
  [[ "$s" == *"~"* || "$s" == *"^"* ]] && return 0

  # hash (short or full)
  [[ "$s" =~ ^[0-9a-fA-F]{7,40}$ ]] && return 0

  return 1
}

# Input: branch-ish string
# Output:
# - if it is an env branch (main/dev/...), returns it as a local name
# - if it contains '/', returns it unchanged (e.g. pepa/pes)
# - otherwise prepends USER_PREFIX (e.g. test -> user/jikl/test)
with_user_prefix() {
  local b="${1:-}"
  [[ -z "$b" ]] && die "Missing branch name"

  if is_env_branch "$b"; then
    printf '%s\n' "$b"
    return 0
  fi

  if [[ "$b" == */* ]]; then
    printf '%s\n' "$b"
  else
    printf '%s\n' "${USER_PREFIX}${b}"
  fi
}

# Input: ref-ish string (for dif, or the base for reb)
# Output:
# - env branch -> runs fetch origin <b> and returns origin/<b>
# - ref-like (HEAD, origin/main, hash, refs/...) -> returned unchanged
# - otherwise -> uses with_user_prefix (i.e. branch per the USER_PREFIX convention)
normalize_ref() {
  local input="${1:-}"
  [[ -z "$input" ]] && die "Missing ref/branch name"

  if is_env_branch "$input"; then
    echo "fetching from origin $input" >&2
    git fetch origin "$input"
    printf 'origin/%s\n' "$input"
    return 0
  fi

  if is_ref_like "$input"; then
    printf '%s\n' "$input"
    return 0
  fi

  printf '%s\n' "$(with_user_prefix "$input")"
}

# Prepends LEGACY_DIR to a file without a path (/ or \); empty LEGACY_DIR = unchanged
legacy_path() {
  local f="${1:-}"
  if [[ "$f" == *"/"* || "$f" == *"\\"* || -z "$LEGACY_DIR" ]]; then
    printf '%s\n' "$f"
  else
    printf '%s/%s\n' "${LEGACY_DIR%/}" "$f"
  fi
}

# Ask for confirmation if the working tree is dirty.
# Used before commands that switch branches / reset / rebase / merge, so user doesn't
# accidentally lose context or get surprised by Git refusing the operation.
confirm_dirty_worktree() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if [[ -z "$(git status --porcelain)" ]]; then
    return 0
  fi

  echo "You have uncommitted changes (staged or unstaged)."
  echo "Do you want to continue? [y/N]"
  read -r answer

  case "${answer,,}" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

# -f / --force: only bypasses the ENV_BRANCHES protection; it is NOT git push --force.
parse_force() {
  FORCE=0
  POSITIONAL=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force) FORCE=1 ;;
      *) POSITIONAL+=("$1") ;;
    esac
    shift
  done
}

check_protected() {
  local branch="$1" operation="$2"
  if is_env_branch "$branch"; then
    if (( FORCE )); then
      echo "WARNING: $operation on protected branch '$branch' (--force override)." >&2
    else
      die "$operation on protected branch '$branch' is prohibited (use -f/--force to override)."
    fi
  fi
}

usage() {
  cat <<'EOF'
git-tools.sh - helper CLI (for git aliases)


Commands:

  Note (safety):
    Some commands (e.g. sw/new/del/sync/up/merg/reb/cp) ask for confirmation
    before acting if you have uncommitted changes.

  br [-asc|--asc] [-desc|--desc] [-rev|--rev]
      Lists local branches.
      Default: newest first (by committerdate).
      -asc  : sort by name (A->Z)
      -desc : sort by name (Z->A)
      -rev  : reverses the current sort order (e.g. oldest first)

  com <message>
  com <path> <message>
      Stages changes and creates a commit.
      - 1 argument:
          git add . + git commit -m "<message>"
      - 2 arguments:
          - if <path> contains '/' or '\', it is used as is:
              git add <path>
          - otherwise it is treated as a legacy shortcut:
              git add LEGACY_DIR/<path>  (empty LEGACY_DIR = <path> unchanged)
          In both cases:
              git commit -m "<message>"

  cp [-f|--force] <commit-hash>
      Asks for confirmation first if you have uncommitted changes.
      Cherry-picks the given commit onto the current branch.
      Cherry-pick onto an env branch is prohibited.

  del [-f|--force] <branch>
      Deletes a branch (if it has no '/', USER_PREFIX is used).
      Env branches (main/dev/...) are protected and deleting them is prohibited.
      If you are on the target branch, switches to DEFAULT_BASE first
      (asks for confirmation if the worktree is dirty).

  dif [OPTIONS] [b1] [b2]
      git diff between two refs.
      Default: b1=DEFAULT_BASE, b2=current branch
      Env branches are normalized to origin/<branch> and fetched.

      OPTIONS (can be combined in any order):
        -n, --name-only      print file names only
        -t, --name-status    print A/M/D status + files
        -s, --stat           print summary statistics
        -l, --log            write the diff to a log file
                             (DIFF_LOG_DIR, name: git_diff_YYYYMMDD.log)

  dif-file [OPTIONS] [b1] [b2] <filename|path>
      git diff of one specific file.

      Default:
        b1 = DEFAULT_BASE
        b2 = current branch

      If <filename> contains no path (/ or \) and LEGACY_DIR is not empty,
      the prefix is added automatically:
        LEGACY_DIR/<filename>

      Env branches are normalized to origin/<branch>
      and fetched before the diff.

      OPTIONS (can be combined in any order):
        -n, --name-only      print file names only
        -t, --name-status    print A/M/D status
        -s, --stat           print summary statistics
        -l, --log            write the diff to a log file
                             (DIFF_LOG_DIR, name: git_diff_file_YYYYMMDD.log)

  done [-f|--force]
      git push -u origin HEAD
      Push on env branches (main/dev/...) is prohibited.
      If the push fails (typically after a rebase), offers --force-with-lease.

  gone [-f|--force]
      Runs fetch --all --prune and offers to delete local branches
      whose upstream is ': gone' (deleted on the remote).
      Skips env branches (-f includes them).

  merg [-f|--force] <branch>
      Asks for confirmation first if you have uncommitted changes.
      Merges the given branch into the current branch (no fetch).
      If <branch> has no '/', USER_PREFIX is used.
      Env branches are kept as local names.
      Merging into an env branch is prohibited.

  new [OPTIONS] <name> [from_in]
      Creates a new branch

      <name>
      - if <name> contains '/', it is used unchanged (e.g. pepa/pes)
      - otherwise USER_PREFIX<name> is created

      <from_in>
      - if <from_in> is not given, creates from DEFAULT_BASE
      - if <from_in> is in ENV_BRANCHES, fetches and creates from it
      - if <from_in> contains '/', it is used unchanged (e.g. pepa/pes) (no fetch, assumes a local branch)
      - otherwise creates from USER_PREFIX/<from_in> (no fetch, assumes a local branch)

      OPTIONS (can be combined in any order)
        -c, --current     creates from the current branch, no fetch!
                          !! combining <from_in> and -c => fails with an error
        -f, --force       allows an env branch as the target

      Env branches (main/dev/...) are prohibited as the target.

  reb [-f|--force] [base]
      Asks for confirmation first if you have uncommitted changes.
      Interactive rebase of the CURRENT branch onto:
      - origin/<env base> (for an env base; default is DEFAULT_BASE) + fetch
      - USER_PREFIX/base (for a non-env base)
      Rebase on env branches (main/dev/...) is prohibited.

  reb-ai [-f|--force] [base]
  reb-ac [-f|--force] [base]
      Same as reb, but NON-interactive with automatic conflict resolution:
      - reb-ai = accept incoming (-X theirs) => commits of the CURRENT branch win
      - reb-ac = accept current  (-X ours)   => the base wins (e.g. origin/main)
      Note: during a rebase "current" is the base and "incoming" are your commits.
      -X only resolves content conflicts; modify/delete etc. still stops the rebase.

  st
      Quick overview: git status -sb + the last 10 commits.

  sw <branch>
      Asks for confirmation first if you have uncommitted changes.
      Switches to a branch. If <branch> has no '/', USER_PREFIX is used.
      Env branches (main/dev/...) are kept as local names.

  sync <branch>
      Asks for confirmation before reset/switch if you have uncommitted changes.
      Syncs the local branch to origin/<branch>:
      - fetch origin <branch>
      - if the local branch does not exist, creates it from origin/<branch>
      - reset --hard to origin/<branch>
      - optionally asks about git clean -fd

  up
      Asks for confirmation before rebase/sync if you have uncommitted changes.
      Updates the current branch:
      - if the current branch is an env branch: runs sync <current> (including the git clean -fd prompt)
      - otherwise: fetch origin DEFAULT_BASE + rebase current onto origin/DEFAULT_BASE

  ver list [pattern]
      Lists tags (newest first).
  ver new <version> [ref] [-m <message>]
      Creates an annotated tag on HEAD or on the given commit/ref.
      Shortcut: ver <version> [ref]. The tag is NOT published automatically.
  ver show <version>
      Shows the tag details and commit.
  ver push <version|--all>
      Publishes a tag or all local tags to origin.
  ver del <version> [--remote]
      Deletes the local tag; --remote also deletes the tag on origin.
      Tags are not branches and never get USER_PREFIX.

  -f, --force
      For cp, del, new, done, merg, reb, reb-ai, reb-ac, gone it bypasses the
      ENV_BRANCHES protection; it does NOT automatically run git push --force.


Configuration (git-tools.conf, path in GITTOOLS_CONFIG_DEFAULT or env GITTOOLS_CONFIG;
can be overridden via env variables):
  USER_PREFIX="user/unknown/"
  ENV_BRANCHES="main dev acc int work"
  DEFAULT_BASE="main"
  DIFF_LOG_DIR="j:/temp"
  LEGACY_DIR=""

Examples:
  $HOME/git-tools.sh new pepa/pes
  $HOME/git-tools.sh up
  $HOME/git-tools.sh gone
  $HOME/git-tools.sh dif dev -n -l
  $HOME/git-tools.sh com "fix: typo"
  $HOME/git-tools.sh done
  $HOME/git-tools.sh ver new v1.2.0 -m "Release 1.2.0"

EOF
}

# =========================
# Commands
# =========================
cmd_st() {
  local cur
  cur="$(current_branch)"
  echo "Status: $cur"
  git status -sb
  echo
  echo "Recent commits:"
  git log --oneline --decorate -n 10
}

cmd_br() {
  # br [-asc|--asc] [-desc|--desc] [-rev|--rev]
  local sort_mode="date"   # date | name_asc | name_desc
  local reverse=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -asc|--asc) sort_mode="name_asc"; shift ;;
      -desc|--desc) sort_mode="name_desc"; shift ;;
      -rev|--rev) reverse=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  local sort_arg=""
  case "$sort_mode" in
    date)
      sort_arg="-committerdate"
      (( reverse )) && sort_arg="committerdate"
      ;;
    name_asc)
      sort_arg="refname"
      (( reverse )) && sort_arg="-refname"
      ;;
    name_desc)
      sort_arg="-refname"
      (( reverse )) && sort_arg="refname"
      ;;
    *)
      die "Internal error: unknown sort mode"
      ;;
  esac

  git for-each-ref --sort="$sort_arg" refs/heads/ --format='%(committerdate:short) %(refname:short)'
}

cmd_sw() {
  local input="${1:?Usage: sw <branch>}"
  local target
  target="$(with_user_prefix "$input")"
  confirm_dirty_worktree || die "Aborted."

  git switch "$target"
}

cmd_del() {
  parse_force "$@"
  set -- "${POSITIONAL[@]}"
  [[ $# -eq 1 ]] || die "Usage: del [-f|--force] <branch>"
  local target current
  target="$(with_user_prefix "$1")"

  # Safety: never delete env branches (local copy); use sync to align with the remote
  check_protected "$target" "Deleting"

  current="$(current_branch)"
  if [[ "$current" == "$target" ]]; then
    [[ "$target" != "$DEFAULT_BASE" ]] || die "Cannot delete checked-out DEFAULT_BASE. Switch elsewhere first."
    echo "Switching to $DEFAULT_BASE to delete $target"
    confirm_dirty_worktree || die "Aborted."
    git switch "$DEFAULT_BASE"
  fi

  git branch -D "$target"
}

cmd_new() {
  # new [-f] <name> [from]
  # new [-f] <name> -c
  parse_force "$@"
  set -- "${POSITIONAL[@]}"
  local name
  local from_in=""
  local use_current=0

  [[ -z "${1:-}" ]] && die "Usage: new [-f|--force] <name> [from] | new <name> -c"

  name="$1"
  shift

  # parse optional flags / from
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--current)
        use_current=1
        shift
        ;;
      *)
        [[ -z "$from_in" ]] || die "Only one 'from' branch can be specified."
        from_in="$1"
        shift
        ;;
    esac
  done

  local target from_ref
  target="$(with_user_prefix "$name")"

  # Safety: never create an env branch name
  check_protected "$target" "Creating"

  confirm_dirty_worktree || die "Aborted."

  # Resolve from_ref
  if (( use_current )); then
    if [[ -n "$from_in" ]]; then
      die "Option -c cannot be combined with explicit 'from' branch."
    fi
    from_ref="$(current_branch)"
  else
    from_in="${from_in:-$DEFAULT_BASE}"
    from_ref="$(normalize_ref "$from_in")"
  fi

  echo "Creating branch '$target' from '$from_ref'"
  git switch -c "$target" "$from_ref"
}


cmd_sync() {
  local b="${1:?Usage: sync <branch>}"
  local answer

  confirm_dirty_worktree || die "Aborted."

  echo "fetching from origin $b"
  git fetch origin "$b"

  # If the local branch does not exist, create it from origin/$b
  if ! git show-ref --verify --quiet "refs/heads/$b"; then
    echo "Local branch '$b' not found, creating from origin/$b"
    git switch -c "$b" "origin/$b"
  else
    echo "Switching to $b"
    git switch "$b"
  fi

  echo "Resetting local $b to latest origin/$b"
  git reset --hard "origin/$b"

  echo
  read -r -p "Run 'git clean -fd'? This will DELETE untracked files and dirs. [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) git clean -fd ;;
    *) echo "Skipping git clean -fd" ;;
  esac

  echo "DONE."
}

cmd_gone() {
  parse_force "$@"
  [[ ${#POSITIONAL[@]} -eq 0 ]] || die "Usage: gone [-f|--force]"
  local answer
  local cur

  echo "This will run: git fetch --all --prune"
  read -r -p "Continue? [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; return 0 ;;
  esac

  git fetch --all --prune

  # Find local branches whose upstream is gone
  # Handles current branch line starting with '*'
  mapfile -t gone_branches < <(
    git branch -vv |
    awk '/: gone]/{ if ($1=="*") print $2; else print $1 }' |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  )

  # Defensive cleanup (drop empty entries)
  local filtered=()
  local b
  for b in "${gone_branches[@]}"; do
    [[ -n "$b" ]] && filtered+=("$b")
  done
  gone_branches=("${filtered[@]}")

  if [[ ${#gone_branches[@]} -eq 0 ]]; then
    echo "No gone branches found."
    return 0
  fi

  echo "================================================================"
  echo "The following local branches will be DELETED:"
  printf '  %s\n' "${gone_branches[@]}"
  echo

  read -r -p "Delete these local branches? (uses git branch -D) [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Skipping delete."; return 0 ;;
  esac

  cur="$(current_branch)"

  for b in "${gone_branches[@]}"; do
    [[ -z "$b" ]] && continue

    if is_env_branch "$b" && (( ! FORCE )); then
      echo "Skipping protected env branch: $b (use -f to include)"
      continue
    fi

    # If we're on the branch we want to delete, switch away first (like cmd_del)
    if [[ "$b" == "$cur" ]]; then
      if ! git show-ref --verify --quiet "refs/heads/$DEFAULT_BASE"; then
        die "DEFAULT_BASE '$DEFAULT_BASE' does not exist locally. Cannot switch away to delete current branch."
      fi
      echo "Switching to $DEFAULT_BASE to delete current branch: $b"
      confirm_dirty_worktree || die "Aborted."
      git switch "$DEFAULT_BASE"
      cur="$(current_branch)"
    fi

    echo "Deleting: $b"
    git branch -D "$b"
  done

  echo "DONE."
}


cmd_up() {
  local cur
  cur="$(current_branch)"

  if [[ -z "$cur" ]]; then
    die "Can't detect current branch."
  fi

  if is_env_branch "$cur"; then
    echo "Current branch is env branch ($cur). Running sync $cur."
    cmd_sync "$cur"
    return 0
  fi

  confirm_dirty_worktree || die "Aborted."

  echo "fetching from origin $DEFAULT_BASE"
  git fetch origin "$DEFAULT_BASE"
  echo "Rebasing '$cur' onto origin/$DEFAULT_BASE"
  git rebase "origin/$DEFAULT_BASE"
}

cmd_merg() {
  parse_force "$@"
  set -- "${POSITIONAL[@]}"
  [[ $# -eq 1 ]] || die "Usage: merg [-f|--force] <branch>"
  local other current

  other="$(with_user_prefix "$1")"
  current="$(current_branch)"

  check_protected "$current" "Merging"

  confirm_dirty_worktree || die "Aborted."

  echo "Merging $other into $current"
  git merge "$other"
  echo "WARNING: this command does not fetch before merge!"
}

cmd_reb() {
  # reb [-f] [base]
  rebase_impl "" "$@"
}

cmd_reb_ai() {
  # reb-ai [-f] [base] - during a rebase incoming = theirs (replayed commits)
  rebase_impl "theirs" "$@"
}

cmd_reb_ac() {
  # reb-ac [-f] [base] - during a rebase current = ours (the base)
  rebase_impl "ours" "$@"
}

# rebase_impl <strategy: ""|theirs|ours> [-f|--force] [base]
rebase_impl() {
  local strategy="${1:-}"
  shift || true
  parse_force "$@"
  set -- "${POSITIONAL[@]}"
  [[ $# -le 1 ]] || die "Usage: reb|reb-ai|reb-ac [-f|--force] [base]"
  local current base_in base

  current="$(current_branch)"

  # 0) Prohibit rebase on env branches
  check_protected "$current" "Rebasing"

  # 1) base input (default)
  base_in="${1:-$DEFAULT_BASE}"

  # 2) env base -> fetch + origin/<base>
  if is_env_branch "$base_in"; then
    echo "fetching from origin $base_in"
    git fetch origin "$base_in"
    base="origin/$base_in"
  else
    # 3) non-env base -> podle USER_PREFIX konvence
    base="$(with_user_prefix "$base_in")"
  fi

  confirm_dirty_worktree || die "Aborted."

  if [[ -z "$strategy" ]]; then
    echo "Rebasing '$current' onto $base"
    git rebase -i "$base"
  else
    echo "Rebasing '$current' onto $base (conflicts auto-resolved: -X $strategy)"
    git rebase -X "$strategy" "$base"
  fi
}

cmd_dif() {
  # dif [OPTIONS] [b1] [b2]
  local use_pager=0
  local mode="full"   # full | name_only | name_status | stat
  local args=()

  # parse flags anywhere
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--log)
        use_pager=1
        shift
        ;;
      -n|--name|--name-only)
        [[ "$mode" != "full" ]] && die "Only one of --name-only/--name-status/--stat can be used."
        mode="name_only"
        shift
        ;;
      -t|--name-status)
        [[ "$mode" != "full" ]] && die "Only one of --name-only/--name-status/--stat can be used."
        mode="name_status"
        shift
        ;;
      -s|--stat)
        [[ "$mode" != "full" ]] && die "Only one of --name-only/--name-status/--stat can be used."
        mode="stat"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  local b1_in b2_in
  if [[ ${#args[@]} -eq 0 ]]; then
    b1_in="$DEFAULT_BASE"
    b2_in="$(current_branch)"
  elif [[ ${#args[@]} -eq 1 ]]; then
    b1_in="${args[0]}"
    b2_in="$(current_branch)"
  else
    b1_in="${args[0]}"
    b2_in="${args[1]}"
  fi

  local b1 b2
  b1="$(normalize_ref "$b1_in")"
  b2="$(normalize_ref "$b2_in")"

  local extra=()
  case "$mode" in
    full) ;;
    name_only) extra+=(--name-only) ;;
    name_status) extra+=(--name-status) ;;
    stat) extra+=(--stat) ;;
    *) die "Internal error: unknown dif mode" ;;
  esac

  if (( use_pager )); then
    local stamp logfile

    stamp="$(date +'%Y%m%d')"
    logfile="$DIFF_LOG_DIR/git_diff_${stamp}.log"

    # create the folder if it does not exist
    mkdir -p "$DIFF_LOG_DIR" 2>/dev/null || true

    {
      echo "========================================"
      echo "GIT DIFF LOG"
      echo "Date:    $(date)"
      echo "Branch1: $b1"
      echo "Branch2: $b2"
      echo "Mode:    $mode"
      echo "Command: git diff $b1 $b2 ${extra[*]}"
      echo "========================================"
      echo
      git diff "$b1" "$b2" "${extra[@]}"
    } > "$logfile"

    echo "Diff written to: $logfile"

  else
    if [[ ${#extra[@]} -gt 0 ]]; then
      echo "Comparing $b1 to $b2 (${extra[*]})"
    else
      echo "Comparing $b1 to $b2"
    fi
    git diff "$b1" "$b2" "${extra[@]}"
  fi
}

cmd_dif_file() {
  # dif-file [OPTIONS] [b1] [b2] <file|path>
  local use_pager=0
  local mode="full"   # full | name_only | name_status | stat
  local args=()

  # parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--log)
        use_pager=1
        shift
        ;;
      -n|--name|--name-only)
        [[ "$mode" != "full" ]] && die "Only one of --name-only/--name-status/--stat can be used."
        mode="name_only"
        shift
        ;;
      -t|--name-status)
        [[ "$mode" != "full" ]] && die "Only one of --name-only/--name-status/--stat can be used."
        mode="name_status"
        shift
        ;;
      -s|--stat)
        [[ "$mode" != "full" ]] && die "Only one of --name-only/--name-status/--stat can be used."
        mode="stat"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  # the last argument MUST be a file / name
  if [[ ${#args[@]} -lt 1 ]]; then
    die "Usage: git dif-file [options] [b1] [b2] <file|path>"
  fi

  local file_in file
  file_in="${args[-1]}"
  unset 'args[-1]'

  file="$(legacy_path "$file_in")"

  local b1_in b2_in
  if [[ ${#args[@]} -eq 0 ]]; then
    b1_in="$DEFAULT_BASE"
    b2_in="$(current_branch)"
  elif [[ ${#args[@]} -eq 1 ]]; then
    b1_in="${args[0]}"
    b2_in="$(current_branch)"
  else
    b1_in="${args[0]}"
    b2_in="${args[1]}"
  fi

  local b1 b2
  b1="$(normalize_ref "$b1_in")"
  b2="$(normalize_ref "$b2_in")"

  local extra=()
  case "$mode" in
    full) ;;
    name_only) extra+=(--name-only) ;;
    name_status) extra+=(--name-status) ;;
    stat) extra+=(--stat) ;;
    *) die "Internal error: unknown dif-file mode" ;;
  esac

  local cmd=(git diff "$b1" "$b2" "${extra[@]}" -- "$file")

  if (( use_pager )); then
    local stamp logfile
    stamp="$(date +'%Y%m%d')"
    logfile="$DIFF_LOG_DIR/git_diff_file_${stamp}.log"

    mkdir -p "$DIFF_LOG_DIR" 2>/dev/null || true

    {
      echo "========================================"
      echo "GIT DIFF FILE LOG"
      echo "Date:    $(date)"
      echo "Branch1: $b1"
      echo "Branch2: $b2"
      echo "File:    $file"
      echo "Mode:    $mode"
      echo "Command: ${cmd[*]}"
      echo "========================================"
      echo
      "${cmd[@]}"
    } > "$logfile"

    echo "Diff written to: $logfile"
  else
    echo "Comparing $b1 to $b2 -- $file"
    "${cmd[@]}"
  fi
}

cmd_com() {
  # com <message>
  # com <path> <message>
  local what message

  if [[ -z "${2:-}" ]]; then
    # only commit message -> commit everything
    message="${1:?Usage: com <message> | com <path> <message>}"
    what="."
  else
    what="$(legacy_path "$1")"
    message="$2"
  fi

  echo "git add $what"
  git add "$what"

  echo "git commit -m \"$message\""
  git commit -m "$message"
}

cmd_cp() {
  # cp [-f] <commit-hash>
  parse_force "$@"
  set -- "${POSITIONAL[@]}"
  [[ $# -eq 1 ]] || die "Usage: cp [-f|--force] <commit-hash>"
  local commit_hash="$1"
  local current
  current="$(current_branch)"

  check_protected "$current" "Cherry-picking"

  confirm_dirty_worktree || die "Aborted."

  echo "Cherry-picking $commit_hash onto $current"
  git cherry-pick "$commit_hash"
}

cmd_done() {
  parse_force "$@"
  [[ ${#POSITIONAL[@]} -eq 0 ]] || die "Usage: done [-f|--force]"
  local current answer
  current="$(current_branch)"

  # 0) Prohibit push on env branches
  check_protected "$current" "Pushing"

  echo "git push -u origin HEAD"
  if git push -u origin HEAD; then
    return 0
  fi

  # push failed - typically after a rebase
  echo
  echo "Push failed (branch is probably behind due to rebase)."
  read -r -p "Force push with --force-with-lease? (yes/no) " answer

  case "$answer" in
    y|Y|yes|YES)
      echo "git push --force-with-lease -u origin HEAD"
      git push --force-with-lease -u origin HEAD
      ;;
    *)
      echo "Aborted. No force push performed."
      return 1
      ;;
  esac
}


# =========================
# Version management via git ver (annotated tags by default)
# =========================
cmd_ver() {
  local operation="${1:-list}"
  [[ $# -eq 0 ]] || shift
  case "$operation" in
    list|ls)
      [[ $# -le 1 ]] || die "Usage: ver list [pattern]"
      if [[ $# -eq 1 ]]; then
        git tag --list --sort=-creatordate "$1"
      else
        git tag --list --sort=-creatordate
      fi
      ;;
    new|create)
      ver_create "$@"
      ;;
    show)
      [[ $# -eq 1 ]] || die "Usage: ver show <version>"
      git show --no-patch "refs/tags/$1"
      ;;
    push)
      [[ $# -eq 1 ]] || die "Usage: ver push <version|--all>"
      if [[ "$1" == "--all" ]]; then
        git push origin --tags
      else
        git show-ref --verify --quiet "refs/tags/$1" || die "Tag not found: $1"
        git push origin "refs/tags/$1"
      fi
      ;;
    del|delete|rm)
      [[ $# -ge 1 && $# -le 2 ]] || die "Usage: ver del <version> [--remote]"
      local name="$1" remote=0 answer
      if [[ $# -eq 2 ]]; then
        [[ "$2" == "--remote" ]] || die "Unknown option: $2"
        remote=1
      fi
      git show-ref --verify --quiet "refs/tags/$name" || die "Tag not found: $name"
      if (( remote )); then
        read -r -p "Delete tag '$name' also on origin? Type yes: " answer
        [[ "$answer" == "yes" ]] || { echo "Aborted."; return 1; }
        git push origin --delete "$name"
      fi
      git tag -d "$name"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      # Short form: git ver <version> [ref]
      ver_create "$operation" "$@"
      ;;
  esac
}

ver_create() {
  local name="" ref="HEAD" message="" ref_set=0
  [[ $# -gt 0 ]] || die "Usage: ver new <version> [ref] [-m <message>]"
  name="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--message)
        [[ $# -ge 2 ]] || die "Missing tag message"
        message="$2"; shift 2 ;;
      -*) die "Unknown tag option: $1" ;;
      *)
        (( ref_set == 0 )) || die "Only one ref can be specified"
        ref="$1"; ref_set=1; shift ;;
    esac
  done
  git check-ref-format "refs/tags/$name" || die "Invalid tag name: $name"
  if [[ -z "$message" ]]; then message="Release $name"; fi
  git tag -a "$name" "$ref" -m "$message"
  echo "Created annotated tag '$name' at $(git rev-parse --short "$ref"). Publish: git ver push $name"
}

# =========================
# Router
# =========================
main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    st)       cmd_st "$@" ;;
    br)       cmd_br "$@" ;;
    sw)       cmd_sw "$@" ;;
    del)      cmd_del "$@" ;;
    new)      cmd_new "$@" ;;
    up)       cmd_up "$@" ;;
    sync)     cmd_sync "$@" ;;
    gone)     cmd_gone "$@" ;;
    merg)     cmd_merg "$@" ;;
    reb)      cmd_reb "$@" ;;
    reb-ai)   cmd_reb_ai "$@" ;;
    reb-ac)   cmd_reb_ac "$@" ;;
    dif)      cmd_dif "$@" ;;
    dif-file) cmd_dif_file "$@" ;;
    com)      cmd_com "$@" ;;
    done)     cmd_done "$@" ;;
    cp)       cmd_cp "$@" ;;
    ver)      cmd_ver "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "Unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
