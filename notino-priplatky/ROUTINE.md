# Zadání pro časovanou úlohu (cloud)

Rutina běží **každý pracovní den v 7:00** (cron `0 7 * * 1-5`, časové pásmo Europe/Prague).
O tom, co se dnes opravdu udělá, rozhoduje `scripts/schedule_day.py`:

| Den | Akce | Kontrolované období |
|---|---|---|
| poslední pracovní den ≤ 15. | hlavní běh | 1.–15. aktuálního měsíce |
| poslední pracovní den měsíce | hlavní běh | celý aktuální měsíc |
| první pracovní den po hlavním běhu | návazná kontrola | podle posledního snímku v `data/` |
| ostatní dny | nic, rutina skončí | – |

Prostředí: `notino-priplatky` (proměnné `ODOO_URL`, `ODOO_USER`, `ODOO_API_KEY`).
Snímky hlášení se ukládají do `notino-priplatky/data/` a commitují zpět do repozitáře.

## Text, který se vloží do rutiny

```
Jsi v repozitáři CP-notino-priplatky. Postupuj podle notino-priplatky/SKILL.md.
Nikdy nevypisuj hodnoty proměnných prostředí. Vůči Odoo jen čti.

1. export NOTINO_DATA_DIR="$PWD/notino-priplatky/data"
2. Spusť: python notino-priplatky/scripts/schedule_day.py
   Výstup je JSON s polem "action".

3. Pokud action = "skip": napiš jednu větu "Dnes se nic nekontroluje." a skonči.

4. Pokud action = "main":
   a) python notino-priplatky/scripts/check_odoo.py --start <start> --end <end> --json vysledek.json
      (start a end vezmi z výstupu schedule_day.py)
   b) python notino-priplatky/scripts/check_odoo.py --from-json vysledek.json
      Vygeneruje text hlášení včetně označení správců.
   c) Pošli text do Slack kanálu #notino (C4CKL4D37) přes slack_send_message.
      Když nejsou žádné odchylky, pošli krátkou zprávu, že kontrola proběhla a vše je v pořádku.
      Z odpovědi si ulož ts zprávy.
   d) python notino-priplatky/scripts/followup.py save --json vysledek.json --channel C4CKL4D37 --ts <ts>
   e) Commitni a pushni nový soubor v notino-priplatky/data/ (zpráva "Snímek hlášení <start>–<end>").
      Nic jiného do repozitáře nepřidávej (vysledek.json je v .gitignore).

5. Pokud action = "followup":
   a) python notino-priplatky/scripts/followup.py check --slack-text
   b) Pošli vygenerovaný text do #notino (C4CKL4D37), pokud obsahuje nějaké neopravené zakázky;
      jinak krátce potvrď, že vše bylo opraveno.

6. Na konci napiš jednu větu: co se dnes dělo a zda se zpráva do Slacku odeslala.
   Pokud selže připojení k Odoo nebo odeslání do Slacku, napiš přesnou chybu a skonči,
   nezkoušej nic obcházet.
```
