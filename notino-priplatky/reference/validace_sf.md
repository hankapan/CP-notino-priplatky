> **Historický záznam z doby, kdy se kontrolovalo i v Salesforce.**
> Není součástí postupu — kontrola běží výhradně nad Odoo.

# Validace pravidla proti Salesforce (Notino Group)

Účet: **Notino Group** (001QF00000GitEIYAZ)

| Zakázka | Objednáno (CreatedDate) | Termín (Termin_vyhotoveni__c) | Prac. dní | Očekáváno | Skutečnost (MaxPriplatek__c) | Verdikt |
|---|---|---|---|---|---|---|
| 1068094 | 2. 11. 2026 13:10 (Po) | 4. 11. 2026 13:00 (St) | 2 | **30 %** | 50 % | ❌ o 20 p.b. víc |
| 1069009 | 3. 11. 2026 11:04 (Út) | 3. 11. 2026 13:00 (Út) | 0 (tentýž den) | **80 %** | 100 % | ❌ o 20 p.b. víc |

Logika pracovních dnů (`workdays.py`) reprodukuje **oba** nálezy ze Salesforce přesně.

## Kalendář kontrolovaného období
26. 10. Po · 27. 10. Út · **28. 10. St = státní svátek** (Den vzniku samostatného
československého státu) · 29. 10. Čt · 30. 10. Pá · **31. 10. So + 1. 11. Ne = víkend**
· 2. 11. Po · 3. 11. Út · 4. 11. St

Pozor: 27. 10. → 29. 10. jsou jen **1 pracovní den** (28. 10. svátek), ne 2.

## Relevantní pole v Salesforce
- `CreatedDate` — okamžik objednání
- `Termin_vyhotoveni__c` (Deadline, Date/Time) — termín
- `MaxPriplatek__c` (rollup MAX z Opportunity Product) — skutečný příplatek v %
- `Sleva__c` (Extra charge/Discount, %) — příplatek na úrovni zakázky
- `Count_of_Customer_Products__c` / `Bez_z_kaznick_ch_produkt__c` — zákaznické produkty
- Zákaznické produkty = kladné řádky; dodavatelské řádky mají zápornou cenu
