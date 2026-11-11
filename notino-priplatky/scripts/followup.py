# -*- coding: utf-8 -*-
"""Navazna kontrola: udelali spravci zakazek opravu, nebo ne?

  save   ulozi snimek toho, co bylo nahlaseno do Slacku
  check  znovu se podiva do Odoo a porovna aktualni stav se snimkem

Spravce zakazky i jeho Slack ID uz nese vysledek z check_odoo.py --json,
takze tady neni potreba zadny dalsi zdroj. Snimky lezi v data/.
Vuci Odoo READ-ONLY.
"""
import sys, os, json, argparse, datetime as dt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import odoo_q
from check_odoo import cfg

NL = chr(10)
HERE = os.path.dirname(os.path.abspath(__file__))

# Snimky zamerne NElezi ve slozce s dovednosti. Ta muze existovat ve vic kopiich
# (~/.claude/skills, nahrana verze z claude.ai) a pri aktualizaci se prepisuje -
# historie hlaseni by se roztrhla nebo zmizela. Drzi se proto na jednom mistě
# u uzivatele; prepsat lze promennou NOTINO_DATA_DIR.
DATA = os.environ.get("NOTINO_DATA_DIR") or os.path.join(
    os.path.expanduser("~"), ".notino-priplatky", "data")


def latest_snapshot():
    if not os.path.isdir(DATA):
        return None
    f = sorted(x for x in os.listdir(DATA) if x.endswith(".json"))
    return os.path.join(DATA, f[-1]) if f else None


def save(a):
    with open(a.json, encoding="utf-8") as fh:
        res = json.load(fh)
    problems = [r for r in res["rows"] if r["verdict"] != "OK"]
    snap = {
        "reported_at": dt.datetime.now().isoformat(timespec="seconds"),
        "period": [res["start"], res["end"]],
        "slack_channel": a.channel, "slack_ts": a.ts,
        "items": problems,
    }
    os.makedirs(DATA, exist_ok=True)
    path = os.path.join(DATA, "hlaseni_%s_%s.json" % (res["start"], res["end"]))
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(snap, fh, ensure_ascii=False, indent=1)
    print("Snimek ulozen: %s" % path)
    print("  polozek: %d" % len(snap["items"]))
    for i in snap["items"]:
        print("   %-8s %s -> %g%%   spravce: %s" % (
            i["job_no"], ", ".join("%g%%" % x for x in i["actual"]),
            i["expected"], (i.get("owner") or {}).get("name", "?")))


def current_state(job_no):
    """Aktualni priplatky na zakaznickych produktech dane zakazky, nebo None."""
    c = cfg()
    jobs = odoo_q.call(c["job_model"], "search_read",
                       [[c["job_no_field"], "=", job_no]], fields=["id"], limit=1)
    if not jobs:
        return None
    lines = odoo_q.call(c["product_model"], "search_read",
                        [[c["link_field"], "=", jobs[0]["id"]]] + c["customer_product_filter"],
                        fields=[c["surcharge_field"]], limit=1000)
    return sorted({round(float(l[c["surcharge_field"]] or 0), 2) for l in lines})


def tag(item):
    o = item.get("owner") or {}
    if o.get("slack_id"):
        return "<@%s>" % o["slack_id"]
    return o.get("name") or "správce neznámý"


def check(a):
    path = a.file or latest_snapshot()
    if not path:
        sys.exit("Zadny snimek v %s - spust nejdriv 'save'." % DATA)
    with open(path, encoding="utf-8") as fh:
        snap = json.load(fh)

    print("Snimek: %s" % os.path.basename(path))
    print("Nahlaseno: %s  |  obdobi %s..%s" % (snap["reported_at"], *snap["period"]))
    print("")

    fixed, pending, other = [], [], []
    for it in snap["items"]:
        now = current_state(it["job_no"])
        row = dict(it, now=now)
        if now is None:
            other.append((row, "zakazka v Odoo nenalezena"))
        elif now == it["actual"]:
            pending.append((row, "beze zmeny"))
        elif now == [it["expected"]]:
            fixed.append((row, "opraveno na %g%%" % it["expected"]))
        else:
            other.append((row, "zmeneno na %s, ocekavano %g%%"
                          % (", ".join("%g%%" % x for x in now), it["expected"])))

    for label, group in (("OPRAVENO", fixed), ("BEZ ZMENY", pending),
                         ("JINAK ZMENENO", other)):
        print("--- %s (%d) ---" % (label, len(group)))
        for r, note in group:
            print("  %-8s %-48s %s" % (r["job_no"], r["name"][:48], note))
            print("           spravce: %s" % ((r.get("owner") or {}).get("name") or "?"))
        if not group:
            print("  zadne")
        print("")

    if a.slack_text:
        L = ["**Kontrola příplatků Notino — návazná kontrola**",
             "Hlášeno %s, období %s – %s." % (snap["reported_at"][:10], *snap["period"]), ""]
        if fixed:
            L.append("**Opraveno (%d):**" % len(fixed))
            L += ["• `%s` %s — %s" % (r["job_no"], r["name"][:45], n) for r, n in fixed]
            L.append("")
        if pending:
            L.append("**Stále čeká (%d):**" % len(pending))
            for r, _n in pending:
                L.append("• `%s` %s — má %s, čekáme %g %% — %s" % (
                    r["job_no"], r["name"][:45],
                    ", ".join("%g %%" % x for x in r["actual"]), r["expected"], tag(r)))
            L.append("")
        if other:
            L.append("**Ke kontrole (%d):**" % len(other))
            L += ["• `%s` %s — %s" % (r["job_no"], r["name"][:45], n) for r, n in other]
        print("=" * 78)
        print("TEXT PRO SLACK:")
        print("=" * 78)
        print(NL.join(L))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s1 = sub.add_parser("save")
    s1.add_argument("--json", required=True)
    s1.add_argument("--channel")
    s1.add_argument("--ts")
    s1.set_defaults(fn=save)
    s2 = sub.add_parser("check")
    s2.add_argument("--file")
    s2.add_argument("--slack-text", action="store_true", dest="slack_text")
    s2.set_defaults(fn=check)
    a = ap.parse_args()
    a.fn(a)
