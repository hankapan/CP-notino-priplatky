"""Czech working days + the Notino surcharge rule."""
from datetime import date, timedelta

def easter(y):
    a=y%19; b=y//100; c=y%100; d=b//4; e=b%4; f=(b+8)//25; g=(b-f+1)//3
    h=(19*a+b-d-g+15)%30; i=c//4; k=c%4; l=(32+2*e+2*i-h-k)%7
    m=(a+11*h+22*l)//451; mo=(h+l-7*m+114)//31; da=((h+l-7*m+114)%31)+1
    return date(y,mo,da)

def cz_holidays(y):
    e = easter(y)
    return {
        date(y,1,1):   "Nový rok / Den obnovy samostatného českého státu",
        e-timedelta(2):"Velký pátek",
        e+timedelta(1):"Velikonoční pondělí",
        date(y,5,1):   "Svátek práce",
        date(y,5,8):   "Den vítězství",
        date(y,7,5):   "Den slovanských věrozvěstů Cyrila a Metoděje",
        date(y,7,6):   "Den upálení mistra Jana Husa",
        date(y,9,28):  "Den české státnosti",
        date(y,10,28): "Den vzniku samostatného československého státu",
        date(y,11,17): "Den boje za svobodu a demokracii",
        date(y,12,24): "Štědrý den",
        date(y,12,25): "1. svátek vánoční",
        date(y,12,26): "2. svátek vánoční",
    }

def is_workday(d):
    return d.weekday() < 5 and d not in cz_holidays(d.year)

def workdays_between(start, end):
    """Number of whole working days from `start` to `end` (both dates).
    Counts working days strictly after `start` up to and including `end`.
    start==end -> 0 (same day). Negative if end < start."""
    if end < start:
        return -workdays_between(end, start)
    n, d = 0, start
    while d < end:
        d += timedelta(days=1)
        if is_workday(d):
            n += 1
    return n

# Notino surcharge rule: working days of lead time -> expected surcharge %
RULE = {0: 80, 1: 50, 2: 30}

def expected_pct(ordered, deadline):
    """ordered / deadline: date objects. Returns expected surcharge percent."""
    return RULE.get(workdays_between(ordered, deadline), 0)

if __name__ == "__main__":
    import sys
    d = date(2026,10,26)
    print("Kalendář 26.10.–4.11.2026")
    while d <= date(2026,11,4):
        h = cz_holidays(d.year).get(d)
        tag = "svátek: "+h if h else ("víkend" if d.weekday()>=5 else "pracovní den")
        print(f"  {d:%d.%m.%Y} {['Po','Út','St','Čt','Pá','So','Ne'][d.weekday()]}  {tag}")
        d += timedelta(days=1)
    print("\nKontrola pravidla (objednáno -> termín => očekávané %):")
    for a,b in [((2026,10,26),(2026,10,26)), ((2026,10,26),(2026,10,27)),
                ((2026,10,27),(2026,10,29)), ((2026,10,27),(2026,10,30)),
                ((2026,10,30),(2026,11,2)),  ((2026,10,30),(2026,11,3)),
                ((2026,11,2),(2026,11,4))]:
        A,B = date(*a), date(*b)
        print(f"  {A:%d.%m.}->{B:%d.%m.}  {workdays_between(A,B)} prac. dní => {expected_pct(A,B)} %")
