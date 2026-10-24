# WPL7 proxy UI

Pagină web mică pentru rute reverse-proxy în Traefik-ul din WPL7: un domeniu public care deschide o
adresă internă (`situlmeu.com` → `192.168.1.50:8080`), ca „proxy sites” din CloudPanel.
Înlocuiește comenzile din `wpl7-proxy.sh` cu un formular și butoane. Cele două unelte scriu aceleași
fișiere (`/srv/traefik/dynamic/proxy-<domeniu>.yml`), deci le poți folosi împreună.

Nu modifică WPL7: rulează ca un container separat, într-un proiect Compose separat, și nu e atinsă
de update-urile WPL7.

## Instalare (pe serverul WPL7, ca root)

1. În DNS: A record pentru domeniul paginii (ex. `proxy.exemplu.ro`) spre IP-ul serverului.
2. Copiază arhiva pe server (WinSCP/pscp), apoi:

```bash
cd /opt
tar xzf ~/wpl7-proxy-ui.tar.gz
cd wpl7-proxy-ui
cp .env.example .env
nano .env              # PROXYUI_DOMAIN, PROXYUI_PASSWORD (min. 12 caractere), PANEL_DOMAIN, PUBLIC_IP
chmod 600 .env
docker compose up -d --build
docker compose logs --tail 20     # trebuie să vezi „wpl7-proxy-ui pornit pe :8080”
```

3. Deschide `https://proxy.exemplu.ro` (certificatul se emite în câteva secunde) și intră cu
   utilizatorul și parola din `.env`.

## Folosire

- **Adaugă ruta**: domeniu + țintă (`192.168.1.50:8080`, `http://nas:5000` sau `https://...`).
  Bifează „Ignoră verificarea TLS” doar pentru ținte `https://` cu certificat autosemnat.
- **Testează ținta**: încearcă adresa din containerul de pe rețeaua Traefik, deci cu aceeași
  rutare pe care o va avea site-ul, înainte să salvezi.
- **Verifică / Verifică toate**: pentru fiecare rută arată trei lucruri.
  - Ținta: orice răspuns HTTP (chiar și 401 sau 404) înseamnă accesibilă; punctul e verde la
    2xx/3xx, galben la 4xx, roșu la 5xx sau când nu răspunde.
  - DNS: adresele A/AAAA ale domeniului și dacă includ `PUBLIC_IP`.
  - Certificat: ce certificat servește Traefik acum pentru domeniu.
- **Șterge**: elimină fișierul; domeniul nu mai deschide ținta.

## Reguli bune de știut

- Calea din URL (`http://host:80/app`) e respinsă: Traefik o ignoră.
- Dacă același domeniu e și site sau panou WPL7, **WPL7 câștigă** (rutele de aici au `priority: 1`).
- Domeniul panoului WPL7 și al acestei pagini nu pot fi adăugate.
- Ținte respinse: `localhost`, `127.x`, `169.254.x`, `0.0.0.0`, servicii interne WPL7
  (`wpl7-*`, `mariadb`, `mail`...). E o plasă de siguranță, nu o graniță de securitate.
  Dacă ai nevoie de `host.docker.internal`, pune `PROXYUI_ALLOW_UNSAFE_TARGETS=1` în `environment`.
- Rutele nu apar în panoul WPL7; sunt vizibile doar aici sau în `ls /srv/traefik/dynamic`.

## Securitate

Pagina poate publica orice domeniu spre orice adresă internă, deci trateaz-o ca pe un panou de admin.

- Folosește o parolă lungă. După 8 încercări greșite, IP-ul e blocat 10 minute.
- Containerul are sistem de fișiere doar-citire, fără capabilități în plus și un singur volum
  (`/srv/traefik/dynamic`). Nu primește `docker.sock`, nici cheile ACME.
- Opțional, restricționează accesul pe IP: dezactivează comentariile `ipallowlist` din
  `docker-compose.yml`.
- Salvează rutele: `cp -a /srv/traefik/dynamic /root/dynamic.bak`.

## Depanare

| Simptom | Ce înseamnă |
|---|---|
| „Ținta nu răspunde: conexiune refuzată” | Nu ascultă nimic pe acel port. |
| „… timeout” | Rutare, firewall sau VPN lipsă între serverul WPL7 și ținta ta. Un VPS din cloud nu ajunge la `192.168.x.x` fără tunel. |
| „… certificatul TLS nu e acceptat” | Țintă `https://` autosemnată: bifează „Ignoră verificarea TLS”. |
| Certificat: „nu servește un certificat valid” | Încă neemis (așteaptă un minut) sau DNS-ul nu indică spre server / portul 80 nu e deschis din internet. Un AAAA vechi în DNS poate bloca emiterea. |
| Pagina nu mai răspunde după un update WPL7 | `cd /opt/wpl7-proxy-ui && docker compose up -d --force-recreate` (reatașează containerul la rețeaua `wpl7_proxy`). |

Loguri: `docker compose logs -f` (conțin adăugările/ștergerile și IP-ul de unde s-au făcut).

## Actualizare și dezinstalare

- Dacă modifici fișierele: `docker compose up -d --build`.
- Dezinstalare: `docker compose down`. Rutele rămân active (sunt fișiere în `/srv/traefik/dynamic`);
  le ștergi cu `rm /srv/traefik/dynamic/proxy-<domeniu>.yml`.

## Fișiere

`app.py` (server, doar biblioteca standard) · `static/` (pagina) · `Dockerfile` · `docker-compose.yml` · `.env.example`
