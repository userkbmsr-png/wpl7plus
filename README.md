# wpl7plus

Instalare într-o singură comandă pentru [WPL7](https://github.com/andyfo/wpl7) (hosting WordPress
self-hosted) plus **wpl7-proxy-ui**, pagina web pentru rute proxy (domeniu public → adresă internă,
ca „proxy sites” din CloudPanel).

## Instalare

Pe un server Ubuntu 26.04 (cerința WPL7), ca utilizator cu `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/userkbmsr-png/wpl7plus/main/install.sh | sudo bash
```

Scriptul te întreabă două lucruri:

| Variabilă | Ce e | Folosit pentru |
|---|---|---|
| `sitename` | domeniul tău de bază, ex. `exemplu.ro` | `panel.exemplu.ro`, `dev.exemplu.ro`, `admin@exemplu.ro` (WPL7) și `proxy.exemplu.ro` (pagina proxy) |
| `sitepassword` | parola paginii proxy, minim 12 caractere | utilizatorul `admin` al paginii proxy |

Parola poate conține litere, cifre și simboluri, dar nu spații și nici `'` `"` `\` `$` `` ` `` `#`
(ajunge neschimbată în `.env`). Se cere de două ori și nu se afișează.

> **Adresa corectă:** fișierele brute se descarcă de la `raw.githubusercontent.com/<utilizator>/<repo>/<ramură>/…`.
> O adresă de forma `github.com/<utilizator>/<repo>/install.sh` nu returnează fișierul.
> Dacă ramura principală nu se numește `main`, înlocuiește-o în adresă și rulează cu
> `sudo WPL7PLUS_REF=<ramură> bash`.

## Ce face, pas cu pas

1. Cere `sitename` și `sitepassword` și le scrie în `/opt/wpl7plus/identity` (doar root).
2. Descarcă și rulează installer-ul WPL7:
   `--panel-domain=panel.<sitename> --dev-domain=dev.<sitename> --acme-email=admin@<sitename>`.
3. Așteaptă prima pornire (cronometru pe ecran): verifică la câteva secunde
   `docker logs wpl7-panel | grep -A2 'First boot'` și afișează rezultatul (parola de prima autentificare).
   Limită: 15 minute; după aceea continuă și îți spune ce comandă să rulezi.
4. Instalează wpl7-proxy-ui în `/opt/wpl7plus/wpl7-proxy-ui` și completează `.env`:
   `PROXYUI_DOMAIN=proxy.<sitename>`, `PROXYUI_USER=admin`, `PROXYUI_PASSWORD=<sitepassword>`,
   `PANEL_DOMAIN=panel.<sitename>`, `PUBLIC_IP=<IP-ul public, aflat automat>`. Apoi pornește containerul
   și verifică local că Traefik a preluat ruta.
5. Afișează adresele, utilizatorii, parola WPL7 de la prima pornire și, dacă DNS-ul nu indică încă
   spre server, ce A record-uri mai trebuie create.

Ieșirea installer-ului WPL7 și a `docker compose` se salvează în `/var/log/wpl7plus-install.log`
(doar root). Parola paginii proxy nu se afișează și nu intră în jurnal.

**Înainte să rulezi:** creează la furnizorul DNS A record-uri pentru `panel.<sitename>` și
`proxy.<sitename>` (și cele cerute de WPL7 pentru `*.dev.<sitename>`) către IP-ul public al serverului.
Fără ele instalarea merge, dar certificatele HTTPS nu se emit până nu indică DNS-ul spre server.

## Rulare repetată

Dacă există `/opt/wpl7plus/identity`, scriptul anunță instalarea existentă și întreabă dacă continui
(implicit **nu**: Enter = renunțare, nu se modifică nimic). Dacă continui:

- WPL7 **nu** se descarcă și nu se reinstalează;
- ți se cer din nou `sitename` (Enter păstrează valoarea veche) și `sitepassword`, iar valorile noi
  le înlocuiesc pe cele vechi în `identity` și în `.env`;
- containerul wpl7-proxy-ui se recreează cu noile valori.

Dacă schimbi `sitename`, WPL7 rămâne configurat cu domeniile vechi (nu îl reinstalează nimeni);
se schimbă doar adresa paginii proxy, iar `PANEL_DOMAIN` din `.env` păstrează domeniul real al panoului.
Dacă `identity` există dar WPL7 nu e instalat (instalare întreruptă), scriptul îl instalează.

## Opțiuni

```bash
curl -fsSL …/install.sh | sudo bash -s -- --sitename=exemplu.ro --sitepassword='ParolaLunga123' --yes
```

`--sitename=`, `--sitepassword=`, `-y/--yes` (la rulare repetată continuă fără întrebare), `-h/--help`.

Dacă terminalul nu răspunde la întrebări (de exemplu pe un sistem cu alt `sudo`), rulează varianta care
păstrează tastatura legată de script:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/userkbmsr-png/wpl7plus/main/install.sh)"
```
Echivalent prin mediu: `sudo SITENAME=… SITEPASSWORD=… bash`. O parolă dată în linia de comandă rămâne
în istoric și în `ps`; pentru uz normal lasă scriptul să o ceară.

## Fișiere pe server

| Cale | Conținut |
|---|---|
| `/opt/wpl7plus/identity` | `sitename=…` și `sitepassword=…` (text clar, permisiuni 600, doar root) |
| `/opt/wpl7plus/wpl7-proxy-ui/` | pagina proxy (cod, `docker-compose.yml`, `.env`) |
| `/var/log/wpl7plus-install.log` | jurnalul instalării |
| `/srv/traefik/dynamic/proxy-*.yml` | rutele create din pagina proxy |

## Securitate

- `curl … | sudo bash` execută cod de pe internet ca root; la fel face și installer-ul WPL7. Dacă
  preferi să citești întâi: `curl -fsSL …/install.sh -o install.sh && less install.sh && sudo bash install.sh`.
- Parola din `identity` și `.env` e în text clar; fișierele sunt 600 și folderul 700.
- Detalii despre pagina proxy (securitate, depanare, rute către alte rețele): `wpl7-proxy-ui/README.md`.

## Dezinstalare pagina proxy

```bash
cd /opt/wpl7plus/wpl7-proxy-ui && sudo docker compose down
sudo rm -rf /opt/wpl7plus        # șterge și identity
```
Rutele rămân active (fișierele din `/srv/traefik/dynamic`); le ștergi cu
`sudo rm /srv/traefik/dynamic/proxy-<domeniu>.yml`. WPL7 se dezinstalează după documentația lui.

## Notă tehnică

`curl … | sudo bash` trimite scriptul prin stdin, deci întrebările se citesc de pe `/dev/tty`. Pe Ubuntu 26.04 `sudo` este
`sudo-rs`, care în acest caz pornește comanda în fundalul unui pseudo-terminal propriu: o citire de pe terminal făcută
într-un subshell (`$(...)`) se blochează. `install.sh` citește de aceea doar în shell-ul principal și e testat cu `sudo-rs`
0.2.13, cu `sudo` 1.9 și fără `sudo`. Dacă modifici scriptul, nu muta citirile din `ask()` într-un `$(...)`.

## Structura acestui repo

```
install.sh            instalatorul unificat
wpl7-proxy-ui/        pagina proxy (app.py, static/, Dockerfile, docker-compose.yml, …)
wpl7-proxy.sh         varianta în linie de comandă pentru rute (opțională)
```
`install.sh` descarcă `wpl7-proxy-ui/` din arhiva acestui repo (ramura `main`), deci repo-ul trebuie să fie
public și să conțină folderul `wpl7-proxy-ui/` la rădăcină.
