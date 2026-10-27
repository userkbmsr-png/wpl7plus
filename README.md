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
- containerul wpl7-proxy-ui se recreează cu noile valori;
- dacă folderul `/opt/wpl7plus/wpl7-proxy-ui` e incomplet (de exemplu a rămas așa după o rulare eșuată), se descarcă
  din nou din repo; dacă e complet, nu se atinge (modificările locale rămân).

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

## Dezinstalare

```bash
curl -fsSL https://raw.githubusercontent.com/userkbmsr-png/wpl7plus/main/uninstall.sh | sudo bash
```

Scriptul arată mai întâi ce a găsit (containere, dimensiunea datelor, firewall), te întreabă ce să dezinstaleze,
afișează planul și cere confirmare. Recomandat: rulează întâi cu `--dry-run`, care nu schimbă nimic.

| Variantă | Ce face | Confirmare |
|---|---|---|
| `--only-proxy-ui` | șterge doar pagina wpl7-proxy-ui (container, imagine, fișiere); WPL7, datele și rutele rămân | `d` |
| `--keep-data` | șterge tot (WPL7 + pagina), dar **păstrează datele** din `/srv`; `/opt/wpl7` se mută în `/opt/wpl7.removed-<data>` | sitename-ul |
| `--purge-data` | șterge tot, **inclusiv datele** (site-uri, baze de date, backup-uri, certificate) — **ireversibil** | `STERGE TOT` |

Ce face varianta completă, în ordine: șterge pagina proxy; oprește stack-ul WPL7 (întâi panoul, ca să nu recreeze
containerele site-urilor), apoi șterge containerele `wpl7-*` și `wp-*`, rețelele `wpl7_*` și imaginile folosite de WPL7
(cele folosite și de alte containere rămân); dezactivează firewall-ul WPL7 (unitate, script, tabela `nft` `inet wpl7`);
scoate cheia panoului din `/root/.ssh/authorized_keys`; șterge `/opt/wpl7plus` (identity, pagina) și jurnalul instalării.

Opțiuni: `--dry-run`, `-y/--yes` (obligatoriu fără terminal), `--remove-routes` (cu `--only-proxy-ui`: șterge și
`proxy-*.yml`), `--keep-images`, `--remove-swap`, `--close-ports` (UFW 80/443), `--remove-docker`, `--srv-root=`,
`--wpl7-dir=`. Exemplu fără întrebări: `… | sudo bash -s -- --keep-data --yes`.

**Nu se ating niciodată:** pachetele de bază (curl, git, ufw, jq, openssl, nftables), regulile UFW pentru SSH și
politicile implicite UFW, alte containere/rețele/volume Docker, `BACKUP_ROOT` (dacă backup-urile sunt pe alt disc) și
alte directoare din `/srv` în afară de cele ale WPL7. Swap-ul, porturile 80/443 și Docker se elimină doar la cerere.
La `--keep-data`, arhiva `/opt/wpl7.removed-<data>` păstrează `deploy/.env` (parola MariaDB): baza de date din
`/srv/mysql` nu poate fi folosită cu alt `.env`.

WPL7 nu are dezinstalare oficială; scriptul se bazează pe ce face `provision/setup.sh` (versiunea 0.3.2). Dacă o
versiune nouă adaugă alte elemente, vor rămâne pe server; verifică lista „Rămân, intenționat” de la final.

## Notă tehnică

`curl … | sudo bash` trimite scriptul prin stdin, deci întrebările se citesc de pe `/dev/tty`. Pe Ubuntu 26.04 `sudo` este
`sudo-rs`, care în acest caz pornește comanda în fundalul unui pseudo-terminal propriu: o citire de pe terminal făcută
într-un subshell (`$(...)`) se blochează. `install.sh` citește de aceea doar în shell-ul principal și e testat cu `sudo-rs`
0.2.13, cu `sudo` 1.9 și fără `sudo`. Dacă modifici scriptul, nu muta citirile din `ask()` într-un `$(...)`.

## Structura acestui repo

```
install.sh                      instalatorul unificat
uninstall.sh                    dezinstalarea (WPL7 + wpl7-proxy-ui)
wpl7-proxy-ui/
  app.py  Dockerfile  docker-compose.yml  .env.example  README.md
  static/  index.html  app.js  app.css
wpl7-proxy.sh                   varianta în linie de comandă pentru rute (opțională)
```

`install.sh` descarcă arhiva acestui repo de pe GitHub (ramura `main`), deci repo-ul trebuie să fie public și să
conțină folderul `wpl7-proxy-ui/` **complet**, cu `static/` în el. Scriptul verifică fișierele de mai sus; dacă
lipsește ceva, afișează ce lipsește și ce conține repo-ul. Acceptă și fișierele puse direct în rădăcina repo-ului.

Ca să vezi exact ce servește GitHub (de pe orice server, fără autentificare):

```bash
curl -fsSL https://github.com/userkbmsr-png/wpl7plus/archive/refs/heads/main.tar.gz | tar tz | head -40
```

La urcarea pe GitHub din browser, trage **folderul** `wpl7-proxy-ui` (nu doar fișierele din el) în pagina „Upload files”,
altfel subfolderul `static/` nu ajunge în repo. Mai sigur: `git add . && git commit && git push`.
