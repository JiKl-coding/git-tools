# git-tools

Malý bash helper pro každodenní Git workflow, určený jako backend pro git aliasy (`git new`, `git sw`, `git done`, ...). Přidává konvenci uživatelských branchí (`USER_PREFIX`), ochranu env branchí (`main`, `dev`, ...) a potvrzení před akcemi, které by mohly přijít o necommitnuté změny.

## Obsah repozitáře

| Soubor | Popis |
|---|---|
| `git-tools.sh` | Vlastní nástroj (bash). |
| `GitToolsSetup.cmd` | Spouštěč setupu pro Windows. |
| `GitToolsSetup.ps1` | Interaktivní menu: konfigurace, instalace skriptu, zápis aliasů do `~/.gitconfig`. |

## Požadavky

- Git s bashem (např. Git for Windows / Git Bash)
- Windows PowerShell (pro setup)

## Instalace

1. Spusť `GitToolsSetup.cmd`.
2. V menu postupně zvol:
   - **3** - vytvoření `git-tools.conf` a nastavení jeho cesty ve skriptu,
   - **4** - instalace `git-tools.sh` (výchozí cíl je domovská složka, vedle `.gitconfig`),
   - **5** - zápis aliasů do globálního `.gitconfig`.
3. Volba **1** zobrazí aktuální stav, volba **2** umožní změnit hodnoty v konfiguraci.

Aliasy nelze zapsat, pokud cesta ke skriptu obsahuje mezeru; v takovém případě skript nainstaluj do jiné složky.

## Konfigurace

Skript načítá `git-tools.conf` (bash syntaxe). Cesta se hledá takto:

1. proměnná prostředí `GITTOOLS_CONFIG`,
2. `GITTOOLS_CONFIG_DEFAULT` ve skriptu (přepisuje ji setup při instalaci; výchozí `J:/config/git-tools.conf`).

Hodnoty z konfigurace lze přepsat proměnnými prostředí.

| Proměnná | Výchozí | Význam |
|---|---|---|
| `USER_PREFIX` | `user/unknown/` | Prefix uživatelských branchí. |
| `ENV_BRANCHES` | `main dev acc int work` | Chráněné env branche (oddělené mezerou). |
| `DEFAULT_BASE` | `main` | Výchozí base branch. |
| `DIFF_LOG_DIR` | `j:/temp` | Složka pro `dif --log`. |
| `LEGACY_DIR` | *(prázdné)* | Prefix pro soubory zadané bez cesty (`dif-file`, `com`). |

## Konvence názvů branchí

- Název s `/` (např. `pepa/pes`) se použije beze změny.
- Název bez `/` dostane `USER_PREFIX` (např. `test` -> `user/jikl/test`).
- Env branche zůstávají lokálními názvy; při `dif` a `reb` se normalizují na `origin/<branch>` a provede se `fetch`.
- Tagy (`ver`) prefix nikdy nedostávají.

## Příkazy

Volání: `git <alias> ...` nebo přímo `~/git-tools.sh <příkaz> ...`. Nápověda: `git h`.

| Příkaz | Popis |
|---|---|
| `st` | `git status -sb` + posledních 10 commitů. |
| `br [-asc\|-desc] [-rev]` | Lokální branche; výchozí řazení podle data posledního commitu. |
| `sw <branch>` | Přepne na branch. |
| `new [-c] [-f] <name> [from]` | Vytvoří branch z `DEFAULT_BASE`, z `from` nebo (`-c`) z aktuální. |
| `del [-f] <branch>` | Smaže lokální branch. |
| `com <message>` / `com <path> <message>` | `git add` + `git commit`. |
| `cp [-f] <hash>` | Cherry-pick do aktuální branche. |
| `merg [-f] <branch>` | Merge do aktuální branche (bez fetch). |
| `reb [-f] [base]` | Interaktivní rebase na base. |
| `reb-ai [-f] [base]` | Neinteraktivní rebase, konflikty vyhrají commity aktuální branche (`-X theirs`). |
| `reb-ac [-f] [base]` | Neinteraktivní rebase, konflikty vyhraje base (`-X ours`). |
| `sync <branch>` | `fetch` + `reset --hard` na `origin/<branch>`, volitelně `git clean -fd`. |
| `up` | Env branch: `sync`. Ostatní: `fetch` + rebase na `origin/DEFAULT_BASE`. |
| `done [-f]` | `git push -u origin HEAD`; při selhání nabídne `--force-with-lease`. |
| `gone [-f]` | `fetch --all --prune` a smazání lokálních branchí s upstreamem `: gone`. |
| `dif [-n\|-t\|-s] [-l] [b1] [b2]` | Diff dvou refů (výchozí `DEFAULT_BASE` vs. aktuální branch). |
| `dif-file [-n\|-t\|-s] [-l] [b1] [b2] <file>` | Diff jednoho souboru. |
| `ver list\|new\|show\|push\|del` | Správa anotovaných tagů. |

### Volby `dif` / `dif-file`

- `-n`, `--name-only` - jen názvy souborů
- `-t`, `--name-status` - stav A/M/D
- `-s`, `--stat` - souhrnná statistika
- `-l`, `--log` - uloží výstup do `DIFF_LOG_DIR` (`git_diff_YYYYMMDD.log`, resp. `git_diff_file_YYYYMMDD.log`)

### Správa verzí (`ver`)

```
git ver list [pattern]                  # tagy, nejnovější první
git ver new <version> [ref] [-m <msg>]  # anotovaný tag (zkratka: git ver <version> [ref])
git ver show <version>
git ver push <version|--all>            # tagy se nepublikují automaticky
git ver del <version> [--remote]
```

## Bezpečnostní chování

- `new`, `del`, `merg`, `reb*`, `cp`, `done` a `gone` odmítnou práci s env branchemi.
- `-f` / `--force` obejde pouze tuto ochranu. Nespouští `git push --force`.
- `sw`, `new`, `del`, `sync`, `up`, `merg`, `reb*` a `cp` se zeptají, pokud máš necommitnuté změny.
- `sync` provádí `reset --hard`; `git clean -fd` je vždy zvlášť potvrzovaný.

## Příklady

```
git new pepa/pes          # nová branch z main
git new feature -c        # z aktuální branche
git up                    # rebase na origin/main
git com "fix: typo"
git done                  # push aktuální branche
git dif dev -n -l         # názvy změněných souborů proti origin/dev do logu
git gone                  # úklid branchí smazaných na remote
git ver new v1.2.0 -m "Release 1.2.0"
```
