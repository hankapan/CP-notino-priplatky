<#
  Vytvori ~/.odoo.env s predvyplnenymi klici - mimo slozku s dovednosti.
  Hodnoty uz doplnis v editoru. Existujici soubor skript nikdy neprepise.
#>
$ErrorActionPreference = 'Stop'

$template = @'
# Prihlasovaci udaje k Odoo pro dovednost notino-priplatky.
# Tento soubor NIKDY nekopiruj do slozky s dovednosti - ta se sdili s kolegy.
ODOO_URL=https://firma.odoo.com
ODOO_USER=jmeno@firma.cz
ODOO_API_KEY=
# Volitelne; kdyz chybi, nazev databaze se zjisti automaticky:
# ODOO_DB=
'@

$path = $env:ODOO_ENV_FILE
if (-not $path) {
    $d = Join-Path $HOME '.notino-priplatky'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $path = Join-Path $d '.odoo.env'
}

if (Test-Path -LiteralPath $path) {
    Write-Host "Soubor uz existuje, nechavam beze zmeny:"
    Write-Host "  $path"
    return
}

# Bez BOM, at to prectou i jine nastroje.
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($path, ($template -replace "`r`n", "`n"), $utf8)

Write-Host "Vytvoreno:"
Write-Host "  $path"
Write-Host ''
Write-Host 'Otevri ho v editoru a doplnu ODOO_URL, ODOO_USER a ODOO_API_KEY.'
