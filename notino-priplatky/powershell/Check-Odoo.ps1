<#
  Kontrola expresnich priplatku v Odoo proti pravidlu (zakaznicke produkty).
  Zdrojem dat je vyhradne Odoo. Vuci Odoo READ-ONLY.

  .\Check-Odoo.ps1 -Start 2026-10-26 -End 2026-11-04 -Json vysledek.json -Csv kontrola.csv
  .\Check-Odoo.ps1                      # posledni 4 dny (vychozi okno)
  .\Check-Odoo.ps1 -FromJson vysledek.json   # text do Slacku bez dotazu do Odoo
#>
param(
    [string]$Start,
    [string]$End,
    [string]$Json,
    [string]$Csv,
    [switch]$SlackText,
    [string]$FromJson,
    [switch]$Discover
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\OdooQ.ps1"
. "$PSScriptRoot\Workdays.ps1"

$RuleValues = @(0, 30, 50, 80)
$SkillRoot = Split-Path -Parent $PSScriptRoot

function Get-Cfg {
    $p = Join-Path $SkillRoot 'scripts\fields.json'
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-SlackMap {
    $p = Join-Path $SkillRoot 'scripts\slack_users.json'
    if (-not (Test-Path -LiteralPath $p)) { return @{} }
    $o = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $h = @{}
    foreach ($prop in $o.PSObject.Properties) { $h[$prop.Name.ToLower()] = $prop.Value }
    return $h
}

function ConvertTo-DateOrNull {
    param($Value)
    if (-not $Value -or $Value -eq $false) { return $null }
    $s = ([string]$Value)
    if ($s.Length -lt 10) { return $null }
    return [datetime]::ParseExact($s.Substring(0, 10), 'yyyy-MM-dd', $null)
}

function Get-PeriodDomain {
    # `date` pole se porovnava holym datem, `datetime` vcetne casu,
    # jinak by posledni den vypadl.
    param($Cfg, [string]$S, [string]$E)
    $f = Invoke-OdooFieldsGet -Model $Cfg.job_model -Only @($Cfg.ordered_field)
    $type = $f.($Cfg.ordered_field).type
    if ($type -eq 'date') { $lo = $S; $hi = $E }
    else { $lo = "$S 00:00:00"; $hi = "$E 23:59:59" }
    $conds = New-Object System.Collections.ArrayList
    foreach ($c in $Cfg.job_filter) { [void]$conds.Add([object[]]$c) }
    [void]$conds.Add([object[]]@($Cfg.ordered_field, '>=', $lo))
    [void]$conds.Add([object[]]@($Cfg.ordered_field, '<=', $hi))
    return New-OdooDomain $conds.ToArray()
}

function Resolve-Owners {
    # Neaktivni uzivatele je nutne vytahnout s active_test=false, jinak je Odoo
    # ve vyhledavani tise vynecha a spravce zustane neznamy.
    param($Cfg, [int[]]$Ids)
    $map = @{}
    if (-not $Ids -or $Ids.Count -eq 0) { return $map }
    $slack = Get-SlackMap
    $dom = New-OdooDomain @( ,@('id', 'in', [object[]]$Ids) )
    $users = Invoke-OdooSearchRead -Model $Cfg.user_model -Domain $dom `
             -Fields @('id', 'name', 'login', 'email', 'active') `
             -Context @{ active_test = $false }
    foreach ($u in $users) {
        $mail = ''
        if ($u.email -and $u.email -ne $false) { $mail = ([string]$u.email).Trim().ToLower() }
        elseif ($u.login -and $u.login -ne $false) { $mail = ([string]$u.login).Trim().ToLower() }
        $map[[int]$u.id] = [pscustomobject]@{
            name = $u.name; email = $mail; active = [bool]$u.active
            slack_id = $slack[$mail]
        }
    }
    return $map
}

function Get-Rows {
    param($Cfg, [string]$S, [string]$E)
    $dom = Get-PeriodDomain -Cfg $Cfg -S $S -E $E
    $fields = @('id', $Cfg.job_no_field, 'name', $Cfg.ordered_field,
                $Cfg.ordered_fallback, $Cfg.deadline_field, $Cfg.owner_field,
                $Cfg.no_customer_products_field)
    $jobs = Invoke-OdooSearchRead -Model $Cfg.job_model -Domain $dom -Fields $fields `
            -Order ($Cfg.ordered_field + ' asc')
    if ($jobs.Count -eq 0) { return @() }

    $ownerIds = @()
    foreach ($j in $jobs) {
        $o = $j.($Cfg.owner_field)
        if ($o -and $o -ne $false) { $ownerIds += [int]$o[0] }
    }
    $owners = Resolve-Owners -Cfg $Cfg -Ids ([int[]]($ownerIds | Sort-Object -Unique))

    # Produkty vsech zakazek jednim dotazem misto jednoho na zakazku.
    $jobIds = [int[]]($jobs | ForEach-Object { [int]$_.id })
    $prodConds = New-Object System.Collections.ArrayList
    [void]$prodConds.Add([object[]]@($Cfg.link_field, 'in', [object[]]$jobIds))
    foreach ($c in $Cfg.customer_product_filter) { [void]$prodConds.Add([object[]]$c) }
    $prodDom = New-OdooDomain $prodConds.ToArray()
    $prods = Invoke-OdooSearchRead -Model $Cfg.product_model -Domain $prodDom `
             -Fields @($Cfg.link_field, $Cfg.surcharge_field)

    $byJob = @{}
    foreach ($p in $prods) {
        $tid = [int]$p.($Cfg.link_field)[0]
        if (-not $byJob.ContainsKey($tid)) { $byJob[$tid] = New-Object System.Collections.ArrayList }
        $v = $p.($Cfg.surcharge_field)
        if (-not $v) { $v = 0 }
        [void]$byJob[$tid].Add([math]::Round([double]$v, 2))
    }

    $rows = @()
    foreach ($j in $jobs) {
        $ordered = ConvertTo-DateOrNull $j.($Cfg.ordered_field)
        if (-not $ordered) { $ordered = ConvertTo-DateOrNull $j.($Cfg.ordered_fallback) }
        $deadline = ConvertTo-DateOrNull $j.($Cfg.deadline_field)
        # Pozor: `actual` jsou ruzne hodnoty priplatku, `n_customer` je pocet
        # zakaznickych produktu. Nemichat - jedna zakazka ma bezne 48 radku
        # se stejnym procentem.
        $vals = @(); $nProd = 0
        if ($byJob.ContainsKey([int]$j.id)) {
            $all = @($byJob[[int]$j.id])
            $nProd = $all.Count
            $vals = @($all | Sort-Object -Unique)
        }
        $wd = $null; $exp = $null
        if ($ordered -and $deadline) {
            $wd = Get-WorkdaysBetween -Start $ordered -End $deadline
            $exp = Get-ExpectedPct -Ordered $ordered -Deadline $deadline
        }
        $own = $j.($Cfg.owner_field)
        $ownerObj = $null
        if ($own -and $own -ne $false) {
            $oid = [int]$own[0]
            if ($owners.ContainsKey($oid)) { $ownerObj = $owners[$oid] }
            else { $ownerObj = [pscustomobject]@{ name = $own[1]; email = ''; active = $true; slack_id = $null } }
        }
        $nm = [string]$j.name
        if ($nm.Length -gt 70) { $nm = $nm.Substring(0, 70) }
        $rows += [pscustomobject]@{
            job_no = [string]$j.($Cfg.job_no_field)
            name = $nm
            ordered = $ordered
            deadline = $deadline
            workdays = $wd
            expected = $exp
            actual = $vals
            n_customer = $nProd
            owner = $ownerObj
        }
    }
    return $rows
}

function Get-Verdict {
    param($Row)
    if ($Row.n_customer -eq 0) { return $null }
    if (-not $Row.deadline) { return @('CHYBI TERMIN', 'nelze spocitat ocekavany priplatek') }
    $bad = @($Row.actual | Where-Object { $_ -ne $Row.expected })
    if ($bad.Count -eq 0) { return $null }
    $off = @($bad | Where-Object { $RuleValues -notcontains $_ })
    if ($off.Count -gt 0) {
        return @('JINE % - KONZULTOVAT',
                 ('ma {0}, pravidlo zna jen 0/30/50/80' -f (($off | ForEach-Object { (Format-Pct $_) + '%' }) -join ', ')))
    }
    return @('ODCHYLKA',
             ('ma {0} misto {1}% ({2} prac. dni)' -f (($bad | ForEach-Object { (Format-Pct $_) + '%' }) -join ', '), $Row.expected, $Row.workdays))
}

function Format-Tag {
    param($Row)
    $o = $Row.owner
    if ($o -and $o.slack_id) { return '<@' + $o.slack_id + '>' }
    if ($o -and $o.name) { return [string]$o.name }
    return 'správce neznámý'
}

function Get-SlackMessage {
    param($Rows, [string]$S, [string]$E)
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('**Kontrola expresních příplatků Notino**')
    [void]$L.Add(('Období {0} – {1}, zkontrolováno {2} zakázek.' -f $S, $E, @($Rows).Count))
    [void]$L.Add('')
    $probs = @()
    foreach ($r in $Rows) {
        $v = $null
        if ($r.PSObject.Properties.Name -contains 'verdict') {
            if ($r.verdict -ne 'OK') { $v = @($r.verdict, $r.detail) }
        } else { $v = Get-Verdict -Row $r }
        if ($v) { $probs += , @($r, $v) }
    }
    if ($probs.Count -eq 0) {
        [void]$L.Add('Vše v pořádku, žádná odchylka.')
        return ($L -join "`n")
    }
    [void]$L.Add(('**Odchylky ({0}):**' -f $probs.Count))
    foreach ($pair in $probs) {
        $r = $pair[0]; $kind = $pair[1][0]
        $od = $r.ordered; $dl = $r.deadline
        if ($od -is [datetime]) { $od = $od.ToString('yyyy-MM-dd') }
        if ($dl -is [datetime]) { $dl = $dl.ToString('yyyy-MM-dd') }
        [void]$L.Add('')
        [void]$L.Add(('`{0}` – {1}' -f $r.job_no, $r.name))
        [void]$L.Add(('objednáno {0}, termín {1} = {2} prac. dní → má být **{3} %**, má **{4}**' -f `
            $od, $dl, $r.workdays, $r.expected, (($r.actual | ForEach-Object { (Format-Pct $_) + ' %' }) -join ', ')))
        if ($kind -eq 'JINE % - KONZULTOVAT') {
            [void]$L.Add(('_Jiné procento, než pravidlo zná – prosím o konzultaci._ {0}' -f (Format-Tag -Row $r)))
        } else {
            [void]$L.Add(('{0} prosím o úpravu.' -f (Format-Tag -Row $r)))
        }
    }
    [void]$L.Add('')
    [void]$L.Add('_Pravidlo: tentýž den 80 %, 1 pracovní den 50 %, 2 pracovní dny 30 %, jinak 0 %._')
    return ($L -join "`n")
}

# ---------------------------------------------------------------- hlavni beh

if ($FromJson) {
    $res = Get-Content -LiteralPath $FromJson -Raw -Encoding UTF8 | ConvertFrom-Json
    Get-SlackMessage -Rows $res.rows -S $res.start -E $res.end
    return
}

if (-not $End) { $End = (Get-Date).ToString('yyyy-MM-dd') }
if (-not $Start) { $Start = ([datetime]$End).AddDays(-7).ToString('yyyy-MM-dd') }
if ($Start -gt $End) { throw "-Start ($Start) je až po -End ($End)" }

$cfg = Get-Cfg

if ($Discover) {
    foreach ($m in @($cfg.job_model, $cfg.product_model)) {
        Write-Host "== $m =="
        $f = Invoke-OdooFieldsGet -Model $m
        foreach ($p in ($f.PSObject.Properties | Sort-Object Name)) {
            $lbl = [string]$p.Value.string
            if ($p.Name -match 'priplatek|surcharge|expres|termin|deadline|zakazk|supplier|dodavat|notino|owner|spravce' -or
                $lbl -match '(?i)příplat|přirážk|expres|termín|zakázk|dodavat|správce') {
                Write-Host ("  {0,-34} {1,-10} {2}" -f $p.Name, $p.Value.type, $lbl)
            }
        }
        Write-Host ''
    }
    $n = Invoke-OdooSearchCount -Model $cfg.job_model -Domain (Get-PeriodDomain -Cfg $cfg -S $Start -E $End)
    Write-Host "zakazek v obdobi $Start..${End}: $n"
    return
}

$rows = Get-Rows -Cfg $cfg -S $Start -E $End
Write-Host ("Obdobi {0} .. {1}  |  zakazek Notino: {2}" -f $Start, $End, @($rows).Count)
Write-Host ''
Write-Host ("{0,-9} {1,-11} {2,-11} {3,3} {4,6} {5,-16} {6,5}  {7}" -f `
    'CISLO', 'OBJEDNANO', 'TERMIN', 'PD', 'OCEK', 'SKUTECNE', 'PROD', 'SPRAVCE')

$problems = @()
foreach ($r in $rows) {
    $v = Get-Verdict -Row $r
    if ($v) { $problems += , @($r, $v) }
    $od = ''; if ($r.ordered) { $od = $r.ordered.ToString('yyyy-MM-dd') }
    $dl = '-'; if ($r.deadline) { $dl = $r.deadline.ToString('yyyy-MM-dd') }
    $pd = '-'; if ($null -ne $r.workdays) { $pd = $r.workdays }
    $ex = '-'; if ($null -ne $r.expected) { $ex = $r.expected }
    $ac = '-'; if ($r.n_customer -gt 0) { $ac = (($r.actual | ForEach-Object { (Format-Pct $_) + '%' }) -join ', ') }
    $ow = '?'; if ($r.owner) { $ow = [string]$r.owner.name }
    if ($ow.Length -gt 20) { $ow = $ow.Substring(0, 20) }
    $mark = ''; if ($v) { $mark = '  <<' }
    Write-Host ("{0,-9} {1,-11} {2,-11} {3,3} {4,5}% {5,-16} {6,5}  {7,-20}{8}" -f `
        $r.job_no, $od, $dl, $pd, $ex, $ac, $r.n_customer, $ow, $mark)
}

Write-Host ''
Write-Host ('=' * 86)
Write-Host ("ODCHYLKY: {0} z {1} zakazek" -f $problems.Count, @($rows).Count)
Write-Host ('=' * 86)
foreach ($pair in $problems) {
    $r = $pair[0]; $kind = $pair[1][0]; $desc = $pair[1][1]
    Write-Host ("  [{0}] {1}  {2}" -f $kind, $r.job_no, $desc)
    Write-Host ("      {0}" -f $r.name)
    $mail = ''; $miss = ''
    if ($r.owner) {
        $mail = [string]$r.owner.email
        if (-not $r.owner.slack_id) { $miss = '   !! chybi ve slack_users.json' }
    }
    Write-Host ("      spravce: {0} <{1}>{2}" -f $r.owner.name, $mail, $miss)
}
if ($problems.Count -eq 0) { Write-Host '  zadne' }

$missing = @($problems | ForEach-Object { $_[0].owner } |
             Where-Object { $_ -and $_.email -and -not $_.slack_id } |
             ForEach-Object { $_.email } | Sort-Object -Unique)
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'Doplnit do scripts/slack_users.json (e-mail -> Slack ID):'
    foreach ($m in $missing) { Write-Host "   $m" }
}

$inactive = @($rows | ForEach-Object { $_.owner } |
              Where-Object { $_ -and -not $_.active } |
              ForEach-Object { $_.name } | Sort-Object -Unique)
if ($inactive.Count -gt 0) {
    Write-Host ''
    Write-Host ("Pozn.: v Odoo neaktivni spravci zakazek: {0}" -f ($inactive -join ', '))
}

if ($Json) {
    $out = @()
    foreach ($r in $rows) {
        $v = Get-Verdict -Row $r
        $od = ''; if ($r.ordered) { $od = $r.ordered.ToString('yyyy-MM-dd') }
        $dl = ''; if ($r.deadline) { $dl = $r.deadline.ToString('yyyy-MM-dd') }
        $out += [pscustomobject]@{
            job_no = $r.job_no; name = $r.name; ordered = $od; deadline = $dl
            workdays = $r.workdays; expected = $r.expected
            actual = @($r.actual); n_customer = $r.n_customer; owner = $r.owner
            verdict = $(if ($v) { $v[0] } else { 'OK' })
            detail = $(if ($v) { $v[1] } else { '' })
        }
    }
    $payload = [pscustomobject]@{ start = $Start; end = $End; rows = $out }
    ConvertTo-Json -InputObject $payload -Depth 10 |
        Set-Content -LiteralPath $Json -Encoding UTF8
    Write-Host ''
    Write-Host ("JSON: {0}" -f (Resolve-Path -LiteralPath $Json))
}

if ($SlackText) {
    Write-Host ''
    Write-Host ('=' * 86)
    Write-Host 'TEXT PRO SLACK:'
    Write-Host ('=' * 86)
    Write-Host (Get-SlackMessage -Rows $rows -S $Start -E $End)
}

if ($Csv) {
    $rows | ForEach-Object {
        $v = Get-Verdict -Row $_
        [pscustomobject]@{
            cislo = $_.job_no; nazev = $_.name
            spravce = $(if ($_.owner) { $_.owner.name } else { '' })
            objednano = $(if ($_.ordered) { $_.ordered.ToString('yyyy-MM-dd') } else { '' })
            termin = $(if ($_.deadline) { $_.deadline.ToString('yyyy-MM-dd') } else { '' })
            prac_dni = $_.workdays; ocekavano_pct = $_.expected
            skutecne_pct = (($_.actual | ForEach-Object { Format-Pct $_ }) -join ' / ')
            zakaznickych_produktu = $_.n_customer
            verdikt = $(if ($v) { $v[0] } else { 'OK' })
        }
    } | Export-Csv -LiteralPath $Csv -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host ("CSV: {0}" -f (Resolve-Path -LiteralPath $Csv))
}
