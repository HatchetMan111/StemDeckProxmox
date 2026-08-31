# StemDeck für Proxmox VE

[StemDeck](https://github.com/stemdeckapp/stemdeck) als Ein-Klick-LXC auf jedem
Proxmox-VE-Host – installiert im Stil der **Proxmox VE Community Scripts**
(community-scripts.github.io/ProxmoxVE) mit einem einzigen Einzeiler.

Droppe ein MP3/WAV/FLAC/MP4 in die Web-UI und StemDeck trennt den Song lokal in
bis zu sechs Stems (Vocals, Drums, Bass, Gitarre, Piano, Other) – DAW-artiger
Mixer, Waveform-Zoom, Loop, Export. Kein Account, kein Upload, keine Cloud:
alles läuft im Container auf deinem eigenen Server.

## Installation (Einzeiler auf dem Proxmox-Host)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh)"
```

Alternativ per `curl`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh)"
```

Das Script (als root ausführen, z. B. `sudo su -`):

- erstellt einen **unprivilegierten Debian-13-LXC** (`onboot: 1`, startet nach
  Host-Reboot automatisch)
- installiert StemDeck aus dem offiziellen Upstream-Release (GitHub, gepinnt
  auf den neuesten Tag) inkl. `ffmpeg` und `deno` (yt-dlp-JS-Runtime)
- richtet den systemd-Dienst `stemdeck` ein (`Restart=always`,
  `After=network-online.target`, bind `0.0.0.0:8000`)
- prüft selbst: Dienst aktiv, Web-UI antwortet (HTTP-Check `/api/health`),
  Bind-Adresse `0.0.0.0` – und meldet am Ende die finale URL.

Am Ende erscheint:

```
========================================================================
  Installation abgeschlossen ✔   —   "Free, local stem separation."
------------------------------------------------------------------------
  Web-UI   :  http://<Container-IP>:8000
  ...
========================================================================
```

## Ressourcen

StemDeck betreibt ein Neuronales Netz (Demucs `htdemucs_6s`). Die Defaults
liegen deshalb **bewusst** über den üblichen Community-Script-Werten
(1 vCPU / 1 GB RAM reichen hier schlicht nicht):

| Ressource | Default | Anmerkung |
|---|---|---|
| vCPU | 4 | nutzbar ab 2 (nur langsam) |
| RAM | 8 GB | CPU-Inferenz braucht real 4–6 GB |
| Swap | 8 GB | Puffer, damit Demucs nicht OOM stirbt |
| Disk | 30 GB | venv ~4 GB + Modell ~170 MB + Stems (~1–3 GB/Job) |

Alle Werte sind im Install-Dialog änderbar oder per Env vorbelegbar:

```bash
CTID=160 VAR_CPU=2 VAR_RAM=4096 VAR_DISK=20 \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh)"
```

## LXC oder VM?

- **LXC (dieses Script):** CPU-Inferenz. Für gelegentliches Trennen einzelner
  Songs völlig ausreichend, dafür wartungsfrei via Einzeiler.
- **VM, wenn leistungshungrig:** Für NVIDIA-GPU-Beschleunigung (CUDA-Torch)
  eine VM nehmen – GPU-Passthrough in unprivilegierten LXC ist nur mit
  erheblichem Aufwand (NVIDIA-Container-Toolkit, `nesting`, Treiber-Matching)
  machbar. Grober Weg: VM mit PCIe-GPU-Passthrough, dort StemDeck per
  Upstream-Docker (`ghcr.io/stemdeckapp/stemdeck`, `--runtime=nvidia`) oder
  direkt aus dem [Upstream-Repo](https://github.com/stemdeckapp/stemdeck)
  betreiben (`STEMDECK_DEMUCS_DEVICE=cuda`).

## Update / Deinstallation

Das Script ist **idempotent**: Erneutes Ausführen erkennt den vorhandenen
Container am Hostname `stemdeck` und schwenkt automatisch in den Update-Modus
(neuestes Release, Daten in `/var/lib/stemdeck` bleiben erhalten).

```bash
# Update – einfach der Einzeiler erneut, oder gezielt:
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh)" # erkennt Container

# Gezielt in einem vorhandenen CT:
pct exec <CTID> -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh)"

# Deinstallation (DESTRUKTIV – Container inkl. aller Stems/Daten löschen):
./stemdeck.sh --uninstall
```

## Debugging

Bei Fehlern gibt das Script **immer die komplette Fehlermeldungskette** aus:
Exit-Code, fehlgeschlagenes Kommando, Call-Stack, `systemctl status`,
`journalctl`-Auszug, offene Ports, Speicher/Platte – und verweist auf das
vollständige Log (`/tmp/stemdeck-install-*.log` auf dem Host,
`/var/log/stemdeck-install.log` im Container).

Vollständiges `bash -x`-Tracing (jede Anweisung mit Zeitstempel + Zeilennummer):

```bash
DEBUG=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/StemdeckProxmox/main/install/stemdeck.sh)"
```

Nützliche Diagnose-Befehle:

```bash
pct exec <CTID> -- systemctl status stemdeck
pct exec <CTID> -- journalctl -u stemdeck -n 60 --no-pager
pct exec <CTID> -- curl -s http://127.0.0.1:8000/api/health
```

## Reboot-Sicherheit (Testprotokoll)

Anlage ist `onboot: 1` + systemd `Restart=always`. So belegst du die
Reboot-Sicherheit nach:

```bash
# 1) Zustand nach Installation
pct exec <CTID> -- systemctl is-active stemdeck        # → active
pct exec <CTID> -- curl -s http://127.0.0.1:8000/api/health
#    → {"status":"ok",...,"version":"0.16.0",...}

# 2) Container rebooten
pct reboot <CTID> && sleep 20

# 3) Erwartete Ausgabe nach Reboot
pct exec <CTID> -- systemctl is-active stemdeck        # → active
pct exec <CTID> -- systemctl is-enabled stemdeck       # → enabled
pct exec <CTID> -- curl -s http://127.0.0.1:8000/api/health
#    → {"status":"ok",...}  (Web-UI wieder erreichbar)

# Optional: auch den Proxmox-Host rebooten – Container startet automatisch
# (onboot=1) und der Dienst kommt via systemd hoch.
```

## Erste Nutzung

1. `http://<CT-IP>:8000` öffnen.
2. Audio-Datei (MP3, WAV, FLAC, OGG/Opus, MP4, M4A) auf die Import-Leiste
   ziehen, Stems per Chips wählen, **Process** klicken.
3. **Hinweis:** Der allererste Job lädt das Demucs-Modell (~170 MB) herunter
   und ist deshalb deutlich langsamer; danach gecacht unter
   `/var/lib/stemdeck/cache`.
4. Mixer: Play/Pause, `M` mute, `S` solo, Fader, Loop per Ruler, Stems als WAV
   exportieren.

## Dateien in diesem Repo

| Datei | Zweck |
|---|---|
| `install/stemdeck.sh` | Proxmox-Installer (Community-Scripts-Stil, Host- + Gast-Phase) |
| `stemdeck.service` | systemd-Unit (Referenz; wird vom Installer identisch in den Container geschrieben) |

App-Code selbst kommt zur Installationszeit direkt aus dem
[Upstream-Release](https://github.com/stemdeckapp/stemdeck/releases) – hier
liegt nur die Proxmox-Integration.

## Lizenz / Credits

- Installer-Vorlage im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE)
  (community-scripts ORG, tteck – MIT)
- [StemDeck](https://github.com/stemdeckapp/stemdeck) (Apache-2.0) mit
  [Demucs](https://github.com/facebookresearch/demucs) (MIT) von Meta AI
