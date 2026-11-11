# -*- coding: utf-8 -*-
"""Read-only Odoo XML-RPC helper.

Prihlasovaci udaje se ctou v tomto poradi:
  1. uz nastavene promenne prostredi (ODOO_URL, ODOO_USER, ODOO_API_KEY, ODOO_DB)
  2. soubor urceny promennou ODOO_ENV_FILE
  3. ~/.notino-priplatky/.odoo.env
  4. ~/.odoo.env  (starsi umisteni)

Soubor NEPATRI do slozky s dovednosti - ta se sdili s kolegy.
Hodnoty se nikdy nevypisuji do konzole.
"""
import os, sys, json, ssl, xmlrpc.client
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)


def _parse_env_file(path):
    out = {}
    with open(path, encoding="utf-8-sig") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.lower().startswith("export "):
                line = line[7:].strip()
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[k] = v
    return out


def _load_env():
    """Fill os.environ from a .env file, without overriding what is already set."""
    home = os.path.expanduser("~")
    candidates = []
    if os.environ.get("ODOO_ENV_FILE"):
        candidates.append(os.environ["ODOO_ENV_FILE"])
    # Prednostne slozka dovednosti - lezi v ni i data/, takze staci povolit
    # pristup k jedne slozce misto cele domovske.
    candidates.append(os.path.join(home, ".notino-priplatky", ".odoo.env"))
    candidates.append(os.path.join(home, ".odoo.env"))

    stray = os.path.join(SKILL_DIR, ".env")
    if os.path.exists(stray):
        print("VAROVANI: %s lezi ve slozce s dovednosti, ktera se sdili s kolegy.\n"
              "          Presun ho mimo ni (napr. do ~/.odoo.env)." % stray,
              file=sys.stderr)
        candidates.append(stray)

    for path in candidates:
        if path and os.path.exists(path):
            for k, v in _parse_env_file(path).items():
                os.environ.setdefault(k, v)
            return path
    return None


_SRC = _load_env()

def _base_url(raw):
    """Vrati jen scheme://host. Z adresy zkopirovane z prohlizece odstrani
    cestu jako /odoo nebo /web - XML-RPC endpoint je vzdy na koreni."""
    raw = (raw or "").strip().rstrip("/")
    if not raw:
        return ""
    if "//" not in raw:
        raw = "https://" + raw
    p = urlsplit(raw)
    return f"{p.scheme}://{p.netloc}" if p.netloc else ""


URL = _base_url(os.environ.get("ODOO_URL"))
USER = os.environ.get("ODOO_USER") or ""
KEY = os.environ.get("ODOO_API_KEY") or ""
DB = os.environ.get("ODOO_DB") or ""

READ_ONLY = {"search_read", "read", "search", "search_count", "fields_get",
             "read_group", "name_search", "default_get"}


def _missing():
    return [n for n, v in (("ODOO_URL", URL), ("ODOO_USER", USER), ("ODOO_API_KEY", KEY)) if not v]


def common():
    return xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common",
                                     context=ssl.create_default_context(), allow_none=True)


def _db_list_http():
    """Seznam databazi pres JSON endpoint /web/database/list.
    Funguje i tam, kde je XML-RPC sluzba `db` zakazana (odoo.sh, Odoo Online)."""
    import json as _json, urllib.request
    req = urllib.request.Request(
        URL + "/web/database/list",
        data=_json.dumps({"jsonrpc": "2.0", "method": "call", "params": {}}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=30) as r:
        return _json.loads(r.read().decode("utf-8", "replace")).get("result") or []


def discover_db():
    if DB:
        return [DB]
    cands = []
    try:
        db = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/db",
                                       context=ssl.create_default_context(), allow_none=True)
        cands.extend(db.list() or [])
    except Exception as e:
        print(f"[db.list nedostupne: {type(e).__name__}]", file=sys.stderr)
    if not cands:
        try:
            cands.extend(_db_list_http())
        except Exception as e:
            print(f"[/web/database/list nedostupne: {type(e).__name__}]", file=sys.stderr)
    host = URL.split("//")[-1].split("/")[0].split(":")[0]
    parts = host.split(".")
    for guess in (parts[0], host.replace(".", "-"), host):
        if guess and guess not in cands:
            cands.append(guess)
    return cands


_UID = _DBNAME = None


def login():
    global _UID, _DBNAME
    if _UID:
        return _DBNAME, _UID
    miss = _missing()
    if miss:
        sys.exit("Chybi: %s\nNastav je v prostredi nebo v souboru (ODOO_ENV_FILE / ~/.odoo.env).\n"
                 "Nacteny soubor: %s" % (", ".join(miss), _SRC or "zadny"))
    errs = []
    for db in discover_db():
        try:
            uid = common().authenticate(db, USER, KEY, {})
            if uid:
                _UID, _DBNAME = uid, db
                return db, uid
            errs.append(f"{db}: prihlaseni odmitnuto")
        except Exception as e:
            errs.append(f"{db}: {type(e).__name__}: {e}")
    sys.exit("Nepodarilo se prihlasit. Zkouseno:\n  " + "\n  ".join(errs))


def call(model, method, *args, **kw):
    if method not in READ_ONLY:
        sys.exit(f"odmitnuta zapisova metoda: {method}")
    db, uid = login()
    models = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object",
                                       context=ssl.create_default_context(), allow_none=True)
    return models.execute_kw(db, uid, KEY, model, method, list(args), kw)


if __name__ == "__main__":
    if sys.argv[1:2] == ["whoami"]:
        db, uid = login()
        print(json.dumps({"db": db, "uid": uid, "host": URL.split("//")[-1],
                          "env_file": _SRC or "zadny"}, ensure_ascii=False))
    else:
        model, method = sys.argv[1], sys.argv[2]
        a = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []
        k = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
        print(json.dumps(call(model, method, *a, **k), ensure_ascii=False, indent=1, default=str))
