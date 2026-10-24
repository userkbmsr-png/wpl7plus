#!/usr/bin/env bash
# wpl7-proxy — publish an internal service under a public domain through WPL7's Traefik.
#
#   sudo ./wpl7-proxy.sh add situlmeu.com 192.168.1.50:8080
#   sudo ./wpl7-proxy.sh add app.exemplu.ro https://192.168.1.60:8443 --insecure
#   sudo ./wpl7-proxy.sh list
#   sudo ./wpl7-proxy.sh check situlmeu.com
#   sudo ./wpl7-proxy.sh rm situlmeu.com
#
# (The same routes can be managed from a web page: see wpl7-proxy-ui/.)
#
# How it works: WPL7's Traefik already loads every YAML file from ${SRV_ROOT}/traefik/dynamic
# (--providers.file.directory, watch=true), so no compose/.env change and no restart is needed.
# Files written here are named proxy-<domain>.yml; the panel uses move-*, sec-* and wpl7-blocked,
# so the names never collide. Entrypoint `websecure` and resolver `letsencrypt` are the ones
# defined in deploy/docker-compose.yml (override with --resolver / ENTRYPOINT).
set -euo pipefail

SRV_ROOT="${SRV_ROOT:-/srv}"
DIR="${SRV_ROOT}/traefik/dynamic"
ENTRYPOINT="${ENTRYPOINT:-websecure}"
RESOLVER="${ACME_RESOLVER:-letsencrypt}"
CONTAINER="${TRAEFIK_CONTAINER:-wpl7-traefik}"

die()  { echo "error: $*" >&2; exit 1; }
slug() { echo "$1" | tr 'A-Z.' 'a-z-'; }
file_for() { echo "${DIR}/proxy-$(slug "$1").yml"; }

valid_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd_add() {
  local domain="${1:-}" target="${2:-}"; shift 2 || usage 1
  local insecure=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --insecure) insecure=1 ;;
      --resolver) RESOLVER="${2:?--resolver needs a name}"; shift ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  domain="$(echo "$domain" | tr 'A-Z' 'a-z')"
  valid_domain "$domain" || die "'$domain' is not a valid domain"
  # Accept host:port, http://host:port or https://host:port
  target="$(echo "$target" | tr 'A-Z' 'a-z')"; target="${target%/}"
  [[ "$target" =~ ^https?:// ]] || target="http://${target}"
  [[ "$target" =~ ^https?://[a-z0-9]([a-z0-9._-]*[a-z0-9])?(:[0-9]{1,5})?$ ]] \
    || die "bad target '$target' - use host:port only (Traefik ignores any path in the URL)"
  if [[ "$target" =~ :([0-9]+)$ ]] && { [ "${BASH_REMATCH[1]}" -lt 1 ] || [ "${BASH_REMATCH[1]}" -gt 65535 ]; }; then
    die "bad port in '$target'"
  fi
  [ -d "$DIR" ] || die "$DIR not found — is WPL7 installed here (SRV_ROOT=$SRV_ROOT)?"

  local name; name="proxy-$(slug "$domain")"
  local out; out="$(file_for "$domain")"
  local f
  for f in "$DIR"/proxy-*.yml; do
    [ -e "$f" ] || continue
    if [ "$f" != "$out" ] && grep -qF "Host(\`${domain}\`)" "$f"; then die "$domain is already routed by $f"; fi
  done
  if [ -f "$out" ] && ! grep -qF "Host(\`${domain}\`)" "$out"; then
    die "$out belongs to another route (name collision) - remove it or use another domain"
  fi
  local tmp; tmp="$(mktemp "${DIR}/.${name}.XXXXXX")"

  {
    echo "# Gestionat de wpl7-proxy-ui / wpl7-proxy.sh - poate fi editat; panoul WPL7 nu atinge acest fisier."
    echo "http:"
    echo "  routers:"
    echo "    ${name}:"
    echo "      rule: \"Host(\`${domain}\`)\""
    echo "      entryPoints: [${ENTRYPOINT}]"
    echo "      service: ${name}"
    echo "      priority: 1"     # a WPL7 site/panel with the same domain wins
    echo "      tls:"
    echo "        certResolver: ${RESOLVER}"
    echo "  services:"
    echo "    ${name}:"
    echo "      loadBalancer:"
    echo "        passHostHeader: true"
    if [ "$insecure" = 1 ]; then
      echo "        serversTransport: ${name}-insecure"
    fi
    echo "        servers:"
    echo "          - url: \"${target}\""
    if [ "$insecure" = 1 ]; then
      echo "  serversTransports:"
      echo "    ${name}-insecure:"
      echo "      insecureSkipVerify: true"
    fi
  } > "$tmp"

  chmod 644 "$tmp"
  mv -f "$tmp" "$out"          # atomic rename: Traefik never reads a half-written file
  echo "ok: $out"
  echo "    https://${domain}  ->  ${target}"
  echo "DNS: point an A record for ${domain} at this server's public IP; the certificate"
  echo "is requested by Traefik on first visit (HTTP-01, port 80 must be reachable)."
}

cmd_rm() {
  local domain="${1:-}"; [ -n "$domain" ] || usage 1
  local f; f="$(file_for "$domain")"
  [ -f "$f" ] || die "no proxy file for $domain ($f)"
  rm -f "$f"
  echo "removed $f"
}

cmd_list() {
  shopt -s nullglob
  local any=0 f
  for f in "$DIR"/proxy-*.yml; do
    any=1
    local host url
    host="$(grep -o 'Host(`[^`]*`)' "$f" | head -1 | sed 's/Host(`\(.*\)`)/\1/')"
    url="$(grep -o 'url: "[^"]*"' "$f" | head -1 | sed 's/url: "\(.*\)"/\1/')"
    printf '%-35s -> %s\n' "$host" "$url"
  done
  [ "$any" = 1 ] || echo "(no proxy routes)"
}

# Test reachability FROM INSIDE the Traefik container — the network position that matters.
cmd_check() {
  local domain="${1:-}"; [ -n "$domain" ] || usage 1
  local f; f="$(file_for "$domain")"
  [ -f "$f" ] || die "no proxy file for $domain"
  local url; url="$(grep -o 'url: "[^"]*"' "$f" | head -1 | sed 's/url: "\(.*\)"/\1/')"
  echo "from ${CONTAINER}: GET ${url}"
  if docker exec "$CONTAINER" wget -q -S -O /dev/null -T 5 --no-check-certificate "$url" 2>&1 | head -3; then
    echo "(a HTTP status line above means the backend is reachable)"
  else
    echo "unreachable from the Traefik container — check routing/VPN/firewall to ${url}" >&2
    exit 2
  fi
}

case "${1:-}" in
  add)   shift; cmd_add "$@" ;;
  rm)    shift; cmd_rm "$@" ;;
  list)  cmd_list ;;
  check) shift; cmd_check "$@" ;;
  -h|--help|help|"") usage 0 ;;
  *) usage 1 ;;
esac
