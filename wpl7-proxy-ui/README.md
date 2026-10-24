# WPL7 proxy UI

Pagină web mică pentru rute reverse-proxy în Traefik-ul din WPL7: un domeniu public care deschide o
adresă internă (`situlmeu.com` → `192.168.1.50:8080`), ca „proxy sites” din CloudPanel.
Înlocuiește comenzile din `wpl7-proxy.sh` cu un formular și butoane. Cele două unelte scriu aceleași
fișiere (`/srv/traefik/dynamic/proxy-<domeniu>.yml`), deci le poți folosi împreună.

Nu modifică WPL7: rulează ca un container separat, într-un proiect Compose separat, și nu e atinsă
de update-urile WPL7.

> **Instalare automată:** din repo-ul `wpl7plus`, `install.sh` instalează WPL7 și această pagină și
> completează `.env`. Instrucțiunile de mai jos sunt pentru instalarea **manuală**, separat de WPL7.

## Instalare (pe serverul WPL7, ca utilizator obișnuit)

Nu ai nevoie de root și nici de `/opt`: folderul poate sta oriunde, de exemplu în `/home/utilizator`.

1. În DNS: A record pentru domeniul paginii (ex. `proxy.exemplu.ro`) spre IP-ul serverului.
2. În WinSCP, urcă `wpl7-proxy-ui.tar.gz` în folderul în care intri implicit (`/home/utilizator`).
3. În PuTTY, cu același utilizator:

```bash
tar xzf wpl7-proxy-ui.tar.gz
cd wpl7-proxy-ui
cp .env.example .env
nano .env              # PROXYUI_DOMAIN, PROXYUI_PASSWORD (min. 12 caractere), PANEL_DOMAIN, PUBLIC_IP
chmod 600 .env
sudo docker compose up -d --build
sudo docker compose logs --tail 20     # trebuie să vezi „wpl7-proxy-ui pornit pe :8080”
```

Dacă utilizatorul e în grupul `docker`, `sudo` nu mai e necesar. Toate comenzile `docker compose`
de mai jos se rulează din acest folder (`cd ~/wpl7-proxy-ui`).

4. Deschide `https://proxy.exemplu.ro` (certificatul se emite în câteva secunde) și intră cu
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
- Salvează rutele: `sudo cp -a /srv/traefik/dynamic ~/dynamic.bak`.

## Ținte din altă rețea (ex. serverul în 192.168.1.x, ținta în 192.168.0.x)

Traefik ajunge la orice adresă la care ajunge serverul WPL7 însuși, deci contează doar dacă serverul
are drum până la țintă. Testează întâi de pe server: `ping -c2 192.168.0.X` și
`curl -I http://192.168.0.X:PORT`, apoi „Testează ținta” din pagină (testul din pagină e cel care contează).

Metode, de la cea mai simplă:

1. **PC2 e în spatele unui al doilea router** (cu WAN în 192.168.1.x): faci port forwarding pe acel
   router spre PC2 și folosești ca țintă `192.168.1.<IP-WAN-router>:PORT`. Nu e nevoie de rutare.
2. **Cele două rețele sunt pe același switch**: dai serverului o a doua adresă din 192.168.0.0/24
   (test: `sudo ip addr add 192.168.0.200/24 dev <interfață>`; permanent în netplan, cu `sudo netplan try`).
3. **Rută statică** prin al doilea router: `sudo ip route add 192.168.0.0/24 via 192.168.1.<IP-router>`
   (permanent în netplan, la `routes:`). Routerul trebuie să permită trafic din WAN spre LAN, ceea ce
   routerele casnice blochează implicit; de obicei metoda 1 e mai simplă.
4. **Locații diferite**: VPN (WireGuard, Tailscale) și țintă = adresa din VPN.

Atenție: WPL7 creează câte o rețea Docker /24 pentru fiecare site. Dacă `ip route | grep 192.168.0`
arată `192.168.0.0/24 dev br-...`, o rețea Docker a ocupat acea adresă și ținta nu mai e accesibilă.

## Depanare

| Simptom | Ce înseamnă |
|---|---|
| „Ținta nu răspunde: conexiune refuzată” | Nu ascultă nimic pe acel port. |
| „… timeout” | Rutare, firewall sau VPN lipsă între serverul WPL7 și ținta ta. Un VPS din cloud nu ajunge la `192.168.x.x` fără tunel. |
| „… certificatul TLS nu e acceptat” | Țintă `https://` autosemnată: bifează „Ignoră verificarea TLS”. |
| Certificat: „nu servește un certificat valid” | Încă neemis (așteaptă un minut) sau DNS-ul nu indică spre server / portul 80 nu e deschis din internet. Un AAAA vechi în DNS poate bloca emiterea. |
| Pagina nu mai răspunde după un update WPL7 | `cd ~/wpl7-proxy-ui && sudo docker compose up -d --force-recreate` (reatașează containerul la rețeaua `wpl7_proxy`). |

Loguri: `sudo docker compose logs -f` (conțin adăugările/ștergerile și IP-ul de unde s-au făcut).

## Actualizare și dezinstalare

- Dacă modifici fișierele: `sudo docker compose up -d --build`.
- Dezinstalare: `sudo docker compose down`. Rutele rămân active (sunt fișiere în `/srv/traefik/dynamic`);
  le ștergi cu `sudo rm /srv/traefik/dynamic/proxy-<domeniu>.yml`.

## Fișiere

`app.py` (server, doar biblioteca standard) · `static/` (pagina) · `Dockerfile` · `docker-compose.yml` · `.env.example`
