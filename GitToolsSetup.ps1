param([string]$ScriptDir)

# Instalace a konfigurace git-tools.sh (spouštět přes GitToolsSetup.cmd)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not $ScriptDir) { $ScriptDir = $PSScriptRoot }
$ScriptDir = $ScriptDir.TrimEnd('\', '/')

$ZdrojSkript = Join-Path $ScriptDir 'git-tools.sh'
$DomovDir    = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$NazevSkriptu = 'git-tools.sh'
$VychoziConf = 'J:/config/git-tools.conf'

$VychoziHodnoty = [ordered]@{
    USER_PREFIX  = 'user/unknown/'
    ENV_BRANCHES = 'main dev acc int work'
    DEFAULT_BASE = 'main'
    DIFF_LOG_DIR = 'j:/temp'
    LEGACY_DIR   = ''
}
$PopisKlicu = @{
    USER_PREFIX  = 'Prefix uživatelských branchí (např. user/jikl/)'
    ENV_BRANCHES = 'Chráněné env branche (oddělené mezerou)'
    DEFAULT_BASE = 'Výchozí base branch'
    DIFF_LOG_DIR = 'Složka pro dif --log'
    LEGACY_DIR   = 'Prefix pro soubory bez cesty (dif-file, com), prázdné = bez prefixu'
}

# alias -> příkaz git-tools.sh
$Aliasy = [ordered]@{}
foreach ($a in 'new','sw','del','com','sync','merg','reb','reb-ai','reb-ac','done','gone','up','dif','dif-file','st','br','cp','ver') { $Aliasy[$a] = $a }
$Aliasy['h'] = 'help'

$RegexConfRadek = '(?m)^GITTOOLS_CONFIG_DEFAULT=.*$'

# =========================
# Pomocné funkce
# =========================
function Write-UnixText([string]$Cesta, [string]$Text) {
    $dir = Split-Path -Parent $Cesta
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # bash nesnese CRLF ani BOM
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Cesta, $Text, (New-Object Text.UTF8Encoding $false))
}

function Read-Text([string]$Cesta) {
    [IO.File]::ReadAllText($Cesta, [Text.Encoding]::UTF8)
}

function Get-InstalovanySkript {
    Join-Path $script:InstalDir $NazevSkriptu
}

function Get-ConfZeSkriptu([string]$Skript) {
    if (-not (Test-Path -LiteralPath $Skript)) { return $null }
    $m = [regex]::Match((Read-Text $Skript), '(?m)^GITTOOLS_CONFIG_DEFAULT="?([^"\r\n]*)"?')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Read-Conf([string]$Cesta) {
    $h = [ordered]@{}
    foreach ($k in $VychoziHodnoty.Keys) { $h[$k] = $null }
    if (-not (Test-Path -LiteralPath $Cesta)) { return $h }
    foreach ($radek in (Read-Text $Cesta) -split "`n") {
        $m = [regex]::Match($radek.TrimEnd("`r"), '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$')
        if (-not $m.Success) { continue }
        $hodnota = $m.Groups[2].Value
        if ($hodnota -match "^'(.*)'$") { $hodnota = $Matches[1] -replace "'\\''", "'" }
        elseif ($hodnota -match '^"(.*)"$') { $hodnota = $Matches[1] }
        $h[$m.Groups[1].Value] = $hodnota
    }
    return $h
}

function Write-Conf([string]$Cesta, $Hodnoty) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('# git-tools.conf - načítá git-tools.sh (bash syntaxe)')
    [void]$sb.AppendLine("# Vygenerováno GitToolsSetup $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    foreach ($k in $VychoziHodnoty.Keys) {
        $v = [string]$Hodnoty[$k]
        [void]$sb.AppendLine("$k='" + ($v -replace "'", "'\''") + "'")
    }
    Write-UnixText $Cesta $sb.ToString()
}

function Read-Hodnota([string]$Popis, [string]$Aktualni) {
    $odpoved = Read-Host "$Popis [$Aktualni] (Enter = ponechat, '-' = prázdné)"
    if ($odpoved -eq '') { return $Aktualni }
    if ($odpoved -eq '-') { return '' }
    return $odpoved
}

function Read-AnoNe([string]$Otazka) {
    $odpoved = Read-Host "$Otazka [a/N]"
    return ($odpoved -match '^(a|ano|y|yes)$')
}

function Edit-Hodnoty($Hodnoty) {
    $nove = [ordered]@{}
    foreach ($k in $VychoziHodnoty.Keys) {
        $akt = if ($null -ne $Hodnoty[$k]) { [string]$Hodnoty[$k] } else { $VychoziHodnoty[$k] }
        $nove[$k] = Read-Hodnota "$k - $($PopisKlicu[$k])" $akt
    }
    return $nove
}

function Set-ConfVeSkriptu([string]$Skript, [string]$ConfCesta) {
    $text = Read-Text $Skript
    if ($text -notmatch $RegexConfRadek) { throw "V $Skript chybí řádek GITTOOLS_CONFIG_DEFAULT=" }
    $text = [regex]::Replace($text, $RegexConfRadek, "GITTOOLS_CONFIG_DEFAULT=`"$ConfCesta`"")
    Write-UnixText $Skript $text
}

function Get-AliasPrikaz([string]$Skript, [string]$Prikaz) {
    $dir = (Split-Path -Parent $Skript).TrimEnd('\', '/')
    if ($dir -ieq $DomovDir.TrimEnd('\', '/')) {
        $cesta = '$HOME/' + $NazevSkriptu
    } else {
        $cesta = $Skript -replace '\\', '/'
    }
    return "!$cesta $Prikaz"
}

function Get-GitAlias([string]$Nazev) {
    $v = & git config --global --get "alias.$Nazev"
    if ($LASTEXITCODE -ne 0) { return $null }
    return $v
}

# =========================
# Akce menu
# =========================
function Show-Nastaveni {
    $skript = Get-InstalovanySkript
    $gitconfig = Join-Path $DomovDir '.gitconfig'
    Write-Host ''
    Write-Host '--- Umístění ---'
    Write-Host "Zdrojový skript:      $ZdrojSkript"
    Write-Host ("Instalovaný skript:   $skript " + $(if (Test-Path -LiteralPath $skript) { '(existuje)' } else { '(NEEXISTUJE)' }))
    Write-Host ("Conf ve skriptu:      " + $(if ($c = Get-ConfZeSkriptu $skript) { $c } else { '-' }))
    Write-Host ("Conf (aktuální):      $script:ConfCesta " + $(if (Test-Path -LiteralPath $script:ConfCesta) { '(existuje)' } else { '(NEEXISTUJE)' }))
    Write-Host ("Env GITTOOLS_CONFIG:  " + $(if ($env:GITTOOLS_CONFIG) { $env:GITTOOLS_CONFIG } else { '-' }))
    Write-Host ("Globální .gitconfig:  $gitconfig " + $(if (Test-Path -LiteralPath $gitconfig) { '(existuje)' } else { '(NEEXISTUJE)' }))

    Write-Host ''
    Write-Host '--- Hodnoty v git-tools.conf ---'
    $h = Read-Conf $script:ConfCesta
    foreach ($k in $VychoziHodnoty.Keys) {
        if ($null -ne $h[$k]) { $zobraz = "'$($h[$k])'" } else { $zobraz = "(není v conf, fallback '$($VychoziHodnoty[$k])')" }
        Write-Host ('{0,-13} = {1}' -f $k, $zobraz)
    }

    Write-Host ''
    Write-Host '--- Aliasy v .gitconfig ---'
    foreach ($a in $Aliasy.Keys) {
        $v = Get-GitAlias $a
        if ($null -eq $v) { $v = '(nenastaven)' }
        Write-Host ('{0,-9} = {1}' -f $a, $v)
    }
}

function Edit-Nastaveni {
    if (-not (Test-Path -LiteralPath $script:ConfCesta)) {
        Write-Host "Conf $script:ConfCesta neexistuje - použij volbu 3 (vytvořit)."
        return
    }
    $nove = Edit-Hodnoty (Read-Conf $script:ConfCesta)
    Write-Conf $script:ConfCesta $nove
    Write-Host "Uloženo: $script:ConfCesta"
}

function New-Conf {
    $cesta = Read-Hodnota 'Cesta k git-tools.conf' $script:ConfCesta
    if (-not $cesta) { Write-Host 'Cesta nesmí být prázdná.'; return }
    $cesta = $cesta -replace '\\', '/'
    $vychozi = $VychoziHodnoty
    if (Test-Path -LiteralPath $cesta) {
        if (-not (Read-AnoNe "Soubor $cesta už existuje. Přepsat?")) { return }
        $vychozi = Read-Conf $cesta
    }
    $nove = Edit-Hodnoty $vychozi
    Write-Conf $cesta $nove
    $script:ConfCesta = $cesta
    Write-Host "Vytvořeno: $cesta"

    $skript = Get-InstalovanySkript
    if (Test-Path -LiteralPath $skript) {
        Set-ConfVeSkriptu $skript $cesta
        Write-Host "Cesta ke conf nastavena v $skript"
    } else {
        Write-Host 'git-tools.sh zatím není nainstalovaný - cesta se nastaví při instalaci (volba 4).'
    }
}

function Install-Skript {
    if (-not (Test-Path -LiteralPath $ZdrojSkript)) { Write-Host "Zdroj $ZdrojSkript neexistuje."; return }
    $dir = Read-Hodnota "Cílová složka (globální .gitconfig je v $DomovDir)" $script:InstalDir
    if (-not $dir) { Write-Host 'Složka nesmí být prázdná.'; return }
    $cil = Join-Path $dir $NazevSkriptu
    if ((Test-Path -LiteralPath $cil) -and -not (Read-AnoNe "$cil už existuje. Přepsat?")) { return }

    $conf = Read-Hodnota 'Cesta k git-tools.conf, kterou skript načte' $script:ConfCesta
    $conf = $conf -replace '\\', '/'
    if (-not (Test-Path -LiteralPath $conf)) { Write-Host "UPOZORNĚNÍ: $conf neexistuje - skript použije fallback hodnoty (vytvoř volbou 3)." }

    $text = Read-Text $ZdrojSkript
    if ($text -notmatch $RegexConfRadek) { throw "Ve zdroji chybí řádek GITTOOLS_CONFIG_DEFAULT=" }
    $text = [regex]::Replace($text, $RegexConfRadek, "GITTOOLS_CONFIG_DEFAULT=`"$conf`"")
    Write-UnixText $cil $text

    $script:InstalDir = $dir
    $script:ConfCesta = $conf
    Write-Host "Nainstalováno: $cil (conf: $conf)"
}

function Set-Aliasy {
    $skript = Get-InstalovanySkript
    if (-not (Test-Path -LiteralPath $skript)) { Write-Host "$skript neexistuje - nejdřív instalace (volba 4)."; return }
    if ($skript -match '\s') { Write-Host "Cesta $skript obsahuje mezeru - aliasy nelze zapsat, nainstaluj jinam."; return }

    Write-Host ''
    $zmeny = [ordered]@{}
    foreach ($a in $Aliasy.Keys) {
        $novy = Get-AliasPrikaz $skript $Aliasy[$a]
        $stary = Get-GitAlias $a
        if ($stary -eq $novy) { continue }
        $zmeny[$a] = $novy
        if ($null -eq $stary) { Write-Host ('  + {0,-9} = {1}' -f $a, $novy) }
        else { Write-Host ('  ~ {0,-9} = {1}   (dosud: {2})' -f $a, $novy, $stary) }
    }
    if ($zmeny.Count -eq 0) { Write-Host 'Všechny aliasy už jsou nastavené.'; return }
    if (-not (Read-AnoNe 'Zapsat tyto aliasy do globálního .gitconfig?')) { return }

    foreach ($a in $zmeny.Keys) {
        & git config --global "alias.$a" $zmeny[$a]
        if ($LASTEXITCODE -ne 0) { Write-Host "CHYBA při zápisu aliasu $a" }
    }
    Write-Host "Zapsáno aliasů: $($zmeny.Count)"
}

# =========================
# Hlavní smyčka
# =========================
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host 'git není v PATH.'; exit 1 }

$script:InstalDir = $DomovDir
$script:ConfCesta = Get-ConfZeSkriptu (Get-InstalovanySkript)
if (-not $script:ConfCesta) { $script:ConfCesta = Get-ConfZeSkriptu $ZdrojSkript }
if (-not $script:ConfCesta) { $script:ConfCesta = $VychoziConf }

while ($true) {
    Write-Host ''
    Write-Host '===== git-tools setup ====='
    Write-Host '1) Zobrazit aktuální nastavení'
    Write-Host '2) Změnit nastavení (git-tools.conf)'
    Write-Host '3) Vytvořit git-tools.conf a nastavit jeho cestu v git-tools.sh'
    Write-Host '4) Nainstalovat git-tools.sh (ke .gitconfig)'
    Write-Host '5) Zapsat aliasy do .gitconfig'
    Write-Host '0) Konec'
    $volba = Read-Host 'Volba'
    try {
        switch ($volba) {
            '1' { Show-Nastaveni }
            '2' { Edit-Nastaveni }
            '3' { New-Conf }
            '4' { Install-Skript }
            '5' { Set-Aliasy }
            '0' { return }
            default { Write-Host 'Neplatná volba.' }
        }
    } catch {
        Write-Host "CHYBA: $($_.Exception.Message)"
    }
}
