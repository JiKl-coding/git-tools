# git-tools

Small bash helper for everyday Git workflow, designed as a backend for git aliases (`git new`, `git sw`, `git done`, ...). It adds a user-branch naming convention (`USER_PREFIX`), protection of env branches (`main`, `dev`, ...) and confirmation prompts before actions that could lose uncommitted changes.

## Repository contents

| File | Description |
|---|---|
| `git-tools.sh` | The tool itself (bash). |
| `GitToolsSetup.cmd` | Setup launcher for Windows. |
| `GitToolsSetup.ps1` | Interactive menu: configuration, script installation, writing aliases to `~/.gitconfig`. |

## Requirements

- Git with bash (e.g. Git for Windows / Git Bash)
- Windows PowerShell (for setup)

## Installation

1. Run `GitToolsSetup.cmd`.
2. In the menu, choose in order:
   - **3** - create `git-tools.conf` and set its path in the script,
   - **4** - install `git-tools.sh` (the default target is the home folder, next to `.gitconfig`),
   - **5** - write the aliases to the global `.gitconfig`.
3. Option **1** shows the current state, option **2** lets you change the configuration values.

Aliases cannot be written if the script path contains a space; in that case install the script to a different folder.

## Configuration

The script loads `git-tools.conf` (bash syntax). The path is resolved as follows:

1. the `GITTOOLS_CONFIG` environment variable,
2. `GITTOOLS_CONFIG_DEFAULT` in the script (rewritten by the setup during installation; default `J:/config/git-tools.conf`).

Values from the config can be overridden with environment variables.

| Variable | Default | Meaning |
|---|---|---|
| `USER_PREFIX` | `user/unknown/` | Prefix of user branches. |
| `ENV_BRANCHES` | `main dev acc int work` | Protected env branches (space-separated). |
| `DEFAULT_BASE` | `main` | Default base branch. |
| `DIFF_LOG_DIR` | `j:/temp` | Folder for `dif --log`. |
| `LEGACY_DIR` | *(empty)* | Prefix for files given without a path (`dif-file`, `com`). |

## Branch naming convention

- A name containing `/` (e.g. `pepa/pes`) is used unchanged.
- A name without `/` gets `USER_PREFIX` (e.g. `test` -> `user/jikl/test`).
- Env branches stay as local names; `dif` and `reb` normalize them to `origin/<branch>` and run `fetch`.
- Tags (`ver`) never get the prefix.

## Commands

Usage: `git <alias> ...` or directly `~/git-tools.sh <command> ...`. Help: `git h`.

| Command | Description |
|---|---|
| `st` | `git status -sb` + the last 10 commits. |
| `br [-asc\|-desc] [-rev]` | Local branches; default sort is by last commit date. |
| `sw <branch>` | Switches to a branch. |
| `new [-c] [-f] <name> [from]` | Creates a branch from `DEFAULT_BASE`, from `from`, or (`-c`) from the current one. |
| `del [-f] <branch>` | Deletes a local branch. |
| `com <message>` / `com <path> <message>` | `git add` + `git commit`. |
| `cp [-f] <hash>` | Cherry-picks onto the current branch. |
| `merg [-f] <branch>` | Merges into the current branch (no fetch). |
| `reb [-f] [base]` | Interactive rebase onto base. |
| `reb-ai [-f] [base]` | Non-interactive rebase, conflicts won by commits of the current branch (`-X theirs`). |
| `reb-ac [-f] [base]` | Non-interactive rebase, conflicts won by the base (`-X ours`). |
| `sync <branch>` | `fetch` + `reset --hard` to `origin/<branch>`, optionally `git clean -fd`. |
| `up` | Env branch: `sync`. Others: `fetch` + rebase onto `origin/DEFAULT_BASE`. |
| `done [-f]` | `git push -u origin HEAD`; offers `--force-with-lease` on failure. |
| `gone [-f]` | `fetch --all --prune` and deletes local branches whose upstream is `: gone`. |
| `dif [-n\|-t\|-s] [-l] [b1] [b2]` | Diff of two refs (default `DEFAULT_BASE` vs. current branch). |
| `dif-file [-n\|-t\|-s] [-l] [b1] [b2] <file>` | Diff of a single file. |
| `ver list\|new\|show\|push\|del` | Management of annotated tags. |

### `dif` / `dif-file` options

- `-n`, `--name-only` - file names only
- `-t`, `--name-status` - A/M/D status
- `-s`, `--stat` - summary statistics
- `-l`, `--log` - writes the output to `DIFF_LOG_DIR` (`git_diff_YYYYMMDD.log`, or `git_diff_file_YYYYMMDD.log`)

### Version management (`ver`)

```
git ver list [pattern]                  # tags, newest first
git ver new <version> [ref] [-m <msg>]  # annotated tag (shortcut: git ver <version> [ref])
git ver show <version>
git ver push <version|--all>            # tags are not published automatically
git ver del <version> [--remote]
```

## Safety behavior

- `new`, `del`, `merg`, `reb*`, `cp`, `done` and `gone` refuse to work with env branches.
- `-f` / `--force` only bypasses this protection. It does not run `git push --force`.
- `sw`, `new`, `del`, `sync`, `up`, `merg`, `reb*` and `cp` ask for confirmation if you have uncommitted changes.
- `sync` performs `reset --hard`; `git clean -fd` is always confirmed separately.

## Examples

```
git new pepa/pes          # new branch from main
git new feature -c        # from the current branch
git up                    # rebase onto origin/main
git com "fix: typo"
git done                  # push the current branch
git dif dev -n -l         # names of changed files vs. origin/dev into a log
git gone                  # clean up branches deleted on the remote
git ver new v1.2.0 -m "Release 1.2.0"
```
