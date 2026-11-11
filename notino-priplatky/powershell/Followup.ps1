<#
  Navazna kontrola: udelali spravci zakazek opravu, nebo ne?

    .\Followup.ps1 -Save  -Json vysledek.json -Channel C4CKL4D37 -Ts 1793964181.441199
    .\Followup.ps1 -Check -SlackText

  Snimky zamerne NElezi ve slozce s dovednosti - ta muze existovat ve vic kopiich
  a pri aktualizaci se prepisuje. Drzi se v ~/.notino-priplatky/data,
  prepsat lze promennou NOTINO_DATA_DIR.
  Vuci Odoo READ-ONLY.
#>
param(
    [switch]$Save,
    [switch]$Check,
    [string]$Json,
    [string]$Channel,
    [string]$Ts,
    [string]$File,
    [switch]$SlackText
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\OdooQ.ps1"

$SkillRoot = Split-Path -Parent $PSScriptRoot
$DataDir = $env:NOTINO_DATA_DIR
if (-not $DataDir) { $DataDir = Join-Path $HOME '.notino-priplatky\data' }

function Get-Cfg {
    Get-Content -LiteralPath (Join-Path $SkillRoot 'scripts\fields.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-LatestSnapshot {
    if (-not (Test-Path -LiteralPath $DataDir)) { return $null }
    $f = @(Get-ChildItem -LiteralPath $DataDir -Filter '*.json' | Sort-Object Name)
    if ($f.Count -eq 0) { return $null }
    return $f[-1].FullName
}

function Format-Tag {
    param($Item)
    $o = $Item.owner
    if ($o -and $o.slack_id) { return '<@' + $o.slack_id + '>' }
    if ($o -and $o.name) { return [string]$o.name }
    return 'správce neznámý'
}

function Get-CurrentState {
    # Aktualni priplatky na zakaznickych produktech dane zakazky, nebo $null.
    param($Cfg, [string]$JobNo)
    $jd = New-OdooDomain @( ,@($Cfg.job_no_field, '=', $JobNo) )
    $jobs = Invoke-OdooSearchRead -Model $Cfg.job_model -Domain $jd -Fields @('id') -Limit 1
    if (@($jobs).Count -eq 0) { return $null }
    $conds = New-Object System.Collections.ArrayList
    [void]$conds.Add([object[]]@($Cfg.link_field, '=', [int]$jobs[0].id))
    foreach ($c in $Cfg.customer_product_filter) { [void]$conds.Add([object[]]$c) }
    $lines = Invoke-OdooSearchRead -Model $Cfg.product_model -Domain (New-OdooDomain $conds.ToArray()) `
             -Fields @($Cfg.surcharge_field)
    $vals = @()
    foreach ($l in $lines) {
        $v = $l.($Cfg.surcharge_field); if (-not $v) { $v = 0 }
        $vals += [math]::Round([double]$v, 2)
    }
    return , @($vals | Sort-Object -Unique)
}

function Compare-NumberLists {
    param($A, $B)
    $x = @($A); $y = @($B)
    if ($x.Count -ne $y.Count) { return $false }
    for ($i = 0; $i -lt $x.Count; $i++) {
        if ([double]$x[$i] -ne [double]$y[$i]) { return $false }
    }
    return $true
}

# ------------------------------------------------------------------ save

if ($Save) {
    if (-not $Json) { throw 'Chybí -Json s výsledkem kontroly.' }
    $res = Get-Content -LiteralPath $Json -Raw -Encoding UTF8 | ConvertFrom-Json
    $items = @($res.rows | Where-Object { $_.verdict -ne 'OK' })
    $snap = [pscustomobject]@{
        reported_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        period = @($res.start, $res.end)
        slack_channel = $Channel
        slack_ts = $Ts
        items = $items
    }
    if (-not (Test-Path -LiteralPath $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    }
    $path = Join-Path $DataDir ("hlaseni_{0}_{1}.json" -f $res.start, $res.end)
    ConvertTo-Json -InputObject $snap -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Snimek ulozen: $path"
    Write-Host ("  polozek: {0}" -f $items.Count)
    foreach ($i in $items) {
        $own = '?'; if ($i.owner) { $own = $i.owner.name }
        Write-Host ("   {0,-8} {1} -> {2}%   spravce: {3}" -f `
            $i.job_no, (($i.actual | ForEach-Object { (Format-Pct $_) + '%' }) -join ', '), $i.expected, $own)
    }
    return
}

# ----------------------------------------------------------------- check

if (-not $Check) { throw 'Zadej -Save nebo -Check.' }

$path = $File
if (-not $path) { $path = Get-LatestSnapshot }
if (-not $path) { throw "Žádný snímek v $DataDir - spusť nejdřív -Save." }

$snap = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ("Snimek: {0}" -f (Split-Path -Leaf $path))
Write-Host ("Nahlaseno: {0}  |  obdobi {1}..{2}" -f $snap.reported_at, $snap.period[0], $snap.period[1])
Write-Host ''

$cfg = Get-Cfg
$fixed = @(); $pending = @(); $other = @()

foreach ($it in @($snap.items)) {
    $now = Get-CurrentState -Cfg $cfg -JobNo $it.job_no
    if ($null -eq $now) {
        $other += , @($it, 'zakazka v Odoo nenalezena', $now)
    } elseif (Compare-NumberLists $now $it.actual) {
        $pending += , @($it, 'beze zmeny', $now)
    } elseif ((@($now).Count -eq 1) -and ([double]@($now)[0] -eq [double]$it.expected)) {
        $fixed += , @($it, ("opraveno na {0}%" -f (Format-Pct $it.expected)), $now)
    } else {
        $other += , @($it, ("zmeneno na {0}, ocekavano {1}%" -f `
            ((@($now) | ForEach-Object { (Format-Pct $_) + '%' }) -join ', '), $it.expected), $now)
    }
}

foreach ($g in @(@('OPRAVENO', $fixed), @('BEZ ZMENY', $pending), @('JINAK ZMENENO', $other))) {
    Write-Host ("--- {0} ({1}) ---" -f $g[0], @($g[1]).Count)
    foreach ($e in @($g[1])) {
        $nm = [string]$e[0].name; if ($nm.Length -gt 48) { $nm = $nm.Substring(0, 48) }
        Write-Host ("  {0,-8} {1,-48} {2}" -f $e[0].job_no, $nm, $e[1])
        $own = '?'; if ($e[0].owner) { $own = $e[0].owner.name }
        Write-Host ("           spravce: {0}" -f $own)
    }
    if (@($g[1]).Count -eq 0) { Write-Host '  zadne' }
    Write-Host ''
}

if ($SlackText) {
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('**Kontrola příplatků Notino — návazná kontrola**')
    [void]$L.Add(('Hlášeno {0}, období {1} – {2}.' -f `
        $snap.reported_at.Substring(0, 10), $snap.period[0], $snap.period[1]))
    [void]$L.Add('')
    if ($fixed.Count -gt 0) {
        [void]$L.Add(('**Opraveno ({0}):**' -f $fixed.Count))
        foreach ($e in $fixed) {
            $nm = [string]$e[0].name; if ($nm.Length -gt 45) { $nm = $nm.Substring(0, 45) }
            [void]$L.Add(('• `{0}` {1} — {2}' -f $e[0].job_no, $nm, $e[1]))
        }
        [void]$L.Add('')
    }
    if ($pending.Count -gt 0) {
        [void]$L.Add(('**Stále čeká ({0}):**' -f $pending.Count))
        foreach ($e in $pending) {
            $nm = [string]$e[0].name; if ($nm.Length -gt 45) { $nm = $nm.Substring(0, 45) }
            [void]$L.Add(('• `{0}` {1} — má {2}, čekáme {3} % — {4}' -f `
                $e[0].job_no, $nm, (($e[0].actual | ForEach-Object { (Format-Pct $_) + ' %' }) -join ', '),
                $e[0].expected, (Format-Tag -Item $e[0])))
        }
        [void]$L.Add('')
    }
    if ($other.Count -gt 0) {
        [void]$L.Add(('**Ke kontrole ({0}):**' -f $other.Count))
        foreach ($e in $other) {
            $nm = [string]$e[0].name; if ($nm.Length -gt 45) { $nm = $nm.Substring(0, 45) }
            [void]$L.Add(('• `{0}` {1} — {2}' -f $e[0].job_no, $nm, $e[1]))
        }
    }
    Write-Host ('=' * 78)
    Write-Host 'TEXT PRO SLACK:'
    Write-Host ('=' * 78)
    Write-Host ($L -join "`n")
}
