#!/usr/bin/env bash
# git-tools.sh
# Malý helper pro Git workflow (ideální jako backend pro git aliasy).
# Instalace, konfigurace a aliasy: GitToolsSetup.cmd (ve stejné složce jako zdrojová verze).
#
# Doporučené aliasy v ~/.gitconfig:
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
# Načte hodnoty z konfiguračního souboru, pokud existuje.
# Řádek GITTOOLS_CONFIG_DEFAULT přepisuje GitToolsSetup při instalaci.
GITTOOLS_CONFIG_DEFAULT="J:/config/git-tools.conf"

if [[ -n "${GITTOOLS_CONFIG:-}" && -f "$GITTOOLS_CONFIG" ]]; then
  source "$GITTOOLS_CONFIG"
elif [[ -f "$GITTOOLS_CONFIG_DEFAULT" ]]; then
  source "$GITTOOLS_CONFIG_DEFAULT"
fi

# =========================
# Konfigurace (lze override přes env proměnné)
# Jedná se pouze o FALLBACK, jinak se hodnoty berou z git-tools.conf
# =========================
# Prefix pro „uživatelské“ branche
USER_PREFIX="${USER_PREFIX:-user/unknown/}"

# Seznam „env“ branchí (oddělený mezerami). Tyto branche:
# - necháváme jako lokální názvy (main/dev/...)
# - pro diff/rebase-base normalizujeme na origin/<branch> a děláme fetch
ENV_BRANCHES="${ENV_BRANCHES:-main dev acc int work}"

# Default base branch pro některé příkazy
DEFAULT_BASE="${DEFAULT_BASE:-main}"

# Default dir pro --log u dif (vytvoří soubor)
DIFF_LOG_DIR="${DIFF_LOG_DIR:-j:/temp}"

# Default prefix pro legacy shortcuty (dif-file, com); prázdný = bez prefixu
LEGACY_DIR="${LEGACY_DIR:-}"

# =========================
# Helpery
# =========================
die() { echo "ERROR: $*" >&2; exit 2; }

current_branch() {
  git branch --show-current
}

# Vrací 0 (true), pokud je $1 v ENV_BRANCHES, jinak 1 (false)
is_env_branch() {
  local b="${1:-}"
  local x
  for x in $ENV_BRANCHES; do
    [[ "$b" == "$x" ]] && return 0
  done
  return 1
}

# Vrací 0 (true), pokud to vypadá jako git ref/commit-ish a nemá se prefixovat.
# (Chrání před tím, aby se z HEAD nebo hash stal USER_PREFIX+HEAD apod.)
is_ref_like() {
  local s="${1:-}"
  [[ -z "$s" ]] && return 1

  # typické refy
  [[ "$s" == "HEAD" ]] && return 0
  [[ "$s" == origin/* ]] && return 0
  [[ "$s" == refs/* ]] && return 0

  # commit-ish syntaktika
  [[ "$s" == *"~"* || "$s" == *"^"* ]] && return 0

  # hash (zkrácený i celý)
  [[ "$s" =~ ^[0-9a-fA-F]{7,40}$ ]] && return 0

  return 1
}

# Vstup: branch-ish string
# Výstup:
# - pokud je to env branch (main/dev/...), vrátí ji jako lokální název
# - pokud obsahuje '/', vrátí beze změny (např. pepa/pes)
# - jinak přidá USER_PREFIX (např. test -> user/jikl/test)
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

# Vstup: ref-ish string (pro dif, případně base do reb)
# Výstup:
# - env branch -> provede fetch origin <b> a vrátí origin/<b>
# - ref-like (HEAD, origin/main, hash, refs/...) -> vrátí beze změny
# - jinak -> použije with_user_prefix (tzn. branch podle konvence USER_PREFIX)
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

# Soubor bez cesty (/ nebo \) doplní o LEGACY_DIR; prázdný LEGACY_DIR = beze změny
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

# -f / --force: obejde pouze ochranu ENV_BRANCHES; NENÍ to git push --force.
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
git-tools.sh - helper CLI (pro git aliasy)


Příkazy:

  Poznámka (bezpečnost):
    Některé příkazy (např. sw/new/del/sync/up/merg/reb/cp) se před akcí zeptají,
    pokud máš necommitnuté změny, jestli chceš pokračovat.

  br [-asc|--asc] [-desc|--desc] [-rev|--rev]
      Výpis lokálních branchí.
      Default: od nejnovějších (podle committerdate).
      -asc  : řazení podle názvu (A->Z)
      -desc : řazení podle názvu (Z->A)
      -rev  : otočí aktuální řazení (např. nejstarší první)

  com <message>
  com <path> <message>
      Přidá změny a vytvoří commit.
      - 1 argument:
          git add . + git commit -m "<message>"
      - 2 argumenty:
          - pokud <path> obsahuje '/' nebo '\', použije se přímo:
              git add <path>
          - jinak se bere jako legacy shortcut:
              git add LEGACY_DIR/<path>  (prázdný LEGACY_DIR = <path> beze změny)
          V obou případech:
              git commit -m "<message>"

  cp [-f|--force] <commit-hash>
      Před cherry-pick se zeptá, pokud máš necommitnuté změny.
      Cherry-pick zadaného commitu do aktuální branche.
      Cherry-pick na env branch je zakázaný.

  del [-f|--force] <branch>
      Smaže branch (pokud nemá '/', použije USER_PREFIX).
      Env branche (main/dev/...) jsou chráněné a smazání je zakázané.
      Pokud stojíš na cílové branchi, přepne nejdřív na DEFAULT_BASE
      (při dirty worktree se zeptá).

  dif [OPTIONS] [b1] [b2]
      git diff mezi dvěma refy.
      Default: b1=DEFAULT_BASE, b2=current branch
      Env branche se normalizují na origin/<branch> a dělá se fetch.

      OPTIONS (lze libovolně kombinovat s pořadím):
        -n, --name-only      vypíše jen názvy souborů
        -t, --name-status    vypíše A/M/D status + soubory
        -s, --stat           vypíše souhrnnou statistiku
        -l, --log            uloží diff do log souboru
                             (DIFF_LOG_DIR, název: git_diff_YYYYMMDD.log)

  dif-file [OPTIONS] [b1] [b2] <filename|path>
      git diff nad jedním konkrétním souborem.

      Default:
        b1 = DEFAULT_BASE
        b2 = current branch

      Pokud <filename> neobsahuje cestu (/ nebo \) a LEGACY_DIR není prázdný,
      automaticky se doplní prefix:
        LEGACY_DIR/<filename>

      Env branche se normalizují na origin/<branch>
      a před diffem se provede fetch.

      OPTIONS (lze libovolně kombinovat s pořadím):
        -n, --name-only      vypíše jen názvy souborů
        -t, --name-status    vypíše A/M/D status
        -s, --stat           vypíše souhrnnou statistiku
        -l, --log            uloží diff do log souboru
                             (DIFF_LOG_DIR, název: git_diff_file_YYYYMMDD.log)

  done [-f|--force]
      git push -u origin HEAD
      Push na env branchích (main/dev/...) je zakázaný.
      Když push selže (typicky po rebase), nabídne --force-with-lease.

  gone [-f|--force]
      Provede fetch --all --prune a nabídne smazání lokálních branchí,
      které mají upstream ': gone' (byly smazány na remote).
      Env branche přeskočí (s -f je zahrne).

  merg [-f|--force] <branch>
      Před merge se zeptá, pokud máš necommitnuté změny.
      Merge zadané branche do aktuální branche (bez fetch).
      Pokud <branch> nemá '/', použije USER_PREFIX.
      Env branche se nechávají jako lokální názvy.
      Merge do env branche je zakázaný.

  new [OPTIONS] <name> [from_in]
      Vytvoří novou branch

      <name>
      - když <name> obsahuje '/', použije se beze změny (např. pepa/pes)
      - jinak se vytvoří USER_PREFIX<name>

      <from_in>
      - když není <from_in>, vytvoří z DEFAULT_BASE
      - když je <from_in> z ENV_BRANCHES, udělá fetch a založí z ní
      - když <from_in> obsahuje '/', založí se beze změny (např. pepa/pes) (nedělá fetch, předpokládá local branch)
      - jinak se založí z USER_PREFIX/<from_in> (nedělá fetch, předpokládá local branch)

      OPTIONS (lze libovolně kombinovat s pořadím)
        -c, --current     založí z aktuální branche, nedělá fetch!
                          !! nelze zadat <from_in> i -c => skončí chybou
        -f, --force       povolí env branch jako target

      Env branche (main/dev/...) jsou zakázané jako target.

  reb [-f|--force] [base]
      Před rebase se zeptá, pokud máš necommitnuté změny.
      Interaktivní rebase AKTUÁLNÍ branche na:
      - origin/<env base> (pro env base; default je DEFAULT_BASE) + fetch
      - USER_PREFIX/base (pro non-env base)
      Rebase na env branchích (main/dev/...) je zakázaný.

  reb-ai [-f|--force] [base]
  reb-ac [-f|--force] [base]
      Stejné jako reb, ale NEinteraktivně a s automatickým řešením konfliktů:
      - reb-ai = accept incoming (-X theirs) => vyhrají commity AKTUÁLNÍ branche
      - reb-ac = accept current  (-X ours)   => vyhraje base (např. origin/main)
      Pozn.: při rebase je "current" base a "incoming" jsou tvoje commity.
      -X řeší jen obsahové konflikty; modify/delete apod. rebase stejně zastaví.

  st
      Rychlý přehled: git status -sb + posledních 10 commitů.

  sw <branch>
      Před sw se zeptá, pokud máš necommitnuté změny.
      Switch na branch. Pokud <branch> nemá '/', použije USER_PREFIX.
      Env branche (main/dev/...) nechává jako lokální názvy.

  sync <branch>
      Před resetem/switchem se zeptá, pokud máš necommitnuté změny.
      Sync lokální branch na origin/<branch>:
      - fetch origin <branch>
      - když lokální branch neexistuje, vytvoří ji z origin/<branch>
      - reset --hard na origin/<branch>
      - volitelně se zeptá na git clean -fd

  up
      Před rebase/sync se zeptá, pokud máš necommitnuté změny.
      Aktualizuje current branch:
      - pokud je current env branch: provede sync <current> (včetně dotazu na git clean -fd)
      - jinak: fetch origin DEFAULT_BASE + rebase current na origin/DEFAULT_BASE

  ver list [pattern]
      Seznam tagů (nejnovější první).
  ver new <version> [ref] [-m <message>]
      Vytvoří anotovaný tag na HEAD nebo na zadaném commitu/ref.
      Zkratka: ver <version> [ref]. Tag se NEpublikuje automaticky.
  ver show <version>
      Zobrazí detail tagu a commit.
  ver push <version|--all>
      Publikuje tag nebo všechny lokální tagy na origin.
  ver del <version> [--remote]
      Smaže lokální tag; --remote smaže i tag na origin.
      Tagy nejsou branch a nikdy nedostávají USER_PREFIX.

  -f, --force
      U příkazů cp, del, new, done, merg, reb, reb-ai, reb-ac, gone obejde
      ochranu ENV_BRANCHES; NEprovádí automaticky git push --force.


Konfigurace (git-tools.conf, cesta v GITTOOLS_CONFIG_DEFAULT nebo env GITTOOLS_CONFIG;
lze override přes env proměnné):
  USER_PREFIX="user/unknown/"
  ENV_BRANCHES="main dev acc int work"
  DEFAULT_BASE="main"
  DIFF_LOG_DIR="j:/temp"
  LEGACY_DIR=""

Příklady:
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
# Příkazy
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

  # Bezpečnost: env branche nemaž (lokální kopie); pro sync s remote použij sync
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

  # Pokud lokální branch neexistuje, vytvoř ji z origin/$b
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
  # reb-ai [-f] [base] - při rebase je incoming = theirs (přehrávané commity)
  rebase_impl "theirs" "$@"
}

cmd_reb_ac() {
  # reb-ac [-f] [base] - při rebase je current = ours (base)
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

  # 0) Na env branchích rebase zakázat
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

    # vytvoř složku, pokud neexistuje
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

  # poslední argument MUSÍ být soubor / název
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

  # 0) Na env branchích push zakázat
  check_protected "$current" "Pushing"

  echo "git push -u origin HEAD"
  if git push -u origin HEAD; then
    return 0
  fi

  # push selhal – typicky po rebase
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
