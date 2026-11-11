# Read-only klient pro Odoo pres JSON-RPC. Dot-source: . "$PSScriptRoot\OdooQ.ps1"
#
# Prihlasovaci udaje se ctou v poradi:
#   1. promenne prostredi (ODOO_URL, ODOO_USER, ODOO_API_KEY, ODOO_DB)
#   2. soubor urceny promennou ODOO_ENV_FILE
#   3. ~/.notino-priplatky/.odoo.env
#   4. ~/.odoo.env  (starsi umisteni)
# Hodnoty se nikdy nevypisuji.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:ReadOnlyMethods = @(
    'search_read', 'read', 'search', 'search_count', 'fields_get',
    'read_group', 'name_search', 'default_get'
)
$script:Odoo = $null

function Format-Pct {
    # 50.0 -> "50", 12.5 -> "12.5". JSON z Pythonu nese floaty, bez tohohle
    # by se v textu objevovalo "50.0 %".
    param($Value)
    return ('{0:0.##}' -f [double]$Value)
}

function Read-EnvFile {
    param([string]$Path)
    $out = @{}
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^(?i)export\s+(.*)$') { $line = $Matches[1].Trim() }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $line.Substring(0, $i).Trim()
        $v = $line.Substring($i + 1).Trim()
        if ($v.Length -ge 2) {
            $f = $v[0]; $l = $v[$v.Length - 1]
            if (($f -eq '"' -and $l -eq '"') -or ($f -eq "'" -and $l -eq "'")) {
                $v = $v.Substring(1, $v.Length - 2)
            }
        }
        $out[$k] = $v
    }
    return $out
}

function Get-BaseUrl {
    # Vrati jen scheme://host. Z adresy z prohlizece odrizne /odoo nebo /web -
    # JSON-RPC endpoint je vzdy na koreni.
    param([string]$Raw)
    $r = ($Raw, '')[[string]::IsNullOrWhiteSpace($Raw)].Trim().TrimEnd('/')
    if ($r -eq '') { return '' }
    if ($r -notmatch '://') { $r = 'https://' + $r }
    try { $u = [uri]$r } catch { return '' }
    return ('{0}://{1}' -f $u.Scheme, $u.Authority)
}

function Get-OdooConfig {
    if ($script:Odoo) { return $script:Odoo }

    $vals = @{}
    foreach ($k in 'ODOO_URL', 'ODOO_USER', 'ODOO_API_KEY', 'ODOO_DB') {
        $v = [Environment]::GetEnvironmentVariable($k)
        if (-not [string]::IsNullOrWhiteSpace($v)) { $vals[$k] = $v }
    }

    $candidates = @()
    $envFile = [Environment]::GetEnvironmentVariable('ODOO_ENV_FILE')
    if (-not [string]::IsNullOrWhiteSpace($envFile)) { $candidates += $envFile }
    # Prednostne slozka dovednosti - lezi v ni i data\, takze staci povolit
    # pristup k jedne slozce misto cele domovske.
    $candidates += (Join-Path $HOME '.notino-priplatky\.odoo.env')
    $candidates += (Join-Path $HOME '.odoo.env')

    $stray = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
    if (Test-Path -LiteralPath $stray) {
        Write-Warning "$stray leží ve složce s dovedností, která se sdílí s kolegy. Přesuň ho mimo ni (např. do ~/.odoo.env)."
        $candidates += $stray
    }

    $source = 'žádný'
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            foreach ($kv in (Read-EnvFile -Path $p).GetEnumerator()) {
                if (-not $vals.ContainsKey($kv.Key)) { $vals[$kv.Key] = $kv.Value }
            }
            $source = $p
            break
        }
    }

    $missing = @()
    foreach ($k in 'ODOO_URL', 'ODOO_USER', 'ODOO_API_KEY') {
        if ([string]::IsNullOrWhiteSpace($vals[$k])) { $missing += $k }
    }
    if ($missing.Count -gt 0) {
        throw ("Chybí: {0}`nNastav je v prostředí nebo v souboru (ODOO_ENV_FILE / ~/.odoo.env).`nNačtený soubor: {1}" -f ($missing -join ', '), $source)
    }

    $script:Odoo = [pscustomobject]@{
        Url = Get-BaseUrl -Raw $vals['ODOO_URL']
        User = $vals['ODOO_USER']
        Key = $vals['ODOO_API_KEY']
        Db = $vals['ODOO_DB']
        Uid = $null
        EnvFile = $source
    }
    return $script:Odoo
}

function Invoke-HttpJson {
    # Invoke-RestMethod v PS 5.1 umi prohodit kodovani, kdyz server neposle charset.
    # Ctu proto bajty a dekoduji je sam jako UTF-8.
    param([string]$Uri, $Body)
    # Pozor: $Body | ConvertTo-Json rozbali pole v pipeline a vnorene domeny
    # prijdou do Odoo rozsypane. -InputObject to nedela.
    # Telo obsahuje API klic, proto se nikdy nevypisuje.
    $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $resp = Invoke-WebRequest -Uri $Uri -Method Post -Body $bytes `
        -ContentType 'application/json' -UseBasicParsing -TimeoutSec 180
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    return $text | ConvertFrom-Json
}

function New-OdooDomain {
    <#
      Slozi domenu tak, aby prezila ConvertTo-Json. PowerShell rad splaskne
      jednoprvkove vnorene pole, proto se kazda podminka pretypuje na [object[]].
      Pouziti: New-OdooDomain @(,@('cp_is_notino','=',$true))
               New-OdooDomain @( @('a','=',1), @('b','>=','2026-01-01') )
    #>
    param([array]$Conditions)
    $out = New-Object System.Collections.ArrayList
    foreach ($c in $Conditions) { [void]$out.Add([object[]]$c) }
    return , [object[]]$out.ToArray()
}

function New-PositionalArgs {
    <#
      Z domeny (nebo jineho pole) udela pole pozicnich argumentu o jednom prvku.
      @($domena) by pole rozbalilo a podminky by do Odoo prisly jako samostatne
      argumenty - proto ten vnoreny ArrayList.
    #>
    param([array]$First)
    $a = New-Object System.Collections.ArrayList
    [void]$a.Add([object[]]$First)
    # Uvodni carka je nutna: funkce vracejici pole ho v pipeline rozbali
    # a vnoreni by se ztratilo.
    return , [object[]]$a.ToArray()
}

function Invoke-OdooRpc {
    param([string]$Service, [string]$Method, [array]$Arguments)
    $cfg = Get-OdooConfig
    $body = @{
        jsonrpc = '2.0'; method = 'call'; id = 1
        params = @{ service = $Service; method = $Method; args = $Arguments }
    }
    $res = Invoke-HttpJson -Uri ($cfg.Url + '/jsonrpc') -Body $body
    if ($res.PSObject.Properties.Name -contains 'error' -and $res.error) {
        $msg = $res.error.data.message
        if (-not $msg) { $msg = $res.error.message }
        throw "Odoo: $msg"
    }
    return $res.result
}

function Get-OdooDatabases {
    $cfg = Get-OdooConfig
    if ($cfg.Db) { return @($cfg.Db) }
    $list = @()
    try { $list = @(Invoke-OdooRpc -Service 'db' -Method 'list' -Arguments @()) }
    catch { Write-Verbose "db.list nedostupné: $_" }
    if ($list.Count -eq 0) {
        try {
            $r = Invoke-HttpJson -Uri ($cfg.Url + '/web/database/list') `
                 -Body @{ jsonrpc = '2.0'; method = 'call'; params = @{} }
            $list = @($r.result)
        } catch { Write-Verbose "/web/database/list nedostupné: $_" }
    }
    if ($list.Count -eq 0) {
        $host0 = ([uri]$cfg.Url).Host
        $list = @($host0.Split('.')[0], $host0)
    }
    return $list
}

function Connect-Odoo {
    $cfg = Get-OdooConfig
    if ($cfg.Uid) { return $cfg }
    $errors = @()
    foreach ($db in (Get-OdooDatabases)) {
        try {
            $uid = Invoke-OdooRpc -Service 'common' -Method 'authenticate' `
                   -Arguments @($db, $cfg.User, $cfg.Key, @{})
            if ($uid) { $cfg.Db = $db; $cfg.Uid = $uid; return $cfg }
            $errors += "${db}: přihlášení odmítnuto"
        } catch { $errors += "${db}: $($_.Exception.Message)" }
    }
    throw ("Nepodařilo se přihlásit. Zkoušeno:`n  " + ($errors -join "`n  "))
}

function Invoke-OdooCall {
    <#
      Read-only volani execute_kw. Zapisove metody odmita.
      -Arguments je pole pozicnich argumentu, -Kwargs hashtable pojmenovanych.
    #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Method,
        [object[]]$Positional = @(),
        [hashtable]$Kwargs = @{}
    )
    if ($script:ReadOnlyMethods -notcontains $Method) {
        throw "odmítnuta zápisová metoda: $Method"
    }
    $cfg = Connect-Odoo
    $res = Invoke-OdooRpc -Service 'object' -Method 'execute_kw' `
           -Arguments @($cfg.Db, $cfg.Uid, $cfg.Key, $Model, $Method, $Positional, $Kwargs)
    return $res
}

function Invoke-OdooSearchRead {
    param(
        [Parameter(Mandatory)][string]$Model,
        [array]$Domain = @(),
        [string[]]$Fields,
        [int]$Limit = 0,
        [string]$Order,
        [hashtable]$Context
    )
    $kw = @{}
    if ($Fields) { $kw['fields'] = $Fields }
    if ($Limit -gt 0) { $kw['limit'] = $Limit }
    if ($Order) { $kw['order'] = $Order }
    if ($Context) { $kw['context'] = $Context }
    return @(Invoke-OdooCall -Model $Model -Method 'search_read' `
             -Positional (New-PositionalArgs $Domain) -Kwargs $kw)
}

function Invoke-OdooSearchCount {
    param([Parameter(Mandatory)][string]$Model, [array]$Domain = @())
    return Invoke-OdooCall -Model $Model -Method 'search_count' `
           -Positional (New-PositionalArgs $Domain) -Kwargs @{}
}

function Invoke-OdooFieldsGet {
    param([Parameter(Mandatory)][string]$Model, [string[]]$Only)
    $kw = @{ attributes = @('string', 'type', 'relation') }
    $pos = New-PositionalArgs (@(), $Only)[[bool]$Only]
    return Invoke-OdooCall -Model $Model -Method 'fields_get' -Positional $pos -Kwargs $kw
}

function Get-OdooWhoAmI {
    $cfg = Connect-Odoo
    return [pscustomobject]@{
        db = $cfg.Db; uid = $cfg.Uid
        host = ([uri]$cfg.Url).Host; env_file = $cfg.EnvFile
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    (Get-OdooWhoAmI) | ConvertTo-Json -Compress
}
