# -*- coding: utf-8 -*-
"""Vytvori ~/.odoo.env s predvyplnenymi klici - mimo slozku s dovednosti.

Hodnoty uz doplnis v editoru. Existujici soubor skript nikdy neprepise.
"""
import os, sys, stat

TEMPLATE = """# Prihlasovaci udaje k Odoo pro dovednost notino-priplatky.
# Tento soubor NIKDY nekopiruj do slozky s dovednosti - ta se sdili s kolegy.
ODOO_URL=https://firma.odoo.com
ODOO_USER=jmeno@firma.cz
ODOO_API_KEY=
# Volitelne; kdyz chybi, nazev databaze se zjisti automaticky:
# ODOO_DB=
"""

def main():
    path = os.environ.get("ODOO_ENV_FILE")
    if not path:
        d = os.path.join(os.path.expanduser("~"), ".notino-priplatky")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, ".odoo.env")
    if os.path.exists(path):
        print("Soubor uz existuje, nechavam beze zmeny:\n  %s" % path)
        return 0
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(TEMPLATE)
    try:  # na POSIXu omez prava na vlastnika
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass
    print("Vytvoreno:\n  %s\n\nOtevri ho v editoru a doplnu ODOO_URL, ODOO_USER a ODOO_API_KEY." % path)
    return 0

if __name__ == "__main__":
    sys.exit(main())
