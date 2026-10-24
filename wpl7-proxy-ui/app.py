#!/usr/bin/env python3
"""WPL7 proxy UI.

Pagina web mica pentru rute reverse-proxy (domeniu public -> host:port intern) in
Traefik-ul din WPL7. Citeste/scrie fisierele proxy-<domeniu>.yml din directorul
file-provider al Traefik (aceleasi fisiere ca wpl7-proxy.sh). Doar biblioteca standard.
"""
import base64
import concurrent.futures
import hmac
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

DIR = os.environ.get("DYNAMIC_DIR", "/data")
STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
ENTRYPOINT = os.environ.get("ENTRYPOINT", "websecure")
RESOLVER = os.environ.get("ACME_RESOLVER", "letsencrypt")
USER = os.environ.get("PROXYUI_USER", "admin")
PASSWORD = os.environ.get("PROXYUI_PASSWORD", "")
RESERVED = {d.strip().lower() for d in (os.environ.get("PROXYUI_DOMAIN", ""), os.environ.get("PANEL_DOMAIN", "")) if d.strip()}
PUBLIC_IP = os.environ.get("PUBLIC_IP", "").strip()
TRAEFIK_HOST = os.environ.get("TRAEFIK_HOST", "wpl7-traefik")
TRAEFIK_PORT = int(os.environ.get("TRAEFIK_PORT", "443"))
ALLOW_UNSAFE = os.environ.get("PROXYUI_ALLOW_UNSAFE_TARGETS") == "1"
PORT = int(os.environ.get("PORT", "8080"))

LOCK = threading.Lock()


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, file=sys.stderr, flush=True)


class ApiError(Exception):
    def __init__(self, message, status=400, code=None):
        super().__init__(message)
        self.message, self.status, self.code = message, status, code


# ---------------------------------------------------------------- validare

LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
RE_DOMAIN = re.compile(rf"(?:{LABEL}\.)+(?:[a-z]{{2,63}}|xn--[a-z0-9-]{{2,59}})")
RE_HOST = re.compile(r"[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?")
BLOCKED_NAMES = {"localhost", "traefik", "mariadb", "mail", "dkim", "panel",
                 "host.docker.internal", "gateway.docker.internal"}


def clean_domain(raw, check_reserved=True):
    d = (raw or "").strip().lower().rstrip(".")
    if len(d) > 253 or not RE_DOMAIN.fullmatch(d):
        raise ApiError("Domeniu invalid (exemplu: exemplu.ro sau app.exemplu.ro).")
    if check_reserved and d in RESERVED:
        raise ApiError("Domeniul e rezervat (panoul WPL7 sau această pagină).")
    return d


def blocked(host):
    """Protectie de bun-simt (nu granita de securitate): loopback, link-local, servicii interne WPL7."""
    if host in BLOCKED_NAMES or host.startswith("wpl7-"):
        return "Adresă rezervată (serviciu intern WPL7 sau gazda locală)."
    # '127.1', '2130706433', '0x7f.1' etc. sunt acceptate de resolver ca IP-uri: cerem forma canonica.
    if host.rsplit(".", 1)[-1].isdigit() or host.startswith("0x"):
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            return "Adresă IP invalidă (folosește forma 192.168.1.50)."
        if ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast or ip.is_reserved:
            return "Adresă nepermisă (loopback, link-local sau rezervată)."
    return None


def clean_target(raw):
    t = (raw or "").strip()
    if not re.match(r"https?://", t, re.I):
        t = "http://" + t
    try:
        u = urlsplit(t)
        port = u.port
    except ValueError:
        raise ApiError("Țintă invalidă.")
    if u.username is not None or u.password is not None:
        raise ApiError("Nu pune utilizator/parolă în URL.")
    if u.path not in ("", "/") or u.query or u.fragment:
        raise ApiError("Traefik ignoră calea din URL; folosește doar host:port (ex. 192.168.1.50:8080).")
    host = (u.hostname or "").lower()
    if ":" in host:
        raise ApiError("IPv6 nu e suportat aici; folosește IPv4 sau un nume.")
    if not RE_HOST.fullmatch(host):
        raise ApiError("Gazdă invalidă în țintă.")
    if port is not None and not 1 <= port <= 65535:
        raise ApiError("Port invalid (1-65535).")
    if not ALLOW_UNSAFE:
        why = blocked(host)
        if why:
            raise ApiError(why)
    return f"{u.scheme.lower()}://{host}" + (f":{port}" if port else "")


# ---------------------------------------------------------------- fisiere

RE_HOST_RULE = re.compile(r"Host\(`([^`]+)`\)")
RE_URL = re.compile(r'url:\s*"([^"]+)"')


def slug(domain):
    return domain.replace(".", "-")


def route_path(domain):
    return os.path.join(DIR, f"proxy-{slug(domain)}.yml")


def render(domain, target, insecure):
    n = "proxy-" + slug(domain)
    y = [
        "# Gestionat de wpl7-proxy-ui / wpl7-proxy.sh - poate fi editat; panoul WPL7 nu atinge acest fisier.",
        "http:",
        "  routers:",
        f"    {n}:",
        f'      rule: "Host(`{domain}`)"',
        f"      entryPoints: [{ENTRYPOINT}]",
        f"      service: {n}",
        "      priority: 1",  # un site/panou WPL7 cu acelasi domeniu are prioritate
        "      tls:",
        f"        certResolver: {RESOLVER}",
        "  services:",
        f"    {n}:",
        "      loadBalancer:",
        "        passHostHeader: true",
    ]
    if insecure:
        y.append(f"        serversTransport: {n}-insecure")
    y += ["        servers:", f'          - url: "{target}"']
    if insecure:
        y += ["  serversTransports:", f"    {n}-insecure:", "      insecureSkipVerify: true"]
    return "\n".join(y) + "\n"


def read_route(path):
    try:
        with open(path, encoding="utf-8") as f:
            txt = f.read()
    except OSError:
        return None
    h, u = RE_HOST_RULE.search(txt), RE_URL.search(txt)
    return {"file": os.path.basename(path),
            "domain": h.group(1) if h else None,
            "target": u.group(1) if u else None,
            "insecure": "insecureSkipVerify: true" in txt}


def list_routes():
    """-> (rute recunoscute, fisiere proxy-*.yml nerecunoscute)"""
    try:
        names = sorted(n for n in os.listdir(DIR) if n.startswith("proxy-") and n.endswith(".yml"))
    except OSError as e:
        raise ApiError(f"Nu pot citi {DIR}: {e.strerror}. Volumul /srv/traefik/dynamic e montat?", 500)
    routes, ignored = [], []
    for n in names:
        r = read_route(os.path.join(DIR, n))
        if r and r["domain"] and r["target"]:
            routes.append(r)
        else:
            ignored.append(n)
    return sorted(routes, key=lambda r: r["domain"]), ignored


def save_route(domain, target, insecure, overwrite):
    path = route_path(domain)
    with LOCK:
        routes, _ = list_routes()
        for r in routes:
            if r["domain"] == domain and r["file"] != os.path.basename(path):
                raise ApiError(f"Domeniul există deja în fișierul {r['file']}.", 409, "conflict")
        if os.path.exists(path):
            cur = read_route(path)
            if not cur or cur["domain"] != domain:
                other = (cur or {}).get("domain") or os.path.basename(path)
                raise ApiError(f"Numele fișierului intră în coliziune cu ruta {other}.", 409, "conflict")
            if not overwrite:
                raise ApiError("Ruta există deja.", 409, "exists")
        fd, tmp = tempfile.mkstemp(dir=DIR, prefix=".proxy-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(render(domain, target, insecure))
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o644)
            os.replace(tmp, path)  # atomic: Traefik nu citeste niciodata un fisier pe jumatate scris
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    return {"domain": domain, "target": target, "insecure": insecure, "file": os.path.basename(path)}


def delete_route(domain):
    with LOCK:
        routes, _ = list_routes()
        for r in routes:
            if r["domain"] == domain:
                os.unlink(os.path.join(DIR, r["file"]))
                return
    raise ApiError("Ruta nu există.", 404)


# ---------------------------------------------------------------- verificari

def explain(e):
    if isinstance(e, ssl.SSLCertVerificationError):
        return "certificatul TLS nu e acceptat (autosemnat sau nume diferit) - bifează «Ignoră verificarea TLS»"
    if isinstance(e, ssl.SSLError):
        return f"eroare TLS ({e.reason or e}) - ai pus https:// pe un port HTTP?"
    if isinstance(e, socket.gaierror):
        return "numele nu poate fi rezolvat (DNS)"
    if isinstance(e, ConnectionRefusedError):
        return "conexiune refuzată - nu ascultă nimic pe acel port"
    if isinstance(e, (ConnectionResetError, http.client.BadStatusLine)):
        return "conexiune închisă de server - protocol greșit (http:// vs https://)?"
    if isinstance(e, TimeoutError):
        return "timeout (5 s) - verifică rutarea, firewall-ul sau VPN-ul"
    if isinstance(e, OSError):
        return f"eroare de rețea: {e.strerror or e}"
    return f"eroare: {e.__class__.__name__}"


def probe_backend(target, host_header=None, insecure=False, timeout=5):
    """Cere / de la tinta, din reteaua Traefik. Orice raspuns HTTP = tinta e accesibila."""
    t0 = time.monotonic()
    conn = None
    try:
        u = urlsplit(target)
        https = u.scheme == "https"
        port = u.port or (443 if https else 80)
        if https:
            ctx = ssl.create_default_context()
            if insecure:
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
            conn = http.client.HTTPSConnection(u.hostname, port, timeout=timeout, context=ctx)
        else:
            conn = http.client.HTTPConnection(u.hostname, port, timeout=timeout)
        conn.request("GET", "/", headers={"Host": host_header or u.netloc, "User-Agent": "wpl7-proxy-ui/1.0",
                                          "Accept": "*/*", "Connection": "close"})
        resp = conn.getresponse()
        return {"ok": True, "status": resp.status, "reason": resp.reason,
                "ms": int((time.monotonic() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001 - raportam orice eroare utilizatorului
        return {"ok": False, "error": explain(e)}
    finally:
        if conn:
            conn.close()


def probe_dns(domain):
    out = {"a": [], "aaaa": [], "public_ip": PUBLIC_IP or None, "points_here": None}
    for fam, key in ((socket.AF_INET, "a"), (socket.AF_INET6, "aaaa")):
        try:
            out[key] = sorted({ai[4][0] for ai in socket.getaddrinfo(domain, None, fam, socket.SOCK_STREAM)})
        except OSError:
            pass
    if PUBLIC_IP:
        out["points_here"] = PUBLIC_IP in out["a"]
    return out


def probe_cert(domain, timeout=5):
    """Ce certificat serveste Traefik pentru acest domeniu (SNI). Verificat normal:
    certificatul implicit al Traefik nu trece verificarea => inca neemis."""
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((TRAEFIK_HOST, TRAEFIK_PORT), timeout=timeout) as s:
            with ctx.wrap_socket(s, server_hostname=domain) as t:
                c = t.getpeercert()
        issuer = {k: v for part in c.get("issuer", ()) for k, v in part}
        days = int((ssl.cert_time_to_seconds(c["notAfter"]) - time.time()) // 86400)
        return {"ok": True, "issuer": issuer.get("organizationName") or issuer.get("commonName") or "?", "days": days}
    except ssl.SSLCertVerificationError:
        return {"ok": False, "error": "Traefik nu servește (încă) un certificat valid pentru acest domeniu"}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": explain(e)}


# ---------------------------------------------------------------- autentificare

FAILS = {}  # ip -> [numar, inceput fereastra]
FLOCK = threading.Lock()
MAX_FAILS, WINDOW = 8, 600

SEC_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
                               "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
    "X-Robots-Tag": "noindex, nofollow",
    "Strict-Transport-Security": "max-age=31536000",
}
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
}


def is_locked(ip):
    with FLOCK:
        e = FAILS.get(ip)
        if not e:
            return False
        if time.time() - e[1] > WINDOW:
            del FAILS[ip]
            return False
        return e[0] >= MAX_FAILS


def note_fail(ip):
    with FLOCK:
        now = time.time()
        if len(FAILS) > 10000:
            FAILS.clear()
        e = FAILS.get(ip)
        if not e or now - e[1] > WINDOW:
            FAILS[ip] = [1, now]
        else:
            e[0] += 1


class Handler(BaseHTTPRequestHandler):
    timeout = 15

    def version_string(self):
        return "proxyui"

    def log_message(self, *args, **kwargs):
        pass

    # --- raspunsuri
    def reply(self, status, body, ctype, extra=None):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in {**SEC_HEADERS, **(extra or {})}.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def json(self, status, obj, extra=None):
        self.reply(status, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8", extra)

    # --- helpers
    def client_ip(self):
        xff = self.headers.get("X-Forwarded-For", "")
        last = xff.split(",")[-1].strip() if xff else ""  # ultima valoare o adauga Traefik
        return last or self.client_address[0]

    def authenticate(self, ip):
        if is_locked(ip):
            self.json(429, {"error": "Prea multe încercări eșuate. Încearcă peste câteva minute."},
                      {"Retry-After": str(WINDOW)})
            return False
        h = self.headers.get("Authorization")
        if h:
            ok = False
            try:
                if h[:6].lower() != "basic ":
                    raise ValueError
                u, _, p = base64.b64decode(h[6:], validate=True).decode("utf-8").partition(":")
                ok = hmac.compare_digest(u.encode(), USER.encode()) & hmac.compare_digest(p.encode(), PASSWORD.encode())
            except (ValueError, UnicodeDecodeError):
                pass
            if ok:
                with FLOCK:
                    FAILS.pop(ip, None)
                return True
            note_fail(ip)
            log(f"[{ip}] autentificare eșuată")
        self.json(401, {"error": "Autentificare necesară."},
                  {"WWW-Authenticate": 'Basic realm="WPL7 proxy", charset="UTF-8"'})
        return False

    def guard_csrf(self):
        if self.headers.get("X-Requested-With") != "proxyui":
            raise ApiError("Cerere respinsă (CSRF).", 403)
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).netloc != self.headers.get("Host", ""):
            raise ApiError("Cerere respinsă (origine diferită).", 403)
        if self.command == "POST" and \
                self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            raise ApiError("Content-Type trebuie să fie application/json.", 415)

    def body(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = -1
        if n < 0 or n > 4096:
            raise ApiError("Cerere prea mare.", 413)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            raise ApiError("JSON invalid.")
        if not isinstance(data, dict):
            raise ApiError("JSON invalid.")
        return data

    # --- rutare
    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def do_DELETE(self):
        self.route()

    def route(self):
        method, path = self.command, urlsplit(self.path).path
        if method == "GET" and path == "/healthz":
            return self.reply(200, "ok", "text/plain; charset=utf-8")
        ip = self.client_ip()
        if not self.authenticate(ip):
            return None
        try:
            if method == "GET" and path in STATIC_FILES:
                name, ctype = STATIC_FILES[path]
                with open(os.path.join(STATIC, name), "rb") as f:
                    return self.reply(200, f.read(), ctype)
            if method == "GET" and path == "/api/routes":
                routes, ignored = list_routes()
                return self.json(200, {"routes": routes, "ignored": ignored, "public_ip": PUBLIC_IP or None})
            if method in ("POST", "DELETE"):
                self.guard_csrf()
            if method == "POST" and path == "/api/routes":
                d = self.body()
                domain, target = clean_domain(d.get("domain")), clean_target(d.get("target"))
                insecure = bool(d.get("insecure"))
                res = save_route(domain, target, insecure, bool(d.get("overwrite")))
                log(f"[{ip}] salvat {domain} -> {target}{' (TLS neverificat)' if insecure else ''}")
                return self.json(201, {"route": res})
            m = re.fullmatch(r"/api/routes/([^/]+)", path)
            if method == "DELETE" and m:
                domain = clean_domain(m.group(1), check_reserved=False)
                delete_route(domain)
                log(f"[{ip}] șters {domain}")
                return self.json(200, {"deleted": domain})
            if method == "POST" and path == "/api/check":
                return self.json(200, self.check(self.body()))
            raise ApiError("Nu există.", 404)
        except ApiError as e:
            return self.json(e.status, {"error": e.message, "code": e.code})
        except OSError as e:
            log(f"eroare fișiere: {e}")
            return self.json(500, {"error": f"Eroare la fișiere: {e.strerror or e}"})
        except Exception:  # noqa: BLE001
            log(traceback.format_exc())
            return self.json(500, {"error": "Eroare internă (vezi logurile containerului)."})

    def check(self, d):
        if d.get("domain"):
            domain = clean_domain(d["domain"], check_reserved=False)
            routes, _ = list_routes()
            route = next((r for r in routes if r["domain"] == domain), None)
            if not route:
                raise ApiError("Ruta nu există.", 404)
            with concurrent.futures.ThreadPoolExecutor(3) as ex:
                b = ex.submit(probe_backend, route["target"], domain, route["insecure"])
                dns = ex.submit(probe_dns, domain)
                cert = ex.submit(probe_cert, domain)
                return {"backend": b.result(), "dns": dns.result(), "cert": cert.result()}
        target = clean_target(d.get("target"))
        return {"target": target, "backend": probe_backend(target, None, bool(d.get("insecure")))}


def main():
    if len(PASSWORD) < 12:
        sys.exit("PROXYUI_PASSWORD lipsește sau are sub 12 caractere.")
    for name, val in (("ENTRYPOINT", ENTRYPOINT), ("ACME_RESOLVER", RESOLVER)):
        if not re.fullmatch(r"[A-Za-z0-9_.@-]+", val):
            sys.exit(f"{name} are caractere nepermise.")
    if not os.path.isdir(DIR):
        log(f"ATENȚIE: {DIR} nu există - volumul nu e montat?")
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    log(f"wpl7-proxy-ui pornit pe :{PORT}, director rute {DIR}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
