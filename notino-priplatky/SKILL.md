---
name: notino-priplatky
description: Kontrola expresních příplatků u zakázek Notino v Odoo podle termínu dodání. Spočítá počet pracovních dnů mezi objednáním a termínem (bez víkendů a českých státních svátků), určí očekávaný příplatek (tentýž den 80 %, 1 pracovní den 50 %, 2 pracovní dny 30 %, jinak 0 %), porovná ho se skutečným příplatkem na zákaznických produktech, nahlásí odchylky do Slacku s označením správce zakázky a po čase ověří, jestli projektoví manažeři opravu udělali. Použij, když má někdo zkontrolovat, ověřit nebo odsouhlasit příplatky, přirážky či expresní sazby Notino za nějaké období, nebo zjistit, jestli byly nahlášené odchylky opravené.
---

# Kontrola expresních příplatků Notino

Zdrojem dat je **výhradně Odoo**. Salesforce se už nepoužívá.

## Požadavky

Dovednost existuje ve **dvou rovnocenných variantách** — stačí jedna:

| | `powershell/` | `scripts/` |
|---|---|---|
| Potřebuje | **nic**, PowerShell 5.1 je součástí Windows | Python 3.8+ |
| Závislosti | žádné | žádné (jen standardní knihovna) |
| Kde funguje | Windows | Windows, macOS, Linux |

Obě dělají totéž a jsou ověřené proti sobě: na období 26. 10.–4. 11. 2026 vracejí
shodně 117 zakázek, stejné verdikty u všech řádků a **znak po znaku identický**
text do Slacku. Sdílejí i konfiguraci (`scripts/fields.json`, `scripts/slack_users.json`)
a snímky hlášení, takže se dají míchat — kontrolu spustíš v PowerShellu a návaznou
v Pythonu, nebo naopak.

Pro kolegy bez Pythonu použij PowerShell variantu. Ověření, že Python je:

```bash
py -3 --version
```

Když to verzi nevypíše, nic neinstaluj a jeď přes `powershell/`.

### Konektor na Slack

Na **spuštění kontroly** Slack potřeba není — ta jen čte z Odoo a vypíše výsledek.
Potřeba je až na **odeslání hlášení**: Claude k tomu používá konektor Slack
(`slack_send_message`). Bez něj text vygeneruje a zkopíruješ ho do kanálu ručně.

Konektor je **per uživatel** — každý si ho zapíná sám v Settings → Connectors.
Z toho plyne pár věcí:

- Zpráva do `#notino` odejde **pod jménem toho, kdo kontrolu pustil**, ne pod
  jménem autora dovednosti.
- Kdo kontrolu pouští, musí být členem kanálu `#notino`.
- Návazná kontrola (`followup`) Slack nepotřebuje vůbec — jen čte Odoo a porovná
  se snímkem. Text připomínky zase jen vypíše.
### Převod příkazů

| Co | PowerShell | Python |
|---|---|---|
| údaje k Odoo | `.\powershell\Setup-Creds.ps1` | `py -3 scripts/setup_creds.py` |
| kontrola | `.\powershell\Check-Odoo.ps1 -Start … -End … -Json v.json` | `py -3 scripts/check_odoo.py --start … --end … --json v.json` |
| text do Slacku | `.\powershell\Check-Odoo.ps1 -FromJson v.json` | `py -3 scripts/check_odoo.py --from-json v.json` |
| snímek | `.\powershell\Followup.ps1 -Save -Json v.json -Channel … -Ts …` | `py -3 scripts/followup.py save --json v.json --channel … --ts …` |
| návazná kontrola | `.\powershell\Followup.ps1 -Check -SlackText` | `py -3 scripts/followup.py check --slack-text` |
| mapování modelu | `.\powershell\Check-Odoo.ps1 -Discover` | `py -3 scripts/check_odoo.py --discover` |
| pracovní dny | `.\powershell\Workdays.ps1` | `py -3 scripts/workdays.py` |

Bez `-Start`/`-End` (resp. `--start`/`--end`) se kontroluje **posledních 7 dní**.

> Soubory `.ps1` jsou uložené v UTF-8 **s BOM**. PowerShell 5.1 bez BOM čte skript
> jako ANSI a diakritika se rozsype. Když budeš skripty upravovat, BOM zachovej.

## Instalace

**Pro sebe:** Settings → Customize → Skills → **+ Add** a nahraj zip s touhle
složkou. Dovednost se pak objeví v seznamu *Yours* a je dostupná i mimo tenhle
počítač.

**Pro tým:** na detailu nahrané dovednosti je tlačítko **Publish to org**. Podle
nastavení organizace se publikuje hned, nebo půjde na schválení správci.

Kolegové si ji pak přidají v *Discover* a můžou rovnou spustit — ověřeno, že
skripty z nainstalované dovednosti běží.

Alternativa bez claude.ai: zkopírovat složku do `~/.claude/skills/`
(na Windows `C:\Users\<jmeno>\.claude\skills\`). Funguje jen v Claude Code
na daném počítači a je to spíš pro vývoj — pro rozdávání kolegům použij knihovnu
organizace.

> **Nemíchej obě cesty.** Když je dovednost nahraná i ve složce, Claude uvidí
> dvě položky (nahraná má v seznamu předponu) a časem se rozejdou. Vyber si jednu.
> Snímky hlášení jsou na tom nezávislé — leží v `~/.notino-priplatky/data/`,
> takže přechod z jedné cesty na druhou o historii nepřipraví.

Každý si musí nastavit **vlastní** přihlašovací údaje k Odoo — viz krok 1 níž.
Klíč se nesdílí a ve sdílené verzi není.

Co je a není součástí sdílené verze:

| Soubor | Sdílí se | Proč |
|---|---|---|
| `scripts/fields.json` | ano | mapování modelu, pro všechny stejné |
| `scripts/slack_users.json` | ano | e-mail → Slack ID, jen veřejná ID |
| `~/.notino-priplatky/` | **ne** | API klíč a snímky hlášení — soukromé, mimo složku s dovedností |
| `vysledek.json`, `kontrola*.csv` | **ne** | výstupy jednoho běhu |

## Pravidlo

Příplatek se odvíjí od **počtu celých pracovních dnů mezi objednáním a termínem vyhotovení**:

| Pracovních dnů | Očekávaný příplatek |
|---|---|
| 0 (tentýž den) | **80 %** |
| 1 | **50 %** |
| 2 | **30 %** |
| 3 a více | **0 %** |

- Pracovní den = **pondělí–pátek mimo české státní svátky**.
- Příplatek se kontroluje **na zákaznických produktech** — v Odoo jsou to řádky
  `cp.job.product`, které mají **prázdné `supplier_id`**. Dodavatelské řádky ho mají
  vyplněné a do kontroly nepatří.
- **Jakékoli jiné procento než 0 / 30 / 50 / 80 je nutné konzultovat**, ne automaticky
  opravovat — skript ho označí `JINÉ % - KONZULTOVAT` a v hlášení o opravu nežádá.

> Nejčastější zdroj chyb je svátek nebo víkend uprostřed termínu. Nikdy pracovní dny
> nepočítej od oka — vždy přes `scripts/workdays.py`.

## Postup

> Na Windows používej `py -3`; `python` nemusí být na PATH. Na Macu/Linuxu `python3`.
> Všechny skripty se spouštějí z kořene složky s dovedností.

### 0. První spuštění u nového kolegy

Dovednost **nenese žádný klíč** — každý si nastaví svůj. Python potřeba není.
Projdi to jednou a máš hotovo napořád.

**1. Vytvoř si v Odoo API klíč.** Vpravo nahoře avatar → *Preferences* → záložka
*Account Security* → *New API Key*. Pojmenuj ho třeba `kontrola_notino`.
Odoo si vyžádá heslo a klíč ukáže **jen jednou** — hned ho zkopíruj.

**2. Založ soubor s údaji.** Otevři PowerShell a vlož tenhle řádek:

```bash
New-Item -ItemType Directory -Force "$HOME\.notino-priplatky" | Out-Null; notepad "$HOME\.notino-priplatky\.odoo.env"
```

Vytvoří složku a otevře prázdný soubor v Poznámkovém bloku (potvrď *Ano*, že ho
má založit). Vlož do něj tohle a doplň svoje hodnoty:

```
ODOO_URL=https://firma.odoo.com
ODOO_USER=tvuj.email@firma.cz
ODOO_API_KEY=sem-vloz-klic-z-kroku-1
```

Ulož (Ctrl+S) a zavři. `ODOO_DB` vyplňovat netřeba.

**3. Nainstaluj si dovednost.** Settings → Customize → Skills → záložka
*Discover* → najdi `notino-priplatky` od organizace a přidej si ji. Nic se
nerozbaluje ani nekopíruje.

Pak **spusť novou session v Claude Code** — dovednosti se načítají při startu,
takže v už běžící ji Claude neuvidí.

> Ověřeno: skripty z takto nainstalované dovednosti jdou spustit. Claude si je
> rozbalí do své složky a `.ps1` si zachovají BOM, takže diakritika drží.
**4. Vyzkoušej to.** Řekni Claudovi „zkontroluj příplatky Notino za minulý týden“.
Musí vypsat tabulku zakázek a na konci sekci ODCHYLKY.

Kdyby to skončilo na „přihlášení odmítnuto“, bývá to překlep v e-mailu, klíč
zkopírovaný s mezerou navíc, nebo klíč vytvořený pod jiným účtem.

Stačí **čtecí** práva v Odoo; skripty nic nezapisují a zápisové metody rovnou
odmítají. Pozor ale: na co v Odoo nevidíš, to kontrola nenajde — a vyjde
prázdný výsledek, ne chyba.

> Co si **nemusíš** nastavovat: mapování polí (`scripts/fields.json`) ani Slack ID
> (`scripts/slack_users.json`) — ty jsou součástí dovednosti a jsou pro všechny stejné.

### 1. Kde skript hledá přihlašovací údaje

Skript hledá `ODOO_URL`, `ODOO_USER`, `ODOO_API_KEY` (volitelně `ODOO_DB`) v pořadí:

1. proměnné už nastavené v prostředí
2. soubor určený proměnnou `ODOO_ENV_FILE`
3. **`~/.notino-priplatky/.odoo.env`** ← doporučené
4. `~/.odoo.env` (starší umístění, čte se dál)

Doporučené umístění je `~/.notino-priplatky/`, protože v té složce už leží `data/`
se snímky hlášení. Všechno soukromé k téhle dovednosti je tak na jednom místě —
a když se tě Claude zeptá na přístup k souborům, povolíš **jednu složku** místo
celé domovské.

Soubor si na správném místě vyrobíš takhle (existující nikdy nepřepíše):

```bash
py -3 scripts/setup_creds.py
```

Pak ho otevři v editoru a vyplň:

```
ODOO_URL=https://firma.odoo.com
ODOO_USER=jmeno@firma.cz
ODOO_API_KEY=
```

> **Soubor s klíčem nepatří do složky s touhle dovedností.** Ta se posílá kolegům,
> takže by klíč odešel s ní. Skript na `.env` uvnitř složky upozorní varováním.
> `~/.notino-priplatky/` je něco jiného — ta zůstává u každého na jeho počítači.

Dvě věci, které se snadno přehlédnou:

- `$env:ODOO_API_KEY = '...'` napsané do PowerShellu platí jen pro ten jeden proces,
  ale **samotný příkaz se uloží do historie** (`ConsoleHost_history.txt`) v čitelné
  podobě. Filtr na citlivé hodnoty má až PSReadLine 2.1+. Bezpečněji:
  `$env:ODOO_API_KEY = Read-Host 'API key'`.
- Hodnoty nikdy nevypisuj do konzole ani do chatu. `odoo_q.py whoami` schválně tiskne
  jen databázi, uid a hostname.

Název databáze si skript zjistí sám: zkusí XML-RPC službu `db.list`, a když je zakázaná
(odoo.sh, Odoo Online), sáhne na JSON endpoint `/web/database/list`. Z `ODOO_URL` si
sám odřízne cestu, takže adresa zkopírovaná z prohlížeče (`.../odoo`) funguje.

`scripts/odoo_q.py` je read-only wrapper nad Odoo XML-RPC — povoluje jen `search_read`,
`read`, `search`, `search_count`, `fields_get`, `read_group`, `name_search`,
`default_get`. Jakýkoli zápis odmítne.

### 2. Mapování modelu

V Odoo Českých překladů (ověřeno) platí tohle mapování, které je už v `scripts/fields.json`:

| Co | Kde |
|---|---|
| zakázka | `project.task` |
| filtr na Notino | `cp_is_notino = true` |
| **stav zakázky** | `cp_workflow_status = 'completed'` (*Realizováno*) |
| **objednáno** | `cp_close_date` (v UI *Termín zadání*) |
| termín | `cp_deadline` |
| **správce zakázky (PM)** | `cp_owner_id` → `res.users` |
| produkty | `cp.job.product`, vazba `task_id` |
| **zákaznický produkt** | `supplier_id` je **prázdné** |
| příplatek | `extra_charge_pct` |

> **Kontrolují se jen zakázky ve stavu *Realizováno*.** U rozpracovaných
> (`ordered`, `assigned`, …) se příplatek ještě může doplnit, takže by je kontrola
> hlásila jako chybějící, i když chyba nenastala. Hodnoty `cp_workflow_status`:
> `enquiry`, `quotation_sent`, `ordered`, `assigned`, `internal_check`,
> `waiting_po`, `completed`, `cancelled`.

> Pozor na `sale.order` — v systému existuje, ale zakázky v něm nejsou (celkem 3 záznamy).

> **Objednáno je `cp_close_date`, ne `create_date`.** `create_date` je okamžik vzniku
> záznamu v Odoo a umí se od termínu zadání lišit o den — zakázka se třeba zadá
> ve čtvrtek a v systému vznikne až v pátek. Rozdíl jednoho dne přitom posouvá celé
> pásmo pravidla, takže kontrola pak hlásí odchylky, které žádné nejsou.
> V UI je to pole vidět jako **Termín zadání** hned nad termínem vyhotovení.

> Pole `cp_sf_*` jsou pozůstatek po Salesforce. Kontrola je nepoužívá.

V jiné instanci Odoo si model nejdřív zmapuj:

```bash
py -3 scripts/check_odoo.py --discover --start 2026-10-26 --end 2026-11-04
```

### 3. Samotná kontrola

```bash
py -3 scripts/check_odoo.py --start 2026-10-26 --end 2026-11-04 --json vysledek.json --csv kontrola.csv
```

Vypíše tabulku všech zakázek se správcem, pod ní seznam odchylek. `--json` je potřeba
pro navazující kroky, `--csv` je volitelný export.

**Období je libovolné.** `--start` a `--end` berou `YYYY-MM-DD`. Když je vynecháš,
kontroluje se **posledních 7 dní** (do dneška) — to je výchozí režim pro pravidelnou
týdenní kontrolu. Skript vždy na prvním řádku vypíše, jaké období počítal, takže si
to můžeš ověřit. Obrácené pořadí dat odmítne.

Období se filtruje podle **Termínu zadání**, ne podle data vzniku záznamu.

### 4. Hlášení do Slacku

Zpráva jde do kanálu **#notino** (`C4CKL4D37`) a označuje **správce zakázky** —
projektového manažera z pole `cp_owner_id`.

Párování na Slack jde **přes e-mail**: z `res.users` se vezme `email` (nebo `login`)
a dohledá se v `scripts/slack_users.json`. Text vygeneruješ bez dalšího dotazu do Odoo:

```bash
py -3 scripts/check_odoo.py --from-json vysledek.json
```

Text zkontroluj a teprve pak pošli přes Slack (`slack_send_message`, kanál `C4CKL4D37`).

> **Nikdy neposílej bez odsouhlasení.** Zpráva označuje konkrétní lidi ve veřejném
> kanálu — ať si zadavatel přečte, co přesně odejde a koho to upozorní.

Když někdo ve `slack_users.json` chybí, skript ho vypíše pod hlavičkou
„Doplnit do scripts/slack_users.json" a v textu ho označí jménem místo zmínky.
Slack ID dohledáš přes `slack_search_users` podle e-mailu a doplníš do souboru.

Zakázky s verdiktem `JINÉ % - KONZULTOVAT` zpráva **nežádá opravit**, jen vyzve ke
konzultaci.

### 5. Návazná kontrola — udělali PM opravu?

Hned po odeslání ulož snímek toho, co bylo nahlášeno:

```bash
py -3 scripts/followup.py save --json vysledek.json --channel C4CKL4D37 --ts <ts_zpravy>
```

Snímek se uloží do `~/.notino-priplatky/data/hlaseni_<od>_<do>.json` i se správci
a jejich Slack ID — mimo složku s dovedností, ať přežije její aktualizaci.
S odstupem (typicky za pár dní) spusť:

```bash
py -3 scripts/followup.py check --slack-text
```

Znovu se podívá do Odoo na ty konkrétní zakázky a rozdělí je do tří skupin:

| Skupina | Co to znamená |
|---|---|
| **OPRAVENO** | příplatek teď sedí s očekávaným → hotovo |
| **BEZ ZMĚNY** | hodnota je stejná jako při hlášení → PM to ještě neudělal |
| **JINAK ZMĚNĚNO** | hodnota se změnila, ale na něco jiného → podívat se ručně |

S `--slack-text` rovnou vypíše text připomínky, který znovu označí jen ty správce,
u kterých se nic nestalo. Pro starší období použij `--file` a konkrétní snímek.

## Ověřený výsledek

Období 26. 10.–4. 11. 2026. V tomto období je **28. 10. státní svátek**
a 31. 10.–1. 11. víkend.

| Zakázka | Objednáno | Termín | Prac. dnů | Očekáváno | Skutečnost |
|---|---|---|---|---|---|
| 194782 | 2. 11. (Po) | 4. 11. (St) | 2 | 30 % | 50 % ❌ |
| 194806 | 3. 11. (Út) | 3. 11. (Út) | 0 | 80 % | 100 % ❌ |

Ze 117 zakázek 2 odchylky. Po pozdějším doplnění filtru na stav *Realizováno*
je to **2 z 86** — vyřazené zakázky byly rozpracované, žádná odchylka mezi nimi nebyla. Plný rozbor je v
`reference/vysledek_2026-10-26_2026-11-04.md`.

Past: 27. 10. → 29. 10. je jen **1 pracovní den**, ne 2 (28. 10. je svátek).

## Co skript nedělá

- Nic v Odoo **neopravuje** — jen hlásí.
- Neposílá do Slacku sám od sebe — text vygeneruje, odeslání je vždy na člověku.
- Nepracuje s jinými zákazníky než s tím ve `fields.json`; pro jiného zákazníka
  ověř, že pro něj platí stejná procenta.

## Kde to vůbec může běžet

Skripty se připojují **přímo na Odoo** (XML-RPC / JSON-RPC na `ceskepreklady.odoo.com`).
To znamená, že prostředí, ve kterém běží, na Odoo musí síťově dosáhnout.

| Prostředí | Funguje | Proč |
|---|---|---|
| Claude Code na firemním počítači | **ano** | jde přímo z počítače, ověřeno |
| PowerShell / terminál na počítači | **ano** | totéž |
| Cowork — VM na počítači | **ano** | po povolení domény v allowlistu (6. 11. 2026) |
| Cowork — cloud | **ne** | allowlist doménu nepřeloží ani po povolení |

Když se připojení nezdaří hláškou o nedosažitelnosti (ne „přihlášení odmítnuto"),
není chyba v klíči ani v kódu — jen prostředí na Odoo nevidí. Nejspolehlivější je
spustit kontrolu v **Claude Code** na počítači.

Allowlist se spravuje v admin konzoli Claude na
`https://claude.ai/admin-settings/capabilities`, sekce *Code execution* — mění ho
jen správce organizace a projeví se až v nové session. Není to firewall ani
`settings.json`. U Českých překladů je doména povolená od 6. 11. 2026; VM na
počítači tím začalo fungovat, cloud dál ne.

> **Obcházení přes prohlížeč neber jako výsledek.** Když Odoo není dosažitelné,
> Claude může nabídnout, že data načte přes přihlášený Chrome. Čte tím ale webové
> rozhraní, ne API — jiná cesta k datům, kterou tahle dovednost nemá ověřenou.
> Čísla z takového běhu si před nahlášením do Slacku ověř přímo v Odoo.
## Na co si dát pozor

- **Neaktivní správci.** Část zakázek vlastní uživatelé, kteří jsou v Odoo
  `active = false`. Odoo je ve výchozím vyhledávání vynechává, takže se musí tahat
  s `context={"active_test": False}` — jinak zůstane správce neznámý. Skript to dělá
  a neaktivní správce vypíše na konci jako poznámku. Slack účet přitom mít můžou.
- **Datum objednání.** Ber `cp_close_date` (Termín zadání), ne `create_date`.
  Záměna o jeden den udělá z vyhovující zakázky odchylku — stalo se to u 194724.
- **Rozpracované zakázky se nekontrolují.** Filtr bere jen `completed`. Když ti
  nějaká zakázka v kontrole chybí, podívej se nejdřív na její stav — nejspíš ještě
  není realizovaná. Rozsah filtru změníš v `scripts/fields.json` v `job_filter`;
  obě varianty (PowerShell i Python) ho čtou ze stejného místa.
- **Zakázky bez zákaznických produktů** se do kontroly nepočítají (nemají co mít
  příplatek). V tabulce mají ve sloupci `PROD` nulu.
