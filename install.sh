#!/usr/bin/env bash
# =============================================================================
# wpl7plus - instalare unificată: WPL7 + wpl7-proxy-ui
#
#   curl -fsSL https://raw.githubusercontent.com/userkbmsr-png/wpl7plus/main/install.sh | sudo bash
#
# Cu valori date direct, fără întrebări:
#   curl -fsSL .../install.sh | sudo bash -s -- --sitename=exemplu.ro --sitepassword='ParolaLunga123'
#
# Rulat din nou (când există /opt/wpl7plus/identity) nu reinstalează WPL7:
# cere din nou sitename și parola, le înlocuiește pe cele vechi și reconfigurează wpl7-proxy-ui.
# =============================================================================
set -Eeuo pipefail

# --- configurare (suprascriibilă din mediu, util mai ales pentru teste) --------
REPO="${WPL7PLUS_REPO:-userkbmsr-png/wpl7plus}"
REF="${WPL7PLUS_REF:-main}"
BASE="${WPL7PLUS_DIR:-/opt/wpl7plus}"
LOG="${WPL7PLUS_LOG:-/var/log/wpl7plus-install.log}"
POLL="${WPL7PLUS_POLL:-5}"
SRV_ROOT="${SRV_ROOT:-/srv}"
WPL7_INSTALL_URL="${WPL7_INSTALL_URL:-https://github.com/andyfo/wpl7/releases/latest/download/install.sh}"
PANEL_CONTAINER="${PANEL_CONTAINER:-wpl7-panel}"
FIRST_BOOT_TIMEOUT="${FIRST_BOOT_TIMEOUT:-900}"
PROXYUI_CONTAINER="wpl7-proxy-ui"
IDENTITY="$BASE/identity"
APP_DIR="$BASE/wpl7-proxy-ui"

ASSUME_YES=0
ARG_SITE="${SITENAME:-}"
ARG_PASS="${SITEPASSWORD:-}"
sitename=""; sitepassword=""; old_site=""; reinstall=0; wpl7_fresh=0
public_ip=""; FIRST_BOOT=""; DNS_PROBLEMS=0; TTY_OK=0

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '%s ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s !%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s ✗ %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }

usage() {
  cat <<'EOF'
wpl7plus - instalare unificată WPL7 + wpl7-proxy-ui

Utilizare:
  curl -fsSL https://raw.githubusercontent.com/userkbmsr-png/wpl7plus/main/install.sh | sudo bash
  curl -fsSL .../install.sh | sudo bash -s -- [opțiuni]

Opțiuni:
  --sitename=DOMENIU     domeniul de bază, ex. exemplu.ro (panel.exemplu.ro, proxy.exemplu.ro ...)
  --sitepassword=PAROLA  parola paginii proxy (min. 12 caractere)
  -y, --yes              la o instalare existentă continuă fără să mai întrebe
  -h, --help             acest text

Variabile de mediu echivalente: SITENAME, SITEPASSWORD.
O parolă dată în linia de comandă rămâne în istoric și în `ps`; preferă întrebarea interactivă.
EOF
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\n%s ✗ Instalarea s-a oprit (cod %s). Jurnal: %s%s\n' "$C_R" "$rc" "$LOG" "$C_0" >&2
  fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# --- validări --------------------------------------------------------------------
RE_DOMAIN='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{2,59})$'

normalize_domain() {
  local d="${1,,}"
  d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d%.}"
  printf '%s' "$d"
}

valid_domain() { [[ ${#1} -le 253 && "$1" =~ $RE_DOMAIN ]]; }

# Scrie motivul pe stdout și întoarce 1 dacă parola nu e acceptată.
# Fără ' " \ $ ` # și spații: parola ajunge neschimbată în .env (Docker Compose) și în Basic auth.
valid_password() {
  local p="$1"
  [ "${#p}" -ge 12 ] || { echo "minim 12 caractere"; return 1; }
  local LC_ALL=C
  case "$p" in
    *[!\!-\~]*) echo "doar caractere ASCII vizibile, fără spații"; return 1 ;;
    *[\'\"\\\$\`\#]*) echo "nu sunt permise caracterele ' \" \\ \$ \` #"; return 1 ;;
  esac
  return 0
}

is_ipv4() {
  local ip="$1" o IFS=.
  local -a p
  read -ra p <<<"$ip"
  [ "${#p[@]}" -eq 4 ] || return 1
  for o in "${p[@]}"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] && [ "$o" -le 255 ] || return 1
  done
}

# --- intrare de la utilizator ---------------------------------------------------------
# IMPORTANT: se citește de pe /dev/tty (stdin e scriptul însuși când rulează prin pipe) și ÎN SHELL-UL
# PRINCIPAL, nu în $(...): cu `curl | sudo bash` sudo-rs (Ubuntu 26.04) pornește comanda în fundalul
# pseudo-terminalului lui, iar un subshell care citește de pe terminal primește SIGTTIN și rămâne oprit
# (sudo-rs vede doar procesul direct, nu subshell-ul). De aceea ask() setează variabila REPLY_VALUE.
REPLY_VALUE=""
ask() {  # ask "prompt" [silent]  ->  REPLY_VALUE
  local prompt="$1" silent="${2:-}" rc=0
  REPLY_VALUE=""
  printf '%s' "$prompt" >/dev/tty
  if [ "$silent" = silent ]; then
    IFS= read -rs REPLY_VALUE </dev/tty || rc=$?
    printf '\n' >/dev/tty
  else
    IFS= read -r REPLY_VALUE </dev/tty || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    die "Nu pot citi de la tastatură (terminal indisponibil sau intrare închisă). Rulează în schimb:  sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/$REPO/$REF/install.sh)\"  sau dă valorile ca opțiuni (--sitename=… --sitepassword=…)."
  fi
}

kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 || true; }

# --- așteptare cu cronometru ------------------------------------------------------
# wait_for "mesaj" limită_secunde comandă...   (întoarce 0 când comanda reușește, 1 la timeout)
wait_for() {
  local msg="$1" limit="$2" start=$SECONDS el last=-30
  shift 2
  while ! "$@"; do
    el=$((SECONDS - start))
    if [ "$el" -ge "$limit" ]; then
      if [ -t 1 ]; then printf '\r\033[K'; fi
      return 1
    fi
    if [ -t 1 ]; then
      printf '\r\033[K  %s ... %02d:%02d' "$msg" $((el / 60)) $((el % 60))
    elif [ $((el - last)) -ge 30 ]; then
      printf '  %s ... %ds\n' "$msg" "$el"; last=$el
    fi
    sleep "$POLL"
  done
  if [ -t 1 ]; then printf '\r\033[K'; fi
  return 0
}

first_boot_probe() {
  FIRST_BOOT="$(docker logs "$PANEL_CONTAINER" 2>&1 | grep -m1 -A2 'First boot' || true)"
  [ -n "$FIRST_BOOT" ]
}
proxyui_healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$PROXYUI_CONTAINER" 2>/dev/null || true)" = healthy ]; }
route_ok() {
  curl -sk --max-time 5 --resolve "proxy.$sitename:443:127.0.0.1" "https://proxy.$sitename/healthz" 2>/dev/null </dev/null | grep -qx ok
}
wpl7_present() { docker container inspect "$PANEL_CONTAINER" >/dev/null 2>&1; }

# --- rețea -------------------------------------------------------------------------
get_public_ip() {
  local u ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4fsS --max-time 8 "$u" 2>/dev/null </dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

check_dns() {
  local h got
  DNS_PROBLEMS=0
  for h in "panel.$sitename" "proxy.$sitename"; do
    got="$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    got="${got% }"
    if [ -z "$got" ]; then
      warn "DNS: $h nu are (încă) un record A"; DNS_PROBLEMS=$((DNS_PROBLEMS + 1))
    elif [ -n "$public_ip" ] && [[ " $got " != *" $public_ip "* ]]; then
      warn "DNS: $h → $got (nu include IP-ul public $public_ip)"; DNS_PROBLEMS=$((DNS_PROBLEMS + 1))
    else
      ok "DNS: $h → $got"
    fi
  done
}

# --- pașii ---------------------------------------------------------------------------
parse_args() {
  local a
  for a in "$@"; do
    case "$a" in
      --sitename=*)     ARG_SITE="${a#*=}" ;;
      --sitepassword=*) ARG_PASS="${a#*=}" ;;
      -y|--yes)         ASSUME_YES=1 ;;
      -h|--help)        usage; exit 0 ;;
      *) die "Opțiune necunoscută: $a (vezi --help)" ;;
    esac
  done
}

preflight() {
  local t
  [ "$(id -u)" -eq 0 ] || die "Rulează ca root: curl -fsSL <url> | sudo bash"
  for t in curl tar awk sed grep getent; do
    command -v "$t" >/dev/null 2>&1 || die "Lipsește comanda '$t' (apt-get install -y $t)."
  done
  mkdir -p "$(dirname "$LOG")"
  : >>"$LOG"; chmod 600 "$LOG"
  if (exec </dev/tty) 2>/dev/null; then TTY_OK=1; fi
}

existing_install_gate() {
  local answer
  reinstall=1
  old_site="$(kv "$IDENTITY" sitename)"
  step "Instalare existentă găsită"
  say "  Fișier: $IDENTITY  (sitename=${old_site:-?})"
  say "  Dacă continui, WPL7 NU se mai descarcă și nu se reinstalează."
  say "  Îți cer din nou sitename și parola, le înlocuiesc pe cele vechi și reconfigurez wpl7-proxy-ui."
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  [ "$TTY_OK" = 1 ] || die "Instalare existentă și nu am terminal pentru confirmare. Adaugă --yes pentru a continua."
  ask "Continui? [d/N]: "
  answer="$REPLY_VALUE"
  case "${answer,,}" in
    d|da|y|yes) ;;
    *) say "Renunțat. Nu s-a modificat nimic."; exit 0 ;;
  esac
}

collect_identity() {
  local v p1 p2 why tries=0

  if [ -n "$ARG_SITE" ]; then
    sitename="$(normalize_domain "$ARG_SITE")"
    valid_domain "$sitename" || die "sitename invalid: '$ARG_SITE' (scrie doar domeniul, ex. exemplu.ro)"
  else
    [ "$TTY_OK" = 1 ] || die "Nu am terminal pentru întrebări. Folosește --sitename=… și --sitepassword=… (vezi --help)."
    while :; do
      tries=$((tries + 1)); [ "$tries" -le 5 ] || die "Prea multe încercări."
      if [ -n "$old_site" ]; then
        ask "sitename (domeniul, ex. exemplu.ro) [$old_site]: "
        v="$REPLY_VALUE"
        [ -n "$v" ] || v="$old_site"
      else
        ask "sitename (domeniul, ex. exemplu.ro): "
        v="$REPLY_VALUE"
      fi
      v="$(normalize_domain "$v")"
      if valid_domain "$v"; then sitename="$v"; break; fi
      warn "Domeniu invalid. Scrie doar domeniul, fără https:// și fără panel./proxy. în față."
    done
  fi

  if [ -n "$ARG_PASS" ]; then
    why="$(valid_password "$ARG_PASS" || true)"
    [ -z "$why" ] || die "sitepassword invalid: $why"
    sitepassword="$ARG_PASS"
  else
    [ "$TTY_OK" = 1 ] || die "Nu am terminal pentru întrebări. Folosește --sitepassword=… (vezi --help)."
    tries=0
    while :; do
      tries=$((tries + 1)); [ "$tries" -le 5 ] || die "Prea multe încercări."
      ask "sitepassword (parola paginii proxy, min. 12 caractere): " silent
      p1="$REPLY_VALUE"
      why="$(valid_password "$p1" || true)"
      if [ -n "$why" ]; then warn "Parolă respinsă: $why."; continue; fi
      ask "Repetă parola: " silent
      p2="$REPLY_VALUE"
      if [ "$p1" = "$p2" ]; then sitepassword="$p1"; break; fi
      warn "Parolele nu coincid."
    done
  fi
}

write_identity() {
  local tmp
  mkdir -p "$BASE"; chmod 700 "$BASE"
  tmp="$(mktemp "$BASE/.identity.XXXXXX")"
  printf 'sitename=%s\nsitepassword=%s\n' "$sitename" "$sitepassword" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$IDENTITY"
}

install_wpl7() {
  local tmp
  step "[2/5] Instalez WPL7 (durează câteva minute; ieșirea e salvată și în $LOG)"
  tmp="$(mktemp /tmp/wpl7-install.XXXXXX)"
  if ! curl -fsSL "$WPL7_INSTALL_URL" -o "$tmp" </dev/null; then
    rm -f "$tmp"; die "Nu pot descărca installer-ul WPL7 de la $WPL7_INSTALL_URL"
  fi
  say "  bash install.sh --panel-domain=panel.$sitename --dev-domain=dev.$sitename --acme-email=admin@$sitename"
  if ! bash "$tmp" "--panel-domain=panel.$sitename" "--dev-domain=dev.$sitename" "--acme-email=admin@$sitename" \
        </dev/null 2>&1 | tee -a "$LOG"; then
    rm -f "$tmp"; die "Installer-ul WPL7 a eșuat. Vezi $LOG"
  fi
  rm -f "$tmp"
  ok "Installer-ul WPL7 s-a încheiat"
}

wait_first_boot() {
  step "[3/5] Aștept prima pornire a WPL7"
  say "  Verific la câteva secunde: docker logs $PANEL_CONTAINER | grep -A2 'First boot' (limită $((FIRST_BOOT_TIMEOUT / 60)) min)"
  if wait_for "WPL7 pornește" "$FIRST_BOOT_TIMEOUT" first_boot_probe; then
    ok "WPL7 a pornit. Date pentru prima autentificare:"
    printf '%s\n' "$FIRST_BOOT" | sed 's/^/      /'
  else
    warn "Nu am găsit 'First boot' în $((FIRST_BOOT_TIMEOUT / 60)) min. Continui; verifică apoi: docker logs $PANEL_CONTAINER 2>&1 | grep -A2 'First boot'"
  fi
}

UI_REQUIRED=(app.py Dockerfile docker-compose.yml static/index.html static/app.js static/app.css)

ui_missing() {  # ui_missing DIR -> fișierele lipsă, câte unul pe linie
  local d="$1" f
  for f in "${UI_REQUIRED[@]}"; do
    if [ ! -f "$d/$f" ]; then printf '%s\n' "$f"; fi
  done
}
ui_complete() { [ -z "$(ui_missing "$1")" ]; }

# Aduce wpl7-proxy-ui în $APP_DIR: din folderul de lângă script (checkout local) sau din arhiva repo-ului.
# Acceptă folderul wpl7-proxy-ui/ din rădăcina repo-ului sau, la nevoie, fișierele puse direct în rădăcină.
fetch_proxy_ui() {
  local src="" d="" tmp="" cand diag miss
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ui_complete "$d/wpl7-proxy-ui"; then src="$d/wpl7-proxy-ui"; fi
  fi
  if [ -n "$src" ]; then
    say "  Copiez wpl7-proxy-ui din $src"
  else
    say "  Descarc repo-ul github.com/$REPO ($REF)"
    tmp="$(mktemp -d /tmp/wpl7plus-repo.XXXXXX)"
    if ! curl -fsSL "https://github.com/$REPO/archive/refs/heads/$REF.tar.gz" -o "$tmp/repo.tar.gz" </dev/null; then
      rm -rf "$tmp"
      die "Nu pot descărca github.com/$REPO (ramura '$REF'). Repo-ul e public și ramura există?"
    fi
    mkdir "$tmp/repo"
    if ! tar xzf "$tmp/repo.tar.gz" -C "$tmp/repo" --strip-components=1; then
      rm -rf "$tmp"; die "Arhiva repo-ului nu poate fi citită."
    fi
    for cand in "$tmp/repo/wpl7-proxy-ui" "$tmp/repo"; do
      if ui_complete "$cand"; then src="$cand"; break; fi
    done
    if [ -z "$src" ]; then
      diag="$tmp/repo"
      if [ -d "$tmp/repo/wpl7-proxy-ui" ]; then diag="$tmp/repo/wpl7-proxy-ui"; fi
      miss="$(ui_missing "$diag")"
      warn "wpl7-proxy-ui e incomplet în github.com/$REPO (ramura $REF). Lipsesc:"
      printf '%s\n' "$miss" | sed 's/^/      /' >&2
      warn "Conținutul repo-ului (primele niveluri):"
      (cd "$tmp/repo" && find . -maxdepth 2 -not -path './.git*' | sort | head -40) | sed 's/^/      /' >&2
      rm -rf "$tmp"
      die "Urcă folderul wpl7-proxy-ui/ complet (cu static/ în el) în rădăcina repo-ului și rulează din nou."
    fi
    d="${src#"$tmp"/repo}"
    say "  Folosesc ${d:-rădăcina repo-ului}"
  fi
  rm -rf "${APP_DIR:?}/static"
  cp -a "$src/." "$APP_DIR/"
  if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}

write_env() {
  local panel_domain="panel.$sitename" env="$APP_DIR/.env" old_panel tmp
  # La o rulare repetată (WPL7 neatins) domeniul real al panoului e cel din .env, nu neapărat panel.<sitename> nou.
  if [ "$reinstall" = 1 ] && [ "$wpl7_fresh" != 1 ] && [ -f "$env" ]; then
    old_panel="$(kv "$env" PANEL_DOMAIN)"
    if [ -n "$old_panel" ]; then
      panel_domain="$old_panel"
      if [ "$sitename" != "$old_site" ] && [ "$old_panel" != "panel.$sitename" ]; then
        warn "WPL7 rămâne configurat cu $old_panel (nu îl reinstalez). Schimbarea afectează doar pagina proxy: proxy.$sitename."
      fi
    fi
  fi
  tmp="$(mktemp "$APP_DIR/.env.XXXXXX")"
  {
    printf 'PROXYUI_DOMAIN=proxy.%s\n' "$sitename"
    printf 'PROXYUI_USER=admin\n'
    printf 'PROXYUI_PASSWORD=%s\n' "$sitepassword"
    printf 'PANEL_DOMAIN=%s\n' "$panel_domain"
    printf 'PUBLIC_IP=%s\n' "$public_ip"
    printf 'SRV_ROOT=%s\n' "$SRV_ROOT"
    printf 'ACME_RESOLVER=letsencrypt\n'
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$env"
}

install_proxy_ui() {
  local -a up=(-d --build)
  step "[4/5] Instalez wpl7-proxy-ui"
  command -v docker >/dev/null 2>&1 || die "Docker nu e instalat."
  docker network inspect wpl7_proxy >/dev/null 2>&1 \
    || die "Rețeaua Docker wpl7_proxy nu există: WPL7 nu rulează (verifică: docker ps)."
  [ -d "$SRV_ROOT/traefik/dynamic" ] \
    || die "Nu găsesc $SRV_ROOT/traefik/dynamic: WPL7 pare instalat în altă locație (rulează cu SRV_ROOT=...)."

  mkdir -p "$APP_DIR"
  if ui_complete "$APP_DIR"; then
    ok "Fișierele wpl7-proxy-ui există deja în $APP_DIR"
  else
    if [ -f "$APP_DIR/app.py" ]; then
      warn "wpl7-proxy-ui din $APP_DIR e incomplet (lipsește: $(ui_missing "$APP_DIR" | tr '\n' ' ')). Îl descarc din nou."
    fi
    fetch_proxy_ui
    ui_complete "$APP_DIR" || die "wpl7-proxy-ui rămâne incomplet în $APP_DIR."
    ok "Fișierele wpl7-proxy-ui sunt în $APP_DIR"
  fi
  write_env
  ok "Am scris $APP_DIR/.env (PROXYUI_DOMAIN=proxy.$sitename, PUBLIC_IP=${public_ip:-necunoscut})"

  if [ "$reinstall" = 1 ]; then up+=(--force-recreate); fi
  say "  docker compose up ${up[*]}"
  if ! (cd "$APP_DIR" && docker compose up "${up[@]}" </dev/null) 2>&1 | tee -a "$LOG"; then
    die "docker compose up a eșuat. Vezi $LOG"
  fi

  if ! wait_for "Pornesc $PROXYUI_CONTAINER" 120 proxyui_healthy; then
    docker logs --tail 20 "$PROXYUI_CONTAINER" 2>&1 | sed 's/^/    /' >&2 || true
    die "$PROXYUI_CONTAINER nu a devenit sănătos. Vezi: cd $APP_DIR && docker compose logs"
  fi
  ok "Containerul $PROXYUI_CONTAINER rulează"
  if wait_for "Verific ruta prin Traefik" 60 route_ok; then
    ok "Traefik a preluat ruta https://proxy.$sitename"
  else
    warn "Traefik nu a preluat încă ruta (verifică: docker logs wpl7-traefik)."
  fi
}

summary() {
  step "[5/5] Instalare finalizată"
  if [ -z "$FIRST_BOOT" ]; then first_boot_probe || true; fi
  say ""
  say "  WPL7 e disponibil la adresa https://panel.$sitename"
  say "      utilizator: admin"
  if [ -n "$FIRST_BOOT" ]; then
    say "      parola de la prima pornire:"
    printf '%s\n' "$FIRST_BOOT" | sed 's/^/        /'
  else
    say "      parola: docker logs $PANEL_CONTAINER 2>&1 | grep -A2 'First boot'"
    say "      (dacă nu mai apare, containerul a fost recreat; parola se poate reseta din panou/CLI)"
  fi
  say ""
  say "  wpl7-proxy e disponibil la adresa https://proxy.$sitename"
  say "      utilizator: admin"
  say "      parola: cea introdusă acum (salvată în $IDENTITY)"
  say ""
  say "  Fișiere: $BASE   Jurnal: $LOG"
  check_dns
  if [ "$DNS_PROBLEMS" -gt 0 ]; then
    say ""
    say "  De făcut: la furnizorul DNS creează A record-uri pentru panel.$sitename și proxy.$sitename"
    say "  (și pe cele cerute de WPL7 pentru *.dev.$sitename) către ${public_ip:-IP-ul public al serverului}."
    say "  Certificatele HTTPS se emit după ce DNS-ul indică spre server."
  fi
}

main() {
  parse_args "$@"
  preflight

  step "wpl7plus - instalare unificată WPL7 + wpl7-proxy-ui"
  if [ -f "$IDENTITY" ]; then existing_install_gate; fi

  step "[1/5] Date de identitate"
  collect_identity
  write_identity
  ok "sitename=$sitename; salvat în $IDENTITY (acces doar root)"

  public_ip="$(get_public_ip || true)"
  if [ -n "$public_ip" ]; then
    ok "IP public detectat: $public_ip"
  else
    warn "Nu pot afla IP-ul public; PUBLIC_IP rămâne gol în .env."
  fi

  if command -v docker >/dev/null 2>&1 && wpl7_present; then
    step "[2/5] WPL7"
    ok "WPL7 e deja instalat (containerul $PANEL_CONTAINER există) - nu îl mai descarc"
    step "[3/5] Prima pornire"
    ok "Sar peste: WPL7 rulează deja"
  else
    if [ "$reinstall" = 1 ]; then
      warn "Există $IDENTITY, dar WPL7 nu e instalat (instalarea anterioară a fost întreruptă?). Îl instalez acum."
    fi
    check_dns
    install_wpl7
    wpl7_fresh=1
    wait_first_boot
  fi

  install_proxy_ui
  summary
}

main "$@"
