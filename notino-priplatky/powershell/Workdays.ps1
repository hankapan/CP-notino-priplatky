# Ceske svatky, pracovni dny a pravidlo pro priplatek.
# Dot-source: . "$PSScriptRoot\Workdays.ps1"

function Get-Easter {
    param([int]$Year)
    $a = $Year % 19
    $b = [math]::Floor($Year / 100)
    $c = $Year % 100
    $d = [math]::Floor($b / 4)
    $e = $b % 4
    $f = [math]::Floor(($b + 8) / 25)
    $g = [math]::Floor(($b - $f + 1) / 3)
    $h = (19 * $a + $b - $d - $g + 15) % 30
    $i = [math]::Floor($c / 4)
    $k = $c % 4
    $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7
    $m = [math]::Floor(($a + 11 * $h + 22 * $l) / 451)
    $month = [math]::Floor(($h + $l - 7 * $m + 114) / 31)
    $day = (($h + $l - 7 * $m + 114) % 31) + 1
    return (Get-Date -Year $Year -Month $month -Day $day).Date
}

function Get-CzHolidays {
    param([int]$Year)
    $e = Get-Easter -Year $Year
    $h = [ordered]@{}
    $h[(Get-Date -Year $Year -Month 1  -Day 1).Date]  = 'Nový rok / Den obnovy samostatného českého státu'
    $h[$e.AddDays(-2)]                                 = 'Velký pátek'
    $h[$e.AddDays(1)]                                  = 'Velikonoční pondělí'
    $h[(Get-Date -Year $Year -Month 5  -Day 1).Date]  = 'Svátek práce'
    $h[(Get-Date -Year $Year -Month 5  -Day 8).Date]  = 'Den vítězství'
    $h[(Get-Date -Year $Year -Month 7  -Day 5).Date]  = 'Den slovanských věrozvěstů Cyrila a Metoděje'
    $h[(Get-Date -Year $Year -Month 7  -Day 6).Date]  = 'Den upálení mistra Jana Husa'
    $h[(Get-Date -Year $Year -Month 9  -Day 28).Date] = 'Den české státnosti'
    $h[(Get-Date -Year $Year -Month 10 -Day 28).Date] = 'Den vzniku samostatného československého státu'
    $h[(Get-Date -Year $Year -Month 11 -Day 17).Date] = 'Den boje za svobodu a demokracii'
    $h[(Get-Date -Year $Year -Month 12 -Day 24).Date] = 'Štědrý den'
    $h[(Get-Date -Year $Year -Month 12 -Day 25).Date] = '1. svátek vánoční'
    $h[(Get-Date -Year $Year -Month 12 -Day 26).Date] = '2. svátek vánoční'
    return $h
}

$script:HolidayCache = @{}
function Get-HolidaySet {
    param([int]$Year)
    if (-not $script:HolidayCache.ContainsKey($Year)) {
        $script:HolidayCache[$Year] = Get-CzHolidays -Year $Year
    }
    return $script:HolidayCache[$Year]
}

function Test-Workday {
    param([datetime]$Date)
    $d = $Date.Date
    if ($d.DayOfWeek -eq [System.DayOfWeek]::Saturday) { return $false }
    if ($d.DayOfWeek -eq [System.DayOfWeek]::Sunday)   { return $false }
    return -not (Get-HolidaySet -Year $d.Year).Contains($d)
}

function Get-WorkdaysBetween {
    <#
      Pocet celych pracovnich dnu od Start do End (vcetne End, bez Start).
      Start -eq End  -> 0 (tentyz den). Kdyz je End drive nez Start, vrati zaporne.
    #>
    param([datetime]$Start, [datetime]$End)
    $s = $Start.Date; $e = $End.Date
    if ($e -lt $s) { return -1 * (Get-WorkdaysBetween -Start $e -End $s) }
    $n = 0; $d = $s
    while ($d -lt $e) {
        $d = $d.AddDays(1)
        if (Test-Workday -Date $d) { $n++ }
    }
    return $n
}

function Get-ExpectedPct {
    # Pravidlo: tentyz den 80 %, 1 pracovni den 50 %, 2 pracovni dny 30 %, jinak 0 %.
    param([datetime]$Ordered, [datetime]$Deadline)
    switch (Get-WorkdaysBetween -Start $Ordered -End $Deadline) {
        0 { return 80 }
        1 { return 50 }
        2 { return 30 }
        default { return 0 }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $names = @('Po','Út','St','Čt','Pá','So','Ne')
    Write-Host 'Kalendář 26.10.-4.11.2026'
    $d = [datetime]'2026-10-26'
    while ($d -le [datetime]'2026-11-04') {
        $hol = (Get-HolidaySet -Year $d.Year)[$d.Date]
        if ($hol) { $tag = "svátek: $hol" }
        elseif (-not (Test-Workday -Date $d)) { $tag = 'víkend' }
        else { $tag = 'pracovní den' }
        $idx = [int]$d.DayOfWeek; if ($idx -eq 0) { $idx = 6 } else { $idx = $idx - 1 }
        Write-Host ("  {0:dd.MM.yyyy} {1}  {2}" -f $d, $names[$idx], $tag)
        $d = $d.AddDays(1)
    }
    Write-Host ''
    Write-Host 'Kontrola pravidla (objednáno -> termín => očekávané %):'
    $pairs = @(
        @('2026-10-26','2026-10-26'), @('2026-10-26','2026-10-27'),
        @('2026-10-27','2026-10-29'), @('2026-10-27','2026-10-30'),
        @('2026-10-30','2026-11-02'), @('2026-10-30','2026-11-03'),
        @('2026-11-02','2026-11-04'), @('2026-10-29','2026-11-03')
    )
    foreach ($p in $pairs) {
        $a = [datetime]$p[0]; $b = [datetime]$p[1]
        Write-Host ("  {0:dd.MM.}->{1:dd.MM.}  {2} prac. dní => {3} %" -f `
            $a, $b, (Get-WorkdaysBetween -Start $a -End $b), (Get-ExpectedPct -Ordered $a -Deadline $b))
    }
}
