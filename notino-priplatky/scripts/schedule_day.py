"""Rozhodne, co ma dnes udelat casovana uloha.

Vystup (JSON na stdout):
  {"action": "main",     "start": "RRRR-MM-01", "end": "RRRR-MM-15|posledni den mesice", "run_date": ...}
  {"action": "followup", "main_run_date": "RRRR-MM-DD", ...}
  {"action": "skip"}

Pravidla:
  * hlavni beh v polovine mesice  = posledni pracovni den, ktery je 15. nebo drive;
    kontroluje 1.-15. aktualniho mesice
  * hlavni beh na konci mesice    = posledni pracovni den mesice;
    kontroluje cely mesic (1.-posledni den)
  * navazna kontrola              = prvni pracovni den po kazdem hlavnim behu
Pracovni den = bez vikendu a ceskych statnich svatku (workdays.py).

Pouziti:  python schedule_day.py [--date RRRR-MM-DD]
"""
import sys, os, json, argparse, calendar
from datetime import date, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workdays import is_workday


def last_workday_on_or_before(d):
    while not is_workday(d):
        d -= timedelta(days=1)
    return d


def next_workday_after(d):
    d += timedelta(days=1)
    while not is_workday(d):
        d += timedelta(days=1)
    return d


def main_runs(y, m):
    """Dva hlavni behy mesice: [(datum behu, konec kontrolovaneho obdobi)]."""
    last = date(y, m, calendar.monthrange(y, m)[1])
    return [
        (last_workday_on_or_before(date(y, m, 15)), date(y, m, 15)),
        (last_workday_on_or_before(last), last),
    ]


def decide(today):
    # hlavni behy tohoto mesice
    for run, end in main_runs(today.year, today.month):
        if today == run:
            return {"action": "main", "run_date": run.isoformat(),
                    "start": date(today.year, today.month, 1).isoformat(),
                    "end": end.isoformat()}
    # navazna kontrola: hlavni behy tohoto i predchoziho mesice
    py, pm = (today.year, today.month - 1) if today.month > 1 else (today.year - 1, 12)
    for y, m in ((py, pm), (today.year, today.month)):
        for run, _ in main_runs(y, m):
            if today == next_workday_after(run):
                return {"action": "followup", "main_run_date": run.isoformat()}
    return {"action": "skip"}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", help="RRRR-MM-DD, vychozi dnes (pro testovani)")
    a = ap.parse_args()
    t = date.fromisoformat(a.date) if a.date else date.today()
    out = decide(t)
    out["today"] = t.isoformat()
    print(json.dumps(out, ensure_ascii=False))
