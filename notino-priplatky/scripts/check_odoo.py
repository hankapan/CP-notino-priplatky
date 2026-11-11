# -*- coding: utf-8 -*-
"""Kontrola expresnich priplatku v Odoo proti pravidlu (zakaznicke produkty).

  --discover     zmapuje model a vypise kandidatni pole
  --from-json F  vygeneruje text do Slacku z drive ulozeneho vysledku (bez dotazu do Odoo)
  (bez prepinace) spocita ocekavany vs. skutecny priplatek a vypise odchylky

Mapovani poli je ve fields.json, mapa e-mail -> Slack ID ve slack_users.json.
Zdrojem dat je vyhradne Odoo. READ-ONLY.
"""
import sys, os, json, argparse, csv, datetime as dt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import odoo_q
from workdays import expected_pct, workdays_between

NL = chr(10)
HERE = os.path.dirname(os.path.abspath(__file__))
RULE_VALUES = {0, 30, 50, 80}


def cfg():
    with open(os.path.join(HERE, "fields.json"), encoding="utf-8") as fh:
        return json.load(fh)


def slack_map():
    p = os.path.join(HERE, "slack_users.json")
    if not os.path.exists(p):
        return {}
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def period_domain(c, start, end):
    """Rozsah pro filtr obdobi. `date` pole se porovnava holym datem,
    `datetime` pole vcetne casu - jinak by posledni den vypadl."""
    f = odoo_q.call(c["job_model"], "fields_get", [c["ordered_field"]], attributes=["type"])
    if f.get(c["ordered_field"], {}).get("type") == "date":
        lo, hi = start, end
    else:
        lo, hi = start + " 00:00:00", end + " 23:59:59"
    return [[c["ordered_field"], ">=", lo], [c["ordered_field"], "<=", hi]]


def as_date(v):
    if not v:
        return None
    return dt.date(*map(int, str(v)[:10].split("-")))


HINTS = ("priplatek", "prirazka", "surcharge", "expres", "termin", "deadline",
         "zakazk", "supplier", "dodavat", "notino", "owner", "spravce")


def discover(a):
    c = cfg()
    for model in (c["job_model"], c["product_model"]):
        print("== %s ==" % model)
        f = odoo_q.call(model, "fields_get", [], attributes=["string", "type"])
        for k in sorted(f):
            s = (f[k].get("string") or "")
            if any(h in k.lower() for h in HINTS) or any(h in s.lower() for h in HINTS):
                print("  %-34s %-10s %s" % (k, f[k]["type"], s))
        print("")
    n = odoo_q.call(c["job_model"], "search_count",
                    c["job_filter"] + period_domain(c, a.start, a.end))
    print("zakazek v obdobi %s..%s: %d" % (a.start, a.end, n))


def resolve_owners(c, owner_ids):
    """id -> {name, email, active, slack_id}.

    Neaktivni uzivatele je nutne vytahnout s active_test=False, jinak je Odoo
    ve vyhledavani tise vynecha a spravce zakazky zustane neznamy.
    """
    smap = slack_map()
    out = {}
    if not owner_ids:
        return out
    users = odoo_q.call(c["user_model"], "search_read",
                        [["id", "in", sorted(owner_ids)]],
                        fields=["id", "name", "login", "email", "active"],
                        context={"active_test": False})
    for u in users:
        mail = (u.get("email") or u.get("login") or "").strip().lower()
        out[u["id"]] = {"name": u["name"], "email": mail,
                        "active": u["active"], "slack_id": smap.get(mail)}
    return out


def collect(a):
    c = cfg()
    jobs = odoo_q.call(c["job_model"], "search_read",
        c["job_filter"] + period_domain(c, a.start, a.end),
        fields=["id", c["job_no_field"], "name", c["ordered_field"],
                c["ordered_fallback"], c["deadline_field"], c["owner_field"],
                c["no_customer_products_field"]],
        order=c["ordered_field"] + " asc")

    owners = resolve_owners(c, {j[c["owner_field"]][0] for j in jobs if j[c["owner_field"]]})

    rows = []
    for j in jobs:
        ordered = as_date(j[c["ordered_field"]] or j[c["ordered_fallback"]])
        deadline = as_date(j[c["deadline_field"]])
        lines = odoo_q.call(c["product_model"], "search_read",
            [[c["link_field"], "=", j["id"]]] + c["customer_product_filter"],
            fields=[c["surcharge_field"]], limit=1000)
        actual = sorted({round(float(l[c["surcharge_field"]] or 0), 2) for l in lines})
        own = j[c["owner_field"]]
        rows.append({
            "job_no": j[c["job_no_field"]], "name": (j["name"] or "")[:70],
            "ordered": ordered, "deadline": deadline,
            "workdays": workdays_between(ordered, deadline) if (ordered and deadline) else None,
            "expected": expected_pct(ordered, deadline) if (ordered and deadline) else None,
            "actual": actual, "n_customer": len(lines),
            "owner": owners.get(own[0], {"name": own[1]}) if own else {},
        })
    return rows


def classify(r):
    if r["n_customer"] == 0:
        return None
    if r["deadline"] is None:
        return ("CHYBI TERMIN", "nelze spocitat ocekavany priplatek")
    bad = [v for v in r["actual"] if v != r["expected"]]
    if not bad:
        return None
    off = [v for v in bad if v not in RULE_VALUES]
    if off:
        return ("JINE % - KONZULTOVAT",
                "ma %s, pravidlo zna jen 0/30/50/80" % ", ".join("%g%%" % v for v in off))
    return ("ODCHYLKA", "ma %s misto %g%% (%d prac. dni)"
            % (", ".join("%g%%" % v for v in bad), r["expected"], r["workdays"]))


def verdict_of(r):
    """Funguje pro cerstve radky i pro radky nactene z --from-json."""
    if "verdict" in r:
        return (r["verdict"], r["detail"]) if r["verdict"] != "OK" else None
    return classify(r)


def tag(r):
    o = r.get("owner") or {}
    if o.get("slack_id"):
        return "<@%s>" % o["slack_id"]
    return o.get("name") or "správce neznámý"


def slack_text(rows, start, end):
    probs = [(r, v) for r, v in ((r, verdict_of(r)) for r in rows) if v]
    L = ["**Kontrola expresních příplatků Notino**",
         "Období %s – %s, zkontrolováno %d zakázek." % (start, end, len(rows)), ""]
    if not probs:
        L.append("Vše v pořádku, žádná odchylka.")
        return NL.join(L)
    L.append("**Odchylky (%d):**" % len(probs))
    for r, (kind, _desc) in probs:
        L += ["",
              "`%s` – %s" % (r["job_no"], r["name"]),
              "objednáno %s, termín %s = %s prac. dní → má být **%g %%**, má **%s**"
              % (r["ordered"], r["deadline"], r["workdays"], r["expected"],
                 ", ".join("%g %%" % x for x in r["actual"]))]
        if kind == "JINE % - KONZULTOVAT":
            L.append("_Jiné procento, než pravidlo zná – prosím o konzultaci._ %s" % tag(r))
        else:
            L.append("%s prosím o úpravu." % tag(r))
    L += ["", "_Pravidlo: tentýž den 80 %, 1 pracovní den 50 %, 2 pracovní dny 30 %, jinak 0 %._",
          "_Pracovní dny bez víkendů a českých státních svátků._"]
    return NL.join(L)


def main(a):
    rows = collect(a)
    print("Obdobi %s .. %s  |  zakazek Notino: %d" % (a.start, a.end, len(rows)))
    print("")
    print("%-9s %-11s %-11s %3s %6s %-16s %5s  %s" %
          ("CISLO", "OBJEDNANO", "TERMIN", "PD", "OCEK", "SKUTECNE", "PROD", "SPRAVCE"))
    problems = []
    for r in rows:
        v = classify(r)
        print("%-9s %-11s %-11s %3s %5s%% %-16s %5d  %-20s%s" % (
            r["job_no"], r["ordered"], r["deadline"] or "-",
            "-" if r["workdays"] is None else r["workdays"],
            "-" if r["expected"] is None else r["expected"],
            ", ".join("%g%%" % x for x in r["actual"]) or "-",
            r["n_customer"], (r["owner"].get("name") or "?")[:20], "  <<" if v else ""))
        if v:
            problems.append((r, v))

    print("")
    print("=" * 86)
    print("ODCHYLKY: %d z %d zakazek" % (len(problems), len(rows)))
    print("=" * 86)
    for r, (kind, desc) in problems:
        o = r["owner"]
        print("  [%s] %s  %s" % (kind, r["job_no"], desc))
        print("      %s" % r["name"])
        print("      spravce: %s <%s>%s" % (
            o.get("name", "?"), o.get("email", "?"),
            "" if o.get("slack_id") else "   !! chybi ve slack_users.json"))
    if not problems:
        print("  zadne")

    missing = sorted({r["owner"].get("email") for r, _ in problems
                      if r["owner"].get("email") and not r["owner"].get("slack_id")})
    if missing:
        print("")
        print("Doplnit do scripts/slack_users.json (e-mail -> Slack ID):")
        for m in missing:
            print("   %s" % m)

    inactive = sorted({r["owner"]["name"] for r in rows
                       if r["owner"].get("active") is False})
    if inactive:
        print("")
        print("Pozn.: v Odoo neaktivni spravci zakazek: %s" % ", ".join(inactive))

    if a.json:
        out = []
        for r in rows:
            v = classify(r)
            out.append(dict(r, ordered=str(r["ordered"]), deadline=str(r["deadline"] or ""),
                            verdict=v[0] if v else "OK", detail=v[1] if v else ""))
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump({"start": a.start, "end": a.end, "rows": out}, fh,
                      ensure_ascii=False, indent=1)
        print("")
        print("JSON: %s" % os.path.abspath(a.json))

    if a.slack:
        print("")
        print("=" * 86)
        print("TEXT PRO SLACK:")
        print("=" * 86)
        print(slack_text(rows, a.start, a.end))

    if a.csv:
        with open(a.csv, "w", newline="", encoding="utf-8-sig") as fh:
            w = csv.writer(fh, delimiter=";")
            w.writerow(["cislo", "nazev", "spravce", "objednano", "termin", "prac_dni",
                        "ocekavano_pct", "skutecne_pct", "zakaznickych_produktu", "verdikt"])
            for r in rows:
                v = classify(r)
                w.writerow([r["job_no"], r["name"], r["owner"].get("name", ""),
                            r["ordered"], r["deadline"] or "",
                            "" if r["workdays"] is None else r["workdays"],
                            "" if r["expected"] is None else r["expected"],
                            " / ".join("%g" % x for x in r["actual"]),
                            r["n_customer"], v[0] if v else "OK"])
        print("")
        print("CSV: %s" % os.path.abspath(a.csv))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", help="YYYY-MM-DD; vychozi je pred 7 dny")
    ap.add_argument("--end", help="YYYY-MM-DD; vychozi je dnes")
    ap.add_argument("--discover", action="store_true")
    ap.add_argument("--csv")
    ap.add_argument("--json")
    ap.add_argument("--slack-text", action="store_true", dest="slack")
    ap.add_argument("--from-json", dest="from_json",
                    help="text do Slacku z drive ulozeneho JSON, bez dotazu do Odoo")
    a = ap.parse_args()
    if not a.end:
        a.end = dt.date.today().isoformat()
    if not a.start:
        a.start = (dt.date.fromisoformat(a.end) - dt.timedelta(days=7)).isoformat()
    if a.start > a.end:
        sys.exit("--start (%s) je az po --end (%s)" % (a.start, a.end))
    if a.from_json:
        with open(a.from_json, encoding="utf-8") as fh:
            res = json.load(fh)
        print(slack_text(res["rows"], res["start"], res["end"]))
    elif a.discover:
        discover(a)
    else:
        main(a)
