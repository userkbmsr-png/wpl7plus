#!/usr/bin/env bash
# =============================================================================
# wpl7plus - dezinstalare: WPL7 + wpl7-proxy-ui
#
#   curl -fsSL https://raw.githubusercontent.com/userkbmsr-png/wpl7plus/main/uninstall.sh | sudo bash
#
# Începe întotdeauna prin a arăta ce a găsit și ce va face, apoi cere confirmare.
# Datele (site-uri, baze de date, backup-uri, certificate) se șterg DOAR cu --purge-data.
#   --dry-run  arată ce s-ar face, fără să schimbe nimic        -h/--help  toate opțiunile
# =============================================================================
set -Eeuo pipefail

PREFIX="${UNINSTALL_ROOT:-}"          # doar pentru teste: prefix pus în fața tuturor căilor de pe gazdă
P() { printf '%s%s' "$PREFIX" "$1"; }

WPL7_DIR="$(P /opt/wpl7)"
PLUS_DIR="$(P /opt/wpl7plus)"
LOG="$(P /var/log/wpl7plus-uninstall.log)"
UI_NAME="wpl7-proxy-ui"; UI_IMAGE="wpl7-proxy-ui:local"
ARG_SCOPE=""; ARG_SRV=""; ASSUME_YES=0; DRY=0
REMOVE_ROUTES=0; KEEP_IMAGES=0; REMOVE_SWAP=0; CLOSE_PORTS=0; REMOVE_DOCKER=0
TTY_OK=0; REPLY_VALUE=""; LOG_READY=0
SRV_ROOT=""; SCOPE=""; HAVE_DOCKER=0
UI_CONTAINER=0; UI_IMAGE_PRESENT=0; WPL7_PRESENT=0
STACK_CONTAINERS=""; SITE_CONTAINERS=""; NETWORKS=""; VOLUMES=""; IMAGE_REFS=""
FW_PRESENT=0; SITENAME=""; WPL7_VERSION=""; BACKUP_ROOT=""
DAEMON_JSON_IS_WPL7=0
WARNS=(); DONE=(); REMAIN=()

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
note() { if [ "$LOG_READY" = 1 ]; then printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; fi; }

usage() {
  cat <<'EOF'
wpl7plus - dezinstalare WPL7 + wpl7-proxy-ui

  curl -fsSL https://raw.githubusercontent.com/userkbmsr-png/wpl7plus/main/uninstall.sh | sudo bash
  curl -fsSL .../uninstall.sh | sudo bash -s -- [opțiuni]

Ce se dezinstalează (alege una; fără opțiune, scriptul te întreabă):
  --only-proxy-ui    doar pagina wpl7-proxy-ui (container, imagine, /opt/wpl7plus/wpl7-proxy-ui);
                     WPL7, datele și rutele proxy rămân
  --keep-data        tot (WPL7 + pagina), dar PĂSTREAZĂ datele din /srv (site-uri, baze de date,
                     backup-uri, certificate); /opt/wpl7 e mutat în /opt/wpl7.removed-<data>, cu .env
  --purge-data       tot, ȘTERGÂND și datele din /srv (IREVERSIBIL)

Opțiuni:
  --dry-run          arată ce s-ar face, fără să schimbe nimic
  -y, --yes          nu cere confirmare (obligatoriu fără terminal)
  --remove-routes    cu --only-proxy-ui: șterge și rutele proxy-*.yml create din pagină
  --keep-images      nu șterge imaginile Docker
  --remove-swap      șterge /swapfile creat de WPL7 (doar dacă există; poate ridica presiunea pe memorie)
  --close-ports      șterge din UFW regulile pentru 80/tcp și 443/tcp (SSH și restul rămân)
  --remove-docker    dezinstalează pachetele Docker, dacă nu mai rămâne niciun container
  --srv-root=CALE    rădăcina datelor WPL7 (implicit: cea din /etc/default/wpl7-firewall sau /srv)
  --wpl7-dir=CALE    directorul de instalare WPL7 (implicit: /opt/wpl7)
  -h, --help         acest text

Nu se ating niciodată: pachetele de bază (curl, git, ufw, jq, openssl, nftables ...), regulile UFW pentru SSH,
politicile implicite UFW, alte containere/rețele/volume Docker și BACKUP_ROOT (dacă backup-urile sunt pe alt disc).
EOF
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\n%s ✗ Dezinstalarea s-a oprit (cod %s).%s%s\n' "$C_R" "$rc" "$([ "$LOG_READY" = 1 ] && printf ' Jurnal: %s' "$LOG")" "$C_0" >&2
  fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# --- execuție (dry-run) și ștergeri sigure ---------------------------------------------
run() {
  note "run: $*"
  if [ "$DRY" = 1 ]; then printf '   [dry-run] %s\n' "$*"; return 0; fi
  "$@"
}
try() {  # try "descriere" comandă...  : o eroare nu oprește dezinstalarea, dar se raportează la final
  local d="$1"; shift
  if ! run "$@"; then WARNS+=("$d"); warn "$d: a eșuat (continui)"; fi
}
quiet() { run "$@" >/dev/null 2>&1 || true; }

is_sysdir() {  # is_sysdir CALE_FĂRĂ_PREFIX : adevărat pentru directoare de sistem, care nu se șterg niciodată
  case "$1" in
    ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/var/log) return 0 ;;
  esac
  return 1
}

safe_rm_rf() {  # safe_rm_rf CALE...
  local p
  for p in "$@"; do
    [[ "$p" == /* && "$p" != *..* ]] || die "refuz să șterg '$p' (cale nesigură)"
    if is_sysdir "${p#"$PREFIX"}"; then die "refuz să șterg directorul de sistem '${p#"$PREFIX"}'"; fi
    if [ -e "$p" ] || [ -L "$p" ]; then run rm -rf -- "$p"; fi
  done
}

# --- intrare de la utilizator (de pe /dev/tty, în shell-ul principal, nu în $(...)) -------
ask() {  # ask "prompt"  ->  REPLY_VALUE
  local prompt="$1" rc=0
  REPLY_VALUE=""
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r REPLY_VALUE </dev/tty || rc=$?
  if [ "$rc" -ne 0 ]; then die "Nu pot citi de la tastatură. Dă opțiunile în linia de comandă (vezi --help)."; fi
}
interactive() { [ "$TTY_OK" = 1 ] && [ "$ASSUME_YES" != 1 ]; }

kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 || true; }
size_of() { timeout 30 du -sh -- "$1" 2>/dev/null | awk '{print $1}' || true; }
count_lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c . || true; fi; }

# --- Docker: citiri ----------------------------------------------------------------------
stack_containers() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^wpl7-(traefik|mariadb|mail|dkim|panel|ftp)$' || true; }
site_containers() {  # site-uri (etichete wpl7.managed / wpl7.role) și FTP per site, fără containerele de stack
  { docker ps -a --filter label=wpl7.managed=true --format '{{.Names}}' 2>/dev/null || true
    docker ps -a --filter label=wpl7.role --format '{{.Names}}' 2>/dev/null || true
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^wpl7-ftp-' || true; } \
    | sort -u | grep -vxE 'wpl7-(traefik|mariadb|mail|dkim|panel|ftp)' | grep . || true
}
wpl7_networks() { docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^wpl7_' || true; }
wpl7_volumes() { docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^wpl7_' || true; }
wpl7_images() { docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^(ghcr\.io/andyfo/wpl7/|wpl7-wordpress:)' || true; }
image_ref_of() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || true; }

# --- pașii -------------------------------------------------------------------------------
parse_args() {
  local a n=0
  for a in "$@"; do
    case "$a" in
      --only-proxy-ui) ARG_SCOPE="ui"; n=$((n + 1)) ;;
      --keep-data)     ARG_SCOPE="keep"; n=$((n + 1)) ;;
      --purge-data)    ARG_SCOPE="purge"; n=$((n + 1)) ;;
      --dry-run)       DRY=1 ;;
      -y|--yes)        ASSUME_YES=1 ;;
      --remove-routes) REMOVE_ROUTES=1 ;;
      --keep-images)   KEEP_IMAGES=1 ;;
      --remove-swap)   REMOVE_SWAP=1 ;;
      --close-ports)   CLOSE_PORTS=1 ;;
      --remove-docker) REMOVE_DOCKER=1 ;;
      --srv-root=*)    ARG_SRV="${a#*=}" ;;
      --wpl7-dir=*)    [[ "${a#*=}" == /* && "${a#*=}" != *..* ]] || die "--wpl7-dir trebuie să fie o cale absolută, fără '..'"
                       WPL7_DIR="$(P "${a#*=}")" ;;
      -h|--help)       usage; exit 0 ;;
      *) die "Opțiune necunoscută: $a (vezi --help)" ;;
    esac
  done
  if [ "$n" -gt 1 ]; then die "Alege o singură variantă: --only-proxy-ui, --keep-data sau --purge-data."; fi
  if [ -n "$ARG_SRV" ] && { [[ "$ARG_SRV" != /* ]] || [[ "$ARG_SRV" == *..* ]]; }; then die "--srv-root trebuie să fie o cale absolută, fără '..'"; fi
}

start_log() {  # jurnalul se creează abia după confirmare: o comandă respinsă nu lasă nicio urmă
  if [ "$DRY" = 1 ]; then return 0; fi
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  : >>"$LOG" 2>/dev/null || true; chmod 600 "$LOG" 2>/dev/null || true
  LOG_READY=1
}

preflight() {
  [ "$(id -u)" -eq 0 ] || die "Rulează ca root: curl -fsSL <url> | sudo bash"
  if (exec </dev/tty) 2>/dev/null; then TTY_OK=1; fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAVE_DOCKER=1; fi
}

discover() {
  local fw_default envf
  fw_default="$(P /etc/default/wpl7-firewall)"
  if [ -n "$ARG_SRV" ]; then SRV_ROOT="$(P "$ARG_SRV")"
  else
    SRV_ROOT="$(kv "$fw_default" SRV_ROOT)"
    if [ -n "$SRV_ROOT" ] && [[ "$SRV_ROOT" == /* && "$SRV_ROOT" != *..* ]]; then SRV_ROOT="$(P "$SRV_ROOT")"; else SRV_ROOT="$(P /srv)"; fi
  fi
  if is_sysdir "${SRV_ROOT#"$PREFIX"}" && [ "${SRV_ROOT#"$PREFIX"}" != /srv ]; then
    die "SRV_ROOT ('${SRV_ROOT#"$PREFIX"}') nu e acceptat: ar însemna ștergerea unui director de sistem."
  fi
  if is_sysdir "${WPL7_DIR#"$PREFIX"}"; then die "Directorul WPL7 ('${WPL7_DIR#"$PREFIX"}') nu e acceptat: e un director de sistem."; fi
  if is_sysdir "${PLUS_DIR#"$PREFIX"}"; then die "Directorul wpl7plus nu e acceptat."; fi

  SITENAME="$(kv "$PLUS_DIR/identity" sitename)"
  envf="$WPL7_DIR/deploy/.env"
  if [ -d "$WPL7_DIR" ]; then WPL7_PRESENT=1; fi
  WPL7_VERSION="$(kv "$envf" WPL7_VERSION)"
  BACKUP_ROOT="$(kv "$envf" BACKUP_ROOT)"
  if [ -e "$(P /usr/local/sbin/wpl7-firewall)" ] || [ -e "$(P /etc/systemd/system/wpl7-firewall.service)" ] || [ -e "$fw_default" ]; then FW_PRESENT=1; fi
  if [ -f "$WPL7_DIR/provision/daemon.json" ] && cmp -s "$WPL7_DIR/provision/daemon.json" "$(P /etc/docker/daemon.json)" 2>/dev/null; then DAEMON_JSON_IS_WPL7=1; fi

  if [ "$HAVE_DOCKER" = 1 ]; then
    if docker container inspect "$UI_NAME" >/dev/null 2>&1; then UI_CONTAINER=1; fi
    if docker image inspect "$UI_IMAGE" >/dev/null 2>&1; then UI_IMAGE_PRESENT=1; fi
    STACK_CONTAINERS="$(stack_containers)"; SITE_CONTAINERS="$(site_containers)"
    NETWORKS="$(wpl7_networks)"; VOLUMES="$(wpl7_volumes)"
    if [ -n "$STACK_CONTAINERS$SITE_CONTAINERS$NETWORKS$VOLUMES" ]; then WPL7_PRESENT=1; fi
  fi
}

ui_found() { [ "$UI_CONTAINER" = 1 ] || [ "$UI_IMAGE_PRESENT" = 1 ] || [ -d "$PLUS_DIR/wpl7-proxy-ui" ]; }

show_inventory() {
  local d s
  step "Ce am găsit pe acest server"
  if ui_found; then
    say "  wpl7-proxy-ui:   container $([ "$UI_CONTAINER" = 1 ] && echo "$UI_NAME" || echo "-"), imagine $([ "$UI_IMAGE_PRESENT" = 1 ] && echo "$UI_IMAGE" || echo "-"), fișiere $PLUS_DIR${SITENAME:+ (sitename $SITENAME)}"
  else
    say "  wpl7-proxy-ui:   nu e instalat"
  fi
  if [ "$WPL7_PRESENT" = 1 ]; then
    say "  WPL7:            ${WPL7_DIR#"$PREFIX"}${WPL7_VERSION:+ (versiunea $WPL7_VERSION)}"
    say "                   $(count_lines "$STACK_CONTAINERS") containere de stack, $(count_lines "$SITE_CONTAINERS") containere de site/FTP, $(count_lines "$NETWORKS") rețele wpl7_*, $(count_lines "$VOLUMES") volume wpl7_*"
    for d in sites mysql backups panel traefik mail plugins; do
      if [ -d "$SRV_ROOT/$d" ]; then s="$(size_of "$SRV_ROOT/$d")"; say "  Date $SRV_ROOT/$d: ${s:-?}" | sed "s#$PREFIX##"; fi
    done
    if [ -n "$BACKUP_ROOT" ]; then say "  Backup-uri externe (BACKUP_ROOT): $BACKUP_ROOT  -> NU se șterg niciodată"; fi
    if [ "$FW_PRESENT" = 1 ]; then say "  Firewall WPL7:   unitatea wpl7-firewall + tabela nftables inet wpl7"; fi
  else
    say "  WPL7:            nu e instalat"
  fi
}

choose_scope() {
  local v
  SCOPE="$ARG_SCOPE"
  if [ -z "$SCOPE" ]; then
    if ! ui_found && [ "$WPL7_PRESENT" != 1 ]; then return 0; fi
    interactive || die "Spune ce dezinstalez: --only-proxy-ui, --keep-data sau --purge-data (și --yes fără terminal)."
    say ""
    say "Ce dezinstalez?"
    say "  1) Doar pagina wpl7-proxy-ui (WPL7, datele și rutele rămân)"
    say "  2) Tot, PĂSTRÂND datele din ${SRV_ROOT#"$PREFIX"} (site-uri, baze de date, backup-uri, certificate)"
    say "  3) Tot, ȘTERGÂND și datele (IREVERSIBIL)"
    ask "Alege 1-3 (Enter = renunță): "; v="$REPLY_VALUE"
    case "$v" in
      1) SCOPE="ui" ;; 2) SCOPE="keep" ;; 3) SCOPE="purge" ;;
      *) say "Renunțat. Nu s-a modificat nimic."; exit 0 ;;
    esac
  fi
  if [ "$SCOPE" != ui ] && [ "$WPL7_PRESENT" != 1 ]; then
    warn "WPL7 nu e instalat; elimin doar pagina wpl7-proxy-ui."; SCOPE="ui"
  fi
  if [ "$SCOPE" = ui ] && ! ui_found; then
    say "Nu am găsit wpl7-proxy-ui; nimic de dezinstalat."; exit 0
  fi
}

show_plan() {
  local title=""
  case "$SCOPE" in
    ui) title="doar wpl7-proxy-ui" ;;
    keep) title="tot, păstrând datele" ;;
    purge) title="tot, ȘTERGÂND datele" ;;
  esac
  if [ "$DRY" = 1 ]; then title="$title [dry-run]"; fi
  step "Plan: $title"
  say "  - șterg containerul $UI_NAME și imaginea $UI_IMAGE"
  if [ "$SCOPE" = ui ]; then
    say "  - șterg $PLUS_DIR/wpl7-proxy-ui (setările/parola paginii)"
    if [ "$REMOVE_ROUTES" = 1 ]; then say "  - șterg rutele proxy-*.yml din ${SRV_ROOT#"$PREFIX"}/traefik/dynamic"; else say "  - rutele proxy-*.yml rămân (Traefik le folosește în continuare)"; fi
    say "  - rămân: WPL7, datele, $PLUS_DIR/identity"
    return 0
  fi
  say "  - opresc și șterg stack-ul WPL7 (panou, Traefik, MariaDB, mail, DKIM) și containerele site-urilor/FTP"
  say "  - șterg rețelele wpl7_*"
  if [ "$KEEP_IMAGES" = 1 ]; then say "  - imaginile Docker rămân"; else say "  - șterg imaginile Docker folosite de WPL7 (cele folosite și de alte containere rămân)"; fi
  say "  - dezactivez și șterg firewall-ul WPL7 (unit, script, tabela nftables inet wpl7)"
  say "  - scot cheia panoului din /root/.ssh/authorized_keys și elimin utilizatorul wpl7-panel, dacă există"
  if [ "$SCOPE" = keep ]; then
    say "  - mut ${WPL7_DIR#"$PREFIX"} în ${WPL7_DIR#"$PREFIX"}.removed-<data> (păstrează .env cu parola MariaDB)"
    say "  - DATELE din ${SRV_ROOT#"$PREFIX"} rămân neatinse"
  else
    say "  - ȘTERG ${WPL7_DIR#"$PREFIX"} și, din ${SRV_ROOT#"$PREFIX"}: sites, backups, mysql, traefik, panel, plugins, mail, wpl7-firewall; volumele wpl7_*"
  fi
  say "  - șterg $PLUS_DIR (identity, wpl7-proxy-ui) și jurnalul instalării"
  if [ "$REMOVE_SWAP" = 1 ]; then say "  - șterg /swapfile"; fi
  if [ "$CLOSE_PORTS" = 1 ]; then say "  - șterg regulile UFW 80/tcp și 443/tcp"; fi
  if [ "$REMOVE_DOCKER" = 1 ]; then say "  - dezinstalez pachetele Docker (doar dacă nu mai rămâne niciun container)"; fi
}

confirm() {
  local want
  if [ "$DRY" = 1 ]; then return 0; fi
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  [ "$TTY_OK" = 1 ] || die "Nu am terminal pentru confirmare. Adaugă --yes."
  say ""
  case "$SCOPE" in
    ui)
      ask "Continui? [d/N]: "
      case "${REPLY_VALUE,,}" in d|da|y|yes) ;; *) say "Renunțat. Nu s-a modificat nimic."; exit 0 ;; esac ;;
    keep)
      want="${SITENAME:-STERGE}"
      ask "Pentru a continua scrie '$want' (Enter = renunță): "
      if [ "$REPLY_VALUE" != "$want" ]; then say "Renunțat. Nu s-a modificat nimic."; exit 0; fi ;;
    purge)
      warn "Se șterg site-urile WordPress, bazele de date și backup-urile din ${SRV_ROOT#"$PREFIX"}. NU se poate anula."
      ask "Pentru a continua scrie 'STERGE TOT' (Enter = renunță): "
      if [ "$REPLY_VALUE" != "STERGE TOT" ]; then say "Renunțat. Nu s-a modificat nimic."; exit 0; fi ;;
  esac
}

remove_proxy_ui() {
  step "wpl7-proxy-ui"
  if [ "$UI_CONTAINER" = 1 ]; then try "container $UI_NAME" docker rm -f "$UI_NAME"; fi
  if [ "$UI_IMAGE_PRESENT" = 1 ] && [ "$KEEP_IMAGES" != 1 ]; then quiet docker image rm "$UI_IMAGE"; fi
  if [ "$SCOPE" = ui ] && [ -d "$PLUS_DIR/wpl7-proxy-ui" ]; then safe_rm_rf "$PLUS_DIR/wpl7-proxy-ui"; fi
  if [ "$SCOPE" = ui ] && [ "$REMOVE_ROUTES" = 1 ] && [ -d "$SRV_ROOT/traefik/dynamic" ]; then
    local f
    for f in "$SRV_ROOT"/traefik/dynamic/proxy-*.yml; do
      [ -e "$f" ] || continue
      try "ruta $(basename "$f")" rm -f -- "$f"
    done
  fi
  DONE+=("wpl7-proxy-ui eliminat (container, imagine, fișiere)")
}

remove_wpl7_docker() {
  local c n v ref what
  step "Stack-ul WPL7 (Docker)"
  if [ "$HAVE_DOCKER" != 1 ]; then
    warn "Docker nu răspunde; sar peste containere, rețele și imagini."
    WARNS+=("Docker indisponibil: containerele/rețelele/imaginile WPL7 nu au fost verificate")
    return 0
  fi
  # imaginile se notează înainte de ștergerea containerelor
  for c in $STACK_CONTAINERS $SITE_CONTAINERS; do
    ref="$(image_ref_of "$c")"; [ -z "$ref" ] || IMAGE_REFS="$IMAGE_REFS$ref"$'\n'
  done
  IMAGE_REFS="$IMAGE_REFS$(wpl7_images)"

  # panoul întâi: altfel ar recrea containerele site-urilor
  if [ -x "$WPL7_DIR/provision/compose.sh" ]; then
    try "docker compose down" "$WPL7_DIR/provision/compose.sh" down --remove-orphans
  fi
  for c in $STACK_CONTAINERS; do
    if docker container inspect "$c" >/dev/null 2>&1; then try "container $c" docker rm -f "$c"; fi
  done
  for c in $SITE_CONTAINERS; do
    if docker container inspect "$c" >/dev/null 2>&1; then try "container $c" docker rm -f "$c"; fi
  done
  for n in $(wpl7_networks); do try "rețeaua $n" docker network rm "$n"; done
  if [ "$SCOPE" = purge ]; then
    for v in $(wpl7_volumes); do try "volumul $v" docker volume rm "$v"; done
  fi
  if [ "$KEEP_IMAGES" != 1 ]; then
    for ref in $(printf '%s' "$IMAGE_REFS" | sort -u | grep . || true); do quiet docker image rm "$ref"; done
  fi
  what="containere, rețele"
  if [ "$SCOPE" = purge ]; then what="$what, volume"; fi
  if [ "$KEEP_IMAGES" != 1 ]; then what="$what, imagini"; fi
  DONE+=("stack WPL7: $what eliminate")
}

remove_host_integration() {
  local unit script defl key auth tmp
  step "Integrarea cu sistemul"
  unit="$(P /etc/systemd/system/wpl7-firewall.service)"; script="$(P /usr/local/sbin/wpl7-firewall)"; defl="$(P /etc/default/wpl7-firewall)"
  if [ "$FW_PRESENT" = 1 ]; then
    if command -v systemctl >/dev/null 2>&1; then quiet systemctl disable --now wpl7-firewall.service; fi
    if command -v nft >/dev/null 2>&1; then quiet nft delete table inet wpl7; fi
    for key in "$unit" "$script" "$defl"; do
      if [ -e "$key" ]; then try "fișierul $key" rm -f -- "$key"; fi
    done
    if command -v systemctl >/dev/null 2>&1; then quiet systemctl daemon-reload; fi
    DONE+=("firewall WPL7 (unit, script, tabela inet wpl7) eliminat")
  fi

  # cheia panoului din root
  auth="$(P /root/.ssh/authorized_keys)"
  if [ -f "$auth" ]; then
    key=""
    if [ -f "$SRV_ROOT/panel/ssh/id_ed25519.pub" ]; then key="$(cat "$SRV_ROOT/panel/ssh/id_ed25519.pub")"; fi
    if { [ -n "$key" ] && grep -qF -- "$key" "$auth"; } || grep -q ' wpl7-panel@' "$auth"; then
      if [ "$DRY" = 1 ]; then
        say "   [dry-run] scot cheia panoului din $auth"
      else
        tmp="$(mktemp "$auth.XXXXXX")"
        { if [ -n "$key" ]; then grep -vF -- "$key" "$auth" || true; else cat "$auth"; fi; } | { grep -v ' wpl7-panel@' || true; } >"$tmp"
        chmod --reference="$auth" "$tmp" 2>/dev/null || chmod 600 "$tmp"
        mv -f "$tmp" "$auth"
      fi
      DONE+=("cheia panoului scoasă din /root/.ssh/authorized_keys")
    fi
  fi

  # utilizatorul panoului (doar servere worker / --panel-key)
  if id wpl7-panel >/dev/null 2>&1; then
    try "utilizatorul wpl7-panel" userdel -r wpl7-panel
    DONE+=("utilizatorul wpl7-panel eliminat")
  fi
  if [ -e "$(P /etc/sudoers.d/91-wpl7-panel)" ]; then try "sudoers wpl7-panel" rm -f -- "$(P /etc/sudoers.d/91-wpl7-panel)"; fi
}

finalize_files() {
  local ts arch d
  step "Fișiere"
  if [ "$SCOPE" = keep ]; then
    if [ -d "$WPL7_DIR" ]; then
      ts="$(date +%Y%m%d-%H%M%S)"; arch="$WPL7_DIR.removed-$ts"
      run mv -- "$WPL7_DIR" "$arch"; run chmod 700 "$arch"
      DONE+=("${WPL7_DIR#"$PREFIX"} mutat în ${arch#"$PREFIX"} (conține deploy/.env cu secretele)")
    fi
    REMAIN+=("datele din ${SRV_ROOT#"$PREFIX"} (sites, mysql, backups, traefik, panel, mail, plugins, wpl7-firewall)")
  else
    safe_rm_rf "$WPL7_DIR"
    for d in sites backups mysql traefik panel plugins mail wpl7-firewall; do
      if [ -e "$SRV_ROOT/$d" ]; then safe_rm_rf "$SRV_ROOT/$d"; fi
    done
    DONE+=("${WPL7_DIR#"$PREFIX"} și datele WPL7 din ${SRV_ROOT#"$PREFIX"} șterse")
  fi
  if [ -n "$BACKUP_ROOT" ]; then REMAIN+=("backup-urile din BACKUP_ROOT ($BACKUP_ROOT): nu se șterg automat; șterge-le tu dacă nu mai ai nevoie de ele"); fi
  safe_rm_rf "$PLUS_DIR"
  if [ -e "$(P /var/log/wpl7plus-install.log)" ]; then run rm -f -- "$(P /var/log/wpl7plus-install.log)"; fi
  DONE+=("$PLUS_DIR (identity, wpl7-proxy-ui) și jurnalul instalării șterse")
}

extras() {
  local fstab swap n
  if [ "$REMOVE_SWAP" = 1 ]; then
    swap="$(P /swapfile)"; fstab="$(P /etc/fstab)"
    if [ -f "$swap" ]; then
      step "Swap"
      quiet swapoff "$swap"
      run rm -f -- "$swap"
      if [ -f "$fstab" ] && [ "$DRY" != 1 ]; then sed -i '\|^/swapfile[[:space:]]|d' "$fstab"; fi
      DONE+=("/swapfile șters (și linia din /etc/fstab)")
    else
      say "  /swapfile nu există."
    fi
  fi
  if [ "$CLOSE_PORTS" = 1 ]; then
    step "UFW"
    if command -v ufw >/dev/null 2>&1; then
      quiet ufw delete allow 80/tcp
      quiet ufw delete allow 443/tcp
      DONE+=("reguli UFW 80/tcp și 443/tcp șterse")
    else
      say "  ufw nu e instalat."
    fi
  fi
  if [ "$REMOVE_DOCKER" = 1 ]; then
    step "Docker"
    if [ "$HAVE_DOCKER" = 1 ]; then n="$(docker ps -aq 2>/dev/null | grep -c . || true)"; else n=0; fi
    if [ "${n:-0}" -gt 0 ]; then
      warn "Mai există $n container(e) Docker care nu țin de WPL7; nu dezinstalez Docker."
      WARNS+=("Docker păstrat: mai există containere")
    else
      try "apt-get purge docker" apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      quiet apt-get autoremove -y
      quiet rm -f -- "$(P /etc/apt/sources.list.d/docker.list)" "$(P /etc/apt/keyrings/docker.asc)"
      if [ "$DAEMON_JSON_IS_WPL7" = 1 ]; then quiet rm -f -- "$(P /etc/docker/daemon.json)"; fi
      DONE+=("pachetele Docker dezinstalate (imaginile/volumele din /var/lib/docker nu au fost șterse)")
    fi
  fi
}

summary() {
  local x title="Rezumat"
  if [ "$DRY" = 1 ]; then title="Rezumat (dry-run: nu s-a schimbat nimic)"; fi
  step "$title"
  for x in "${DONE[@]}"; do ok "$x"; done
  say ""
  say "  Rămân, intenționat:"
  for x in "${REMAIN[@]}"; do say "    - $x"; done
  if [ "$SCOPE" = ui ]; then
    if [ "$REMOVE_ROUTES" = 1 ]; then say "    - WPL7 și datele lui, $PLUS_DIR/identity (rutele proxy-*.yml au fost șterse)"
    else say "    - WPL7 și datele lui, rutele proxy-*.yml, $PLUS_DIR/identity"; fi
  fi
  say "    - pachetele de bază instalate de WPL7 (curl, git, ufw, jq, openssl, nftables, gnupg, ca-certificates)"
  if [ "$SCOPE" != ui ]; then
    if [ "$REMOVE_DOCKER" = 1 ]; then say "    - /var/lib/docker (imaginile și volumele altor containere); regulile UFW pentru SSH și politicile implicite"
    else say "    - Docker și /etc/docker/daemon.json; regulile UFW pentru SSH și politicile implicite"; fi
    if [ "$CLOSE_PORTS" != 1 ]; then say "      (porturile 80/443 rămân deschise în UFW; le închizi cu: ufw delete allow 80/tcp; ufw delete allow 443/tcp)"; fi
    if [ "$REMOVE_SWAP" != 1 ] && [ -f "$(P /swapfile)" ]; then say "    - /swapfile (dacă l-a creat WPL7; rulează cu --remove-swap ca să-l ștergi)"; fi
  fi
  if [ "${#WARNS[@]}" -gt 0 ]; then
    say ""; warn "Pași care au dat eroare (verifică manual):"
    for x in "${WARNS[@]}"; do say "    - $x" >&2; done
  fi
  if [ "$SCOPE" = keep ]; then
    say ""
    say "  Reinstalare cu aceleași date: arhiva de configurare păstrează deploy/.env (parola MariaDB, secretele panoului);"
    say "  baza de date din /srv/mysql nu poate fi folosită cu alt .env."
  fi
  if [ "$LOG_READY" = 1 ]; then say ""; say "  Jurnal: ${LOG#"$PREFIX"}"; fi
}

main() {
  parse_args "$@"
  preflight
  discover
  step "wpl7plus - dezinstalare"
  if ! ui_found && [ "$WPL7_PRESENT" != 1 ]; then
    say "  Nu am găsit nimic de dezinstalat (nici wpl7-proxy-ui, nici WPL7)."
    exit 0
  fi
  show_inventory
  choose_scope
  show_plan
  confirm
  start_log
  note "start: scope=$SCOPE dry=$DRY srv=$SRV_ROOT"

  remove_proxy_ui
  if [ "$SCOPE" != ui ]; then
    remove_wpl7_docker
    remove_host_integration
    finalize_files
    extras
  fi
  summary
  note "terminat: warns=${#WARNS[@]}"
}

main "$@"
