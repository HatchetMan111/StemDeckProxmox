#!/usr/bin/env bash
#===============================================================================
# StemDeck – Proxmox VE Installer (Community-Scripts-Stil)
#-------------------------------------------------------------------------------
# Erstellt einen unprivilegierten LXC-Container (Debian 13) und installiert
# darin StemDeck (https://github.com/stemdeckapp/stemdeck) – lokale Audio-
# Stem-Separation (Vocals, Drums, Bass, Gitarre, Piano, Other) über die
# Demucs-Neural-Network-Engine mit DAW-artiger Web-UI. Läuft komplett lokal,
# kein Account, kein Upload in fremde Clouds. CPU-Inferenz im LXC; für
# NVIDIA-GPU-Beschleunigung siehe README (VM-Empfehlung).
#
# Einzeiler auf dem Proxmox-Host:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh)"
#
# Debug-Ablauf (vollständiges bash -x Log):
#   DEBUG=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh)"
#
# Weitere Aufrufe:
#   ./stemdeck.sh --update        # neuestes Release im vorhandenen CT installieren
#   ./stemdeck.sh --uninstall     # Container vollständig entfernen (DESTRUKTIV!)
#   CTID=160 VAR_CPU=4 ./stemdeck.sh   # nicht-interaktiv mit eigenen Werten
#===============================================================================
set -Eeuo pipefail

#==============================
# Konfiguration (per Env überschreibbar)
#==============================
readonly APP_ID="stemdeck"
readonly APP_NAME="StemDeck"
readonly UPSTREAM_REPO="stemdeckapp/stemdeck"

# Ressourcen des LXC. StemDeck betreibt ein Neuronales Netz (Demucs htdemucs_6s)
# – CPU-Inferenz allein braucht real 4-6 GB RAM, dazu kommen ~170 MB Modell und
# bis zu ~3 GB WAV-Dateien pro Job. Die Community-Standardwerte (1 vCPU / 1 GB)
# reichen hier schlicht nicht; das ist bewusst so und pro Env/Dialog anpassbar.
VAR_DISK="${VAR_DISK:-30}"        # GB (venv ~4 GB + Modelle + Stems)
VAR_CPU="${VAR_CPU:-4}"
VAR_RAM="${VAR_RAM:-8192}"        # MB
VAR_SWAP="${VAR_SWAP:-8192}"      # MB – Swap-Puffer, damit Demucs nicht OOM stirbt

VAR_OS="debian"
VAR_VERSION="13"
CT_TYPE="1"                       # 1 = unprivileged
BRIDGE="${BRIDGE:-vmbr0}"
NET_MODE="${NET_MODE:-dhcp}"      # dhcp | static
NET_CIDR="${NET_CIDR:-}"          # z. B. 192.168.1.100/24 (bei NET_MODE=static)
NET_GW="${NET_GW:-}"              # z. B. 192.168.1.1

# Web-UI-Port (upstream-Docker-Konvention: 8000)
WEB_PORT="${WEB_PORT:-8000}"

# Release-Pinning (z. B. "0.16.0"); leer = immer neuestes Release.
STEMDECK_VERSION="${STEMDECK_VERSION:-}"

MODE="${MODE:-install}"           # install | update | uninstall
DEBUG="${DEBUG:-0}"
GUEST_LOG_FILE="/var/log/${APP_ID}-install.log"

TARGET_CTID=""
STORAGE=""
TEMPLATE=""
NET_CFG="ip=dhcp"

TMPDIR_INSTALL="$(mktemp -d /tmp/${APP_ID}-install.XXXXXX)"
LOG_FILE="/tmp/${APP_ID}-install-$(date +%Y%m%d-%H%M%S).log"

trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

#==============================
# Logging + vollständige Fehlermeldungskette
# ALLE Logzeilen gehen bewusst nach stderr, damit Funktionen, deren stdout
# per Kommandosubstitution eingefangen wird (z. B. resolve_self), nie
# Logtext in Rückgabewerte mischen.
#==============================
exec > >(tee -a "$LOG_FILE") 2>&1

msg_info()  { printf '\033[1;36m[Info]\033[0m  %s\n' "$*" >&2; }
msg_ok()    { printf '\033[1;32m [OK]\033[0m  %s\n' "$*" >&2; }
msg_warn()  { printf '\033[1;33m [WARN]\033[0m %s\n' "$*" >&2; }
msg_error() { printf '\033[1;31m[Fehler]\033[0m %s\n' "$*" >&2; }

die() {
  msg_error "$*"
  msg_error "Komplettes Installationslog: $LOG_FILE"
  exit 1
}

enable_debug() {
  PS4='+ $(date +%H:%M:%S) [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
  msg_warn "Debug-Modus aktiv (bash -x) – jede Anweisung wird ins Log mitgeschrieben."
}

print_call_stack() {
  local frame=0 line func file
  while IFS=' ' read -r line func file; do
    msg_error "  aufrufend: ${func}() (${file}:${line})"
    frame=$((frame + 1))
  done < <(while caller "$frame" 2>/dev/null; do frame=$((frame + 1)); done)
}

on_error() {
  local exit_code="$1"
  local failed_cmd="$2"
  trap - ERR
  set +Eeuo pipefail

  printf '\n' >&2
  msg_error "Installationsfehler – vollständige Fehlermeldungskette:"
  msg_error "Exit-Code : ${exit_code}"
  msg_error "Fehlschlag: ${failed_cmd}"
  print_call_stack

  if [[ "${PHASE:-host}" == "guest" ]]; then
    msg_error "--- systemctl status stemdeck ---"
    systemctl --no-pager -l status stemdeck 2>&1 | tail -n 25 || true
    msg_error "--- journalctl -u stemdeck (letzte 40 Zeilen) ---"
    journalctl --no-pager -n 40 -u stemdeck 2>&1 || true
    msg_error "--- offene Ports (ss -tlnp) ---"
    ss -tlnp 2>/dev/null || true
    msg_error "--- Speicher/Platte ---"
    free -m 2>/dev/null || true
    df -h / 2>/dev/null || true
    msg_error "Gast-Log: ${GUEST_LOG_FILE} (pct enter \$CTID → less ${GUEST_LOG_FILE})"
  fi

  msg_error "Alle Ausgaben wurden mitgeschrieben: ${LOG_FILE} (Phase: ${PHASE:-host})"
  msg_error "Zum Nachvollziehen mit vollem Shelltrace erneut ausführen:"
  msg_error "  DEBUG=1 bash -c \"\$(wget -qLO - ${SCRIPT_URL})\""
  exit "$exit_code"
}

trap 'on_error $? "$BASH_COMMAND"' ERR

if [[ "$DEBUG" == "1" ]]; then
  enable_debug
fi

PHASE="${SD_PHASE:-host}"

#==============================
# Hilfsfunktionen
#==============================
have() { command -v "$1" >/dev/null 2>&1; }

ask_default() { # ask_default <Prompt> <Default>
  local reply=""
  if [[ -t 0 ]]; then
    read -r -p "$1 [$2]: " reply </dev/tty || reply=""
    printf '%s\n' "${reply:-$2}"
  else
    msg_info "$1 → nicht-interaktiv, verwende Default: $2"
    printf '%s\n' "$2"
  fi
}

ask_required_value() { # ask_required_value <Option> <Wert>
  if (($# < 2)) || [[ -z "$2" ]]; then
    die "Option $1 benötigt einen Wert (--help anzeigen)."
  fi
  printf '%s\n' "$2"
}

# ask_ram_mib <Prompt> <Default-MB>
# Fragt den RAM ab und übersetzt intuitive GB-Angaben (Wert <= 512) automatisch
# nach MB (6 → 6144). Wenige MB sind für StemDeck ohnehin unbrauchbar, also ist
# die Einheiten-Heuristik hier unkritisch und spart typische Tippfehler ("6" für
# "6 GB" statt "6144"). Rückgabe ist immer in MB.
ask_ram_mib() {
  local prompt="$1" dflt="$2" reply=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt [$dflt]: " reply </dev/tty || reply="$dflt"
  else
    msg_info "$prompt → nicht-interaktiv, verwende Default: $dflt MB"
    reply="$dflt"
  fi
  reply="${reply:-$dflt}"
  reply="$(tr -d '[:space:]' <<<"$reply" | tr -d 'gG')"
  if [[ ! "$reply" =~ ^[0-9]+$ ]]; then
    die "Ungültiger RAM-Wert: '${reply}' – positive Zahl erwartet."
  fi
  if (( reply <= 512 )); then
    msg_info "RAM-Eingabe '${reply}' als GB interpretiert → ${reply} GB = $((reply * 1024)) MB."
    reply=$((reply * 1024))
  fi
  printf '%s\n' "$reply"
}

confirm_or_die() { # confirm_or_die <Frage>
  if [[ -t 0 ]]; then
    local reply=""
    read -r -p "$1 [y/N]: " reply </dev/tty || reply=""
    case "$reply" in y|Y|ja|JA|Ja) return 0 ;; *) die "Abgebrochen." ;; esac
  else
    die "$1 – nicht-interaktiv und Bestätigung erforderlich (TTY fehlt)."
  fi
}

fetch_to() { # fetch_to <URL> <Zieldatei>
  local url="$1" out="$2" attempt
  for attempt in 1 2 3; do
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "${out}.part" "$url"; then
      mv "${out}.part" "$out"
      return 0
    fi
    msg_warn "Download-Versuch ${attempt}/3 fehlgeschlagen: $url"
    sleep 2
  done
  die "Konnte Datei nicht laden: $url"
}

wait_for_http() { # wait_for_http <URL> <Timeout-Sekunden>
  local url="$1" timeout_s="$2" elapsed=0 code=""
  until code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)" && [[ "$code" =~ ^(200|301|302|307|308|401)$ ]]; do
    if (( elapsed >= timeout_s )); then
      msg_error "HTTP-Check fehlgeschlagen nach ${timeout_s}s: $url (letzter Code: ${code:-keiner})"
      return 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 0
}

require_active_unit() { # require_active_unit <unit>
  if ! systemctl is-active --quiet "$1"; then
    msg_error "systemd-Unit '$1' ist NICHT aktiv (Status: $(systemctl is-active "$1" 2>&1 || true))"
    journalctl --no-pager -u "$1" -n 30 2>&1 || true
    return 1
  fi
  msg_ok "Service läuft: $1"
}

#==============================
# Release-Logik (Host + Gast)
#==============================
resolve_release_version() { # stdout: Versionsnummer ohne "v" (z. B. 0.16.0)
  local tag=""
  if [[ -n "$STEMDECK_VERSION" ]]; then
    tag="${STEMDECK_VERSION#v}"
  else
    tag="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" 2>/dev/null \
      | jq -r '.tag_name // empty' || true)"
    tag="${tag#v}"
  fi
  [[ -n "$tag" ]] || die "Konnte neueste StemDeck-Version nicht ermitteln (api.github.com erreichbar?)."
  printf '%s\n' "$tag"
}

#==============================
# GAST-PHASE: Installation im LXC (Debian 13)
#==============================
APT_UPDATED=0
apt_install() {
  if (( APT_UPDATED == 0 )); then
    msg_info "apt-get update …"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

install_app() {
  local ver
  ver="$(resolve_release_version)"

  msg_info "Installiere System-Abhängigkeiten (ffmpeg, build-essential, deno) …"
  # Wie das offizielle Docker-Image: ffmpeg für Transcode/Mix, Compiler für
  # evtl. Source-Fallbacks bei pip-Wheels, deno als yt-dlp-JS-Runtime.
  apt_install build-essential ca-certificates curl jq git python3 python3-venv \
    python3-pip ffmpeg unzip
  install_deno
  msg_ok "System-Abhängigkeiten installiert."

  msg_info "Lade StemDeck v${ver} aus dem Upstream-Repo …"
  rm -rf /opt/stemdeck-src
  if ! git clone -q --depth 1 --branch "v${ver}" "https://github.com/${UPSTREAM_REPO}.git" /opt/stemdeck-src; then
    die "Konnte ${UPSTREAM_REPO} (Tag v${ver}) nicht klonen."
  fi
  [[ -d /opt/stemdeck-src/app && -f /opt/stemdeck-src/pyproject.toml ]] \
    || die "Repo-Struktur unerwartet (app/ oder pyproject.toml fehlt) – Installation abgebrochen."
  mkdir -p /opt/stemdeck
  rm -rf /opt/stemdeck/app /opt/stemdeck/static /opt/stemdeck/pyproject.toml /opt/stemdeck/README.md
  cp -r /opt/stemdeck-src/app /opt/stemdeck/app
  cp -r /opt/stemdeck-src/static /opt/stemdeck/static
  cp /opt/stemdeck-src/pyproject.toml /opt/stemdeck/pyproject.toml
  cp /opt/stemdeck-src/README.md /opt/stemdeck/README.md 2>/dev/null || true
  git -C /opt/stemdeck-src rev-parse HEAD > /opt/stemdeck/installed_commit.txt
  printf '%s\n' "$ver" > /opt/stemdeck/installed_version.txt
  rm -rf /opt/stemdeck-src
  msg_ok "StemDeck v${ver} geladen (Commit $(cut -c1-7 /opt/stemdeck/installed_commit.txt))."

  create_service_user
  create_venv "$ver"
  write_data_dirs
  start_service
}

install_deno() {
  # yt-dlp löst YouTubes JS-Challenge über einen JS-Runtime (deno > node >
  # quickjs). Ohne ihn funktionieren Downloads noch, greifen aber evtl. auf
  # suboptimale Formate zurück – derselbe Stand wie im Docker-Image.
  if have deno; then
    msg_ok "deno bereits vorhanden ($(deno --version | head -n1))."
    return 0
  fi
  local deno_arch deno_zip="/tmp/deno.zip"
  case "$(dpkg --print-architecture)" in
    amd64) deno_arch="x86_64-unknown-linux-gnu" ;;
    arm64) deno_arch="aarch64-unknown-linux-gnu" ;;
    *) msg_warn "Architektur ohne deno-Build – yt-dlp nutzt ggf. einen anderen JS-Runtime."; return 0 ;;
  esac
  fetch_to "https://github.com/denoland/deno/releases/latest/download/deno-${deno_arch}.zip" "$deno_zip"
  unzip -o "$deno_zip" -d /usr/local/bin >/dev/null
  rm -f "$deno_zip"
  chmod 755 /usr/local/bin/deno
  msg_ok "deno installiert ($(deno --version 2>/dev/null | head -n1))."
}

create_service_user() {
  if id -u "$APP_ID" >/dev/null 2>&1; then
    msg_ok "Dienstbenutzer '${APP_ID}' existiert bereits."
    return 0
  fi
  useradd --system --home-dir /var/lib/stemdeck --shell /usr/sbin/nologin "$APP_ID"
  msg_ok "Dienstbenutzer '${APP_ID}' angelegt."
}

create_venv() { # create_venv <Version>
  local ver="$1"
  msg_info "Erstelle Python-Umgebung und installiere StemDeck (~1-2 GB, Torch CPU-Wheels) …"
  python3 -m venv /opt/stemdeck/venv
  # extra-index statt index: auf ARM gibt es kein torchaudio-2.6.0+cpu-Wheel,
  # das PyPI-Standard-Wheel (ohne +cpu-Suffix) ist dort bereits CPU-only.
  # Auf x86_64 greift pip das kleinere +cpu-Wheel vom PyTorch-Index (~250 MB
  # statt ~800 MB CUDA-Variante) – dieselbe Engine, kein funktionaler Unterschied.
  /opt/stemdeck/venv/bin/pip install --no-cache-dir --timeout 300 \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    "torch>=2.6,<2.7" "torchaudio>=2.6,<2.7"
  (cd /opt/stemdeck && SETUPTOOLS_SCM_PRETEND_VERSION="$ver" \
    /opt/stemdeck/venv/bin/pip install --no-cache-dir --timeout 300 .) \
    || die "pip install des Projekts fehlgeschlagen."
  msg_ok "Python-Umgebung fertig."
}

write_data_dirs() {
  # Alle Schreibzugriffe (Jobs, Modelle, Cache, Logs) unter /var/lib/stemdeck;
  # STEMDECK_PERSIST_LIBRARY=1 wie im self-hosted Docker-Default, damit die
  # Bibliothek nicht dem 24h-TTL-Sweep zum Opfer fällt.
  msg_info "Lege Datenverzeichnisse an (/var/lib/stemdeck) …"
  install -d -o stemdeck -g stemdeck -m 0750 \
    /var/lib/stemdeck /var/lib/stemdeck/jobs /var/lib/stemdeck/cache \
    /var/lib/stemdeck/models /var/lib/stemdeck/downloads /var/lib/stemdeck/logs
  chown -R stemdeck:stemdeck /opt/stemdeck
  msg_ok "Datenverzeichnisse angelegt."
}

write_systemd_unit() {
  msg_info "Schreibe systemd-Unit stemdeck.service …"
  cat > /etc/systemd/system/stemdeck.service <<UNIT
[Unit]
Description=StemDeck – lokale Audio-Stem-Separation (Web-UI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=stemdeck
Group=stemdeck
WorkingDirectory=/opt/stemdeck
Environment=PYTHONUNBUFFERED=1
Environment=STEMDECK_DATA_DIR=/var/lib/stemdeck
Environment=STEMDECK_JOBS_DIR=/var/lib/stemdeck/jobs
Environment=STEMDECK_CACHE_DIR=/var/lib/stemdeck/cache
Environment=STEMDECK_MODELS_DIR=/var/lib/stemdeck/models
Environment=STEMDECK_DOWNLOADS_DIR=/var/lib/stemdeck/downloads
Environment=STEMDECK_LOGS_DIR=/var/lib/stemdeck/logs
Environment=STEMDECK_PERSIST_LIBRARY=1
Environment=TORCH_HOME=/var/lib/stemdeck/cache/torch
Environment=XDG_CACHE_HOME=/var/lib/stemdeck/cache
Environment=STEMDECK_DEMUCS_DEVICE=cpu
ExecStart=/opt/stemdeck/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port ${WEB_PORT} --timeout-graceful-shutdown 5
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Leichte Haertung: Dienst ohne Root-Rechte, Schreibzugriff nur auf die
# Datenverzeichnisse. Der erste Model-Download (~170 MB) laeuft trotzdem,
# da TORCH_HOME/XDG_CACHE_HOME unter /var/lib/stemdeck liegen.
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/stemdeck

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/stemdeck.service
  msg_ok "systemd-Unit geschrieben (bind 0.0.0.0:${WEB_PORT}, Restart=always)."
}

start_service() {
  write_systemd_unit
  systemctl daemon-reload
  systemctl enable stemdeck >/dev/null 2>&1 || true
  msg_ok "stemdeck.service aktiviert (Autostart beim Boot, Restart=always)."
  msg_info "(Re)starte Service …"
  systemctl restart stemdeck
}

verify_service_and_web() {
  require_active_unit "stemdeck" || die "stemdeck-Service läuft nicht – Diagnose siehe oben."

  msg_info "Warte auf Web-UI unter 127.0.0.1:${WEB_PORT} (max. 120 s) …"
  wait_for_http "http://127.0.0.1:${WEB_PORT}/api/health" 120 || {
    journalctl --no-pager -n 40 -u stemdeck 2>&1 || true
    die "Web-UI antwortet nicht auf Port ${WEB_PORT}."
  }
  msg_ok "Web-UI antwortet auf 127.0.0.1:${WEB_PORT}/api/health (HTTP 200)."

  msg_info "Prüfe Bind-Adresse (muss 0.0.0.0:${WEB_PORT} sein, nicht nur 127.0.0.1) …"
  local bind_line
  bind_line="$(ss -tlnp 2>/dev/null | grep ":${WEB_PORT} " || true)"
  if [[ -z "$bind_line" ]]; then
    ss -tlnp || true
    die "Kein Listener auf Port ${WEB_PORT} gefunden!"
  fi
  if echo "$bind_line" | grep -q "127.0.0.1:${WEB_PORT}"; then
    echo "$bind_line"
    die "Dienst lauscht nur auf 127.0.0.1 -> von außerhalb NICHT erreichbar!"
  fi
  msg_ok "Dienst lauscht korrekt: $(echo "$bind_line" | awk '{print $4}')"
}

print_guest_summary() {
  local ip="${CT_IP:-127.0.0.1}"
  cat <<SUMMARY

==========================================================
  ${APP_NAME} wurde erfolgreich installiert ✔
==========================================================
  Web-UI      :  http://${ip}:${WEB_PORT}
  Version     :  $(cat /opt/stemdeck/installed_version.txt 2>/dev/null || echo unbekannt)
  Engine      :  Demucs htdemucs_6s (CPU) – erster Job lädt das
                 Modell (~170 MB) und ist deshalb langsamer
  Container   :  unprivileged LXC, onboot=1
  Daten       :  /var/lib/stemdeck (Jobs, Modelle, Logs)
  Dienst      :  systemctl status stemdeck
  Logs        :  ${GUEST_LOG_FILE} · journalctl -u stemdeck

  Update      :  Einzeiler auf dem Proxmox-Host erneut ausführen
                 (erkennt den Container automatisch) oder:
                 ./stemdeck.sh --update
  Deinstall   :  Auf dem Proxmox-Host: ./stemdeck.sh --uninstall
==========================================================

SUMMARY
}

guest_main() {
  msg_info "${APP_NAME} – Gast-Phase (MODE=${MODE}) auf $(hostname), Start: $(date -Is)."
  [[ $EUID -eq 0 ]] || die "Gast-Phase muss als root laufen."
  apt_install ca-certificates curl jq 2>/dev/null \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq

  install_app
  verify_service_and_web

  print_guest_summary
}

#==============================
# HOST-PHASE: Proxmox-Node
#==============================
check_host_prereqs() {
  [[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen (sudo su -)."
  [[ -d /etc/pve ]] || die "Dies ist kein Proxmox-VE-Host (/etc/pve fehlt). Script auf dem PVE-Node starten."
  local cmd
  for cmd in pct pvesm pveam pvesh curl openssl jq sha256sum; do
    have "$cmd" || die "Benötigtes Werkzeug nicht gefunden: $cmd – nur auf Proxmox VE ausführen."
  done
}

check_upstream_reachable() {
  if ! curl -fsSL --max-time 15 --retry 2 "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" >/dev/null; then
    die "GitHub-Releases von ${UPSTREAM_REPO} nicht erreichbar – Verbindung bzw. Tag prüfen."
  fi
  msg_ok "Upstream-Release-Quelle erreichbar: https://github.com/${UPSTREAM_REPO}/releases"
}

find_ct_by_name() {
  local vmid hostname
  while read -r vmid; do
    hostname="$(pct config "$vmid" 2>/dev/null | awk '/^hostname:/{print $2}')"
    if [[ "$hostname" == "$APP_ID" ]]; then
      printf '%s\n' "$vmid"
    fi
  done < <(pct list 2>/dev/null | awk 'NR>1{print $1}')
}

next_free_ctid() {
  pvesh get /cluster/nextid 2>/dev/null || printf '999\n'
}

# Liefert "Name<TAB>freieBytes" für alle aktiven Storages mit rootdir-Inhalt.
storage_rootdir_list() {
  local json=""
  json="$(pvesm status -content rootdir --output-format json 2>/dev/null || true)"
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    json="$(pvesm status -content rootdir -json 2>/dev/null || true)"
  fi
  if [[ -n "$json" ]] && printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '
      .[]
      | select(.active == 1)
      | select(((.content // "") | tostring) | contains("rootdir"))
      | [(.storage // .name), (.avail // 0)]
      | @tsv'
    return 0
  fi
  msg_warn "pvesm liefert kein gültiges JSON – nutze Tabellenausgabe mit Einheiten-Erkennung."
  pvesm status -content rootdir 2>/dev/null | awk '
    NR > 1 && $3 == "active" && NF >= 6 {
      n++; names[n] = $1; avail[n] = $6 + 0
      if (avail[n] > max) max = avail[n]
    }
    END {
      mult = (max >= 8589934592) ? 1 : 1024
      for (i = 1; i <= n; i++) printf "%s\t%d\n", names[i], avail[i] * mult
    }'
}

fmt_gib() { # fmt_gib <Bytes> → "123.4"
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'
}

storage_avail_bytes() { # storage_avail_bytes <Name>
  storage_rootdir_list | awk -v s="$1" '$1 == s { print $2; found = 1 } END { exit !found }'
}

select_storage() {
  local -a names=() frees=()
  local name avail

  if [[ -n "$STORAGE" ]] && storage_avail_bytes "$STORAGE" >/dev/null; then
    msg_info "Storage per Env vorgegeben und gültig: ${STORAGE} (frei: $(fmt_gib "$(storage_avail_bytes "$STORAGE")") GB)"
    return 0
  fi
  [[ -z "$STORAGE" ]] || msg_warn "Vorgegebener STORAGE '${STORAGE}' ist nicht aktiv/verfügbar – wähle neu."
  STORAGE=""

  while IFS=$'\t' read -r name avail; do
    names+=("$name")
    frees+=("$avail")
  done < <(storage_rootdir_list)

  ((${#names[@]})) || die "Kein aktiver Storage mit Inhaltstyp 'rootdir' gefunden ('pvesm status' prüfen)."

  if (( ${#names[@]} == 1 )) || [[ ! -t 0 ]]; then
    local best=0 i
    for i in "${!frees[@]}"; do
      (( ${frees[$i]} > ${frees[$best]} )) && best=$i
    done
    STORAGE="${names[$best]}"
    msg_info "Storage automatisch gewählt: ${STORAGE} (frei: $(fmt_gib "${frees[$best]}") GB)"
    return 0
  fi

  local i choice
  msg_info "Verfügbare Storages (rootdir):"
  for i in "${!names[@]}"; do
    printf '  %2d) %-20s frei: %s GB\n' "$((i+1))" "${names[$i]}" "$(fmt_gib "${frees[$i]}")" >&2
  done
  choice="$(ask_default "Welchen Storage verwenden?" "1")"
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
    STORAGE="${names[$((choice-1))]}"
  else
    die "Ungültige Storage-Auswahl: ${choice}"
  fi
}

ensure_capacity() {
  local need_bytes=$(( VAR_DISK * 1073741824 ))
  local avail_bytes
  avail_bytes="$(storage_avail_bytes "$STORAGE" 2>/dev/null || true)"
  [[ -n "$avail_bytes" ]] || { msg_warn "Freier Speicher von '${STORAGE}' nicht ermittelbar – Kapazitätscheck übersprungen."; return 0; }
  if (( avail_bytes < need_bytes )); then
    die "Storage '${STORAGE}' hat nur $(fmt_gib "$avail_bytes") GB frei – ${VAR_DISK} GB angefordert (VAR_DISK reduzieren oder anderen Storage wählen)."
  fi
  msg_ok "Kapazität ausreichend: $(fmt_gib "$avail_bytes") GB frei ≥ ${VAR_DISK} GB angefordert."
}

ensure_debian_template() {
  local tmpl
  msg_info "Suche neuestes ${VAR_OS}-${VAR_VERSION}-Standard-Template …"
  pveam update >/dev/null 2>&1 || true
  tmpl="$(pveam available --section system 2>/dev/null | awk '/debian-13-standard/{print $2}' | sort -rV | head -n1)"
  [[ -n "$tmpl" ]] || die "Kein debian-13-Template gefunden ('pveam available' manuell prüfen)."
  if ! pveam list local 2>/dev/null | grep -qF "local:vztmpl/${tmpl}"; then
    msg_info "Lade Template herunter: ${tmpl} …"
    pveam download local "$tmpl"
  else
    msg_info "Template bereits vorhanden: ${tmpl}"
  fi
  TEMPLATE="$tmpl"
}

validate_settings() {
  if ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || (( WEB_PORT < 1024 || WEB_PORT > 65535 )); then
    die "WEB_PORT muss zwischen 1024 und 65535 liegen (ist: ${WEB_PORT})."
  fi
  [[ "$NET_MODE" == "dhcp" || "$NET_MODE" == "static" ]] || die "NET_MODE muss 'dhcp' oder 'static' sein."
}

resolve_self() {
  local cand="${BASH_SOURCE[0]:-}"
  if [[ -z "$cand" || "$cand" == "bash" || ! -f "$cand" || ! -r "$cand" ]]; then
    cand="$0"
  fi
  if [[ -f "$cand" && -r "$cand" && "$(head -c 2 "$cand" 2>/dev/null)" == "#!" ]]; then
    readlink -f "$cand"
    return 0
  fi
  msg_warn "Script wurde gepipe't (kein lesbares Dateiobjekt) – lade Kopie für den Container-Transfer …"
  fetch_to "$SCRIPT_URL" "${TMPDIR_INSTALL}/${APP_ID}-install.sh"
  local path
  path="$(readlink -f "${TMPDIR_INSTALL}/${APP_ID}-install.sh")"
  [[ -s "$path" ]] || die "Heruntergeladene Installer-Kopie fehlt/ist leer: ${path}"
  printf '%s\n' "$path"
}

create_container() {
  msg_info "Erstelle LXC ${APP_ID} (ID ${CTID}, ${VAR_CPU} vCPU / ${VAR_RAM} MB RAM / ${VAR_DISK} GB Disk, unprivileged) …"
  local ct_password
  ct_password="$(openssl rand -hex 8)"
  local tz_args=()
  if [[ -n "${TIMEZONE_OVERRIDE:-}" ]]; then
    tz_args=(--timezone "$TIMEZONE_OVERRIDE")
  elif [[ -r /etc/timezone ]]; then
    tz_args=(--timezone "$(tr -d '[:space:]' </etc/timezone)")
  fi

  pct create "$CTID" "local:vztmpl/${TEMPLATE}" \
    --hostname "$APP_ID" \
    --password "$ct_password" \
    --unprivileged "$CT_TYPE" \
    --cores "$VAR_CPU" \
    --memory "$VAR_RAM" \
    --swap "$VAR_SWAP" \
    --rootfs "${STORAGE}:${VAR_DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},${NET_CFG},firewall=0" \
    --onboot 1 \
    --tags "community-scripts,${APP_ID}" \
    --description "${APP_NAME} – lokale Audio-Stem-Separation. Web-UI: http://<CT-IP>:${WEB_PORT} · Installer: bash -c \$(wget -qLO - ${SCRIPT_URL})" \
    "${tz_args[@]+"${tz_args[@]}"}" \
    --start 1

  msg_ok "Container erstellt (Konsolen-Passwort einmalig: ${ct_password} – ändern oder 'pct enter ${CTID}' nutzen)."
}

wait_for_ct_ip() {
  local attempts=45 ip="" i
  msg_info "Warte auf Netzwerk im Container …"
  for ((i = 1; i <= attempts; i++)); do
    ip="$(pct exec "$CTID" -- sh -c 'hostname -I 2>/dev/null' 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$ip" ]]; then
      break
    fi
    sleep 2
  done
  [[ -n "$ip" ]] || die "Container hat keine IP erhalten (DHCP/Netzwerk prüfen: pct enter ${CTID})."
  CT_IP="$ip"
  msg_ok "Container-IP: ${CT_IP}"
}

run_guest_phase() {
  local self_path
  self_path="$(resolve_self)"
  [[ "$self_path" != *$'\n'* && -s "$self_path" ]] ||
    die "Interner Fehler: Installer-Pfad ungültig (${self_path@Q})."

  msg_info "Übertrage Installer in den Container (Quelle: ${self_path}) …"
  if ! pct push "$CTID" "$self_path" "/root/${APP_ID}-install.sh" >/dev/null; then
    die "pct push konnte ${self_path} nicht in CT ${CTID} übertragen."
  fi
  if ! pct exec "$CTID" -- test -s "/root/${APP_ID}-install.sh"; then
    die "Installer nach pct push im Container nicht vorhanden/leer (/root/${APP_ID}-install.sh)."
  fi

  msg_info "Führe Gast-Installation aus (Live-Ausgabe unten; Log im Container: tail -f ${GUEST_LOG_FILE}) …"
  if ! pct exec "$CTID" -- env \
      SD_PHASE=guest \
      MODE="$MODE" \
      WEB_PORT="$WEB_PORT" \
      UPSTREAM_REPO="$UPSTREAM_REPO" \
      STEMDECK_VERSION="$STEMDECK_VERSION" \
      CT_IP="$CT_IP" \
      DEBUG="$DEBUG" \
      DEBIAN_FRONTEND=noninteractive \
      LC_ALL=C.UTF-8 LANG=C.UTF-8 \
      bash "/root/${APP_ID}-install.sh"; then
    msg_error "Gast-Phase fehlgeschlagen – Container-Logauszug:"
    pct exec "$CTID" -- tail -n 80 "$GUEST_LOG_FILE" 2>/dev/null || true
    die "Installation im Container fehlgeschlagen (siehe Auszug oben sowie $LOG_FILE)."
  fi
}

do_uninstall() {
  local target="${TARGET_CTID}"
  if [[ -z "$target" ]]; then
    target="$(find_ct_by_name | head -n1 || true)"
  fi
  [[ -n "$target" ]] || die "Kein ${APP_NAME}-Container gefunden (pct list)."
  msg_warn "Deinstalliert ${APP_NAME} inklusive ALLER Daten aus CT ${target}!"
  confirm_or_die "Wirklich löschen? (pct stop + pct destroy ${target})"
  pct stop "$target" >/dev/null 2>&1 || true
  pct destroy --purge "$target"
  msg_ok "Container ${target} entfernt."
}

show_help() {
  cat <<HELP
${APP_NAME} – Proxmox-Installer (Community-Scripts-Stil)

Aufruf:
  bash stemdeck.sh [Optionen]

Optionen:
  --update       Neuestes Release im vorhandenen Container installieren
  --uninstall    Container inkl. Daten entfernen (interaktive Bestätigung)
  --ctid N       Vorhandene/vorgesehene CT-ID verwenden bzw. aktualisieren
  --port N       Web-UI-Port (Default: ${WEB_PORT})
  --debug        Volles bash -x-Tracing
  -h | --help    Diese Hilfe

Env-Variablen (Auswahl): CTID VAR_DISK VAR_CPU VAR_RAM VAR_SWAP BRIDGE
  NET_MODE NET_CIDR NET_GW WEB_PORT STEMDECK_VERSION STORAGE DEBUG
  (Defaults stehen im Kopfteil des Scripts.)

Ressourcen-Hinweis: StemDeck betreibt ein Neuronales Netz (Demucs).
Die Defaults (${VAR_CPU} vCPU / ${VAR_RAM} MB RAM / ${VAR_DISK} GB Disk)
liegen bewusst über den üblichen Community-Script-Defaults; Minimum für
nutzbare CPU-Inferenz sind 2 vCPU / 4 GB RAM.
HELP
}

parse_args() {
  while (($#)); do
    case "$1" in
      --update) MODE="update" ;;
      --uninstall) MODE="uninstall" ;;
      --debug) DEBUG=1; enable_debug ;;
      --ctid) TARGET_CTID="$(ask_required_value "$1" "${2:-}")"; shift ;;
      --port) WEB_PORT="$(ask_required_value "$1" "${2:-}")"; shift ;;
      -h|--help) show_help; exit 0 ;;
      *) die "Unbekannte Option: $1 (--help anzeigen)" ;;
    esac
    shift
  done
}

host_main() {
  parse_args "$@"
  check_host_prereqs
  validate_settings
  check_upstream_reachable

  if [[ "$MODE" == "uninstall" ]]; then
    do_uninstall
    return 0
  fi

  cat <<BANNER
  ____  _____ ____ _   _ _____    ___  ____      _    ____ __  __
 / ___|| ____/ ___| | | |_   _|  / _ \|  _ \    / \  / ___|  \/  |
 \___ \|  _|\___ \ |_| | | |   | | | | |_) |  / _ \| |   | |\/| |
  ___) | |___ ___) |  _  | | |   | |_| |  _ <  / ___ \ |___| |  | |
 |____/|_____|____/|_| |_| |_|    \___/|_| \_\/_/   \_\____|_|  |_|

  StemDeck – Proxmox-LXC-Installer (Community-Scripts-Stil)
  Lokale Stem-Separation: Vocals · Drums · Bass · Gitarre · Piano · Other
BANNER

  # Existierenden Container erkennen → idempotent in den Update-Pfad schwenken
  local existing
  existing="$(find_ct_by_name | head -n1 || true)"
  if [[ -n "${TARGET_CTID}" ]]; then
    CTID="$TARGET_CTID"
    if [[ -n "$existing" && "$existing" != "$CTID" ]]; then
      msg_warn "Gefundener ${APP_ID}-Container hat ID ${existing}, gewünscht ist ${CTID}."
    fi
  elif [[ -n "$existing" ]]; then
    CTID="$existing"
  fi

  if [[ -n "$existing" && "$MODE" == "install" ]]; then
    MODE="update"
    msg_info "Vorhandener Container erkannt (ID ${existing}) – wechsle in den Update-Modus."
  fi

  if [[ "$MODE" == "update" ]]; then
    CTID="${CTID:?Keine CT-ID für Update ermittelbar (--ctid angeben)}"
    pct status "$CTID" >/dev/null 2>&1 || die "CT ${CTID} nicht gefunden (pct list)."
    if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
      msg_info "Starte gestoppten Container ${CTID} …"
      pct start "$CTID"
    fi
    wait_for_ct_ip
    run_guest_phase
    msg_ok "Update abgeschlossen → http://${CT_IP}:${WEB_PORT}"
    return 0
  fi

  # Frische Installation: Parameter erfragen
  CTID="${CTID:-$(next_free_ctid)}"
  CTID="$(ask_default "CT-ID" "$CTID")"
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige CT-ID: ${CTID}"
  if pct status "$CTID" >/dev/null 2>&1; then
    die "CT-ID ${CTID} ist bereits vergeben (pct list)."
  fi
  select_storage
  ensure_debian_template

  if [[ "$NET_MODE" == "static" ]]; then
    [[ -n "$NET_CIDR" && -n "$NET_GW" ]] || die "NET_MODE=static benötigt NET_CIDR und NET_GW."
    NET_CFG="ip=${NET_CIDR},gw=${NET_GW}"
  fi

  VAR_DISK="$(ask_default "Disk (GB) – StemDeck braucht Modell+venv+Stems" "$VAR_DISK")"
  VAR_CPU="$(ask_default "vCPU-Kerne" "$VAR_CPU")"
  VAR_RAM="$(ask_ram_mib "RAM (MB– auch GB funktioniert: 6 = 6 GB) – Demucs braucht 4-6 GB" "$VAR_RAM")"
  msg_ok "RAM gesetzt: ${VAR_RAM} MB ($((VAR_RAM / 1024)) GB)."

  ensure_capacity
  create_container
  wait_for_ct_ip
  run_guest_phase

  # Verifikation von außen (vom Proxmox-Host aus)
  msg_info "Verifikation von außen: ${APP_NAME} wirklich erreichbar?"
  local external_ok=0 http_code="" curl_rc=0 health_url="http://${CT_IP}:${WEB_PORT}/api/health"
  local attempt
  for attempt in 1 2 3 4 5; do
    # --noproxy: ein auf dem Host gesetzter http_proxy würde LAN-Requests verfälschen
    http_code="$(curl --noproxy '*' -s -m 5 -o /dev/null -w '%{http_code}' "$health_url" 2>/dev/null)"
    curl_rc=$?
    if [[ "$http_code" == "200" ]]; then
      external_ok=1
      break
    fi
    sleep 2
  done

  cat <<SUCCESS

========================================================================
  Installation abgeschlossen ✔   —   "Free, local stem separation."
------------------------------------------------------------------------
  Web-UI   :  http://${CT_IP}:${WEB_PORT}
  Container:  ${APP_ID} (ID ${CTID}, unprivileged, onboot=1)
  Einstieg :  pct enter ${CTID}
  Update   :  Einzeiler erneut ausführen (erkennt den Container automatisch)
               oder: bash stemdeck.sh --update
  Deinstall:  bash stemdeck.sh --uninstall
========================================================================

SUCCESS

  if (( external_ok == 0 )); then
    msg_warn "Web-UI war vom Host aus nach ${attempt} Versuchen noch nicht erreichbar"
    msg_warn "(letzter HTTP-Code: ${http_code:-keiner}, curl-rc: ${curl_rc})."
    msg_warn "Diagnose:"
    msg_warn "  pct exec ${CTID} -- systemctl status stemdeck"
    msg_warn "  pct exec ${CTID} -- journalctl -u stemdeck -n 60 --no-pager"
    msg_warn "  pct exec ${CT_ID:-$CTID} -- ss -tlnp | grep ${WEB_PORT}"
    exit 1
  fi
  msg_ok "Web-UI vom Host aus erreichbar (HTTP 200)."
}

#==============================
# Einstiegspunkt
#==============================
if [[ "$PHASE" == "guest" ]]; then
  # Gleichzeitig ins Gast-Log UND auf die Konsole (Live-Stream via pct exec).
  exec > >(tee -a "$GUEST_LOG_FILE") 2>&1
  guest_main
else
  SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh}"
  host_main "$@"
fi
