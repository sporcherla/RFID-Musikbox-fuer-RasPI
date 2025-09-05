#!/usr/bin/env bash
# ==================================================================
#  kiddy-music-box – Installer (RFID + MPD + FastAPI + Kiosk)
#  Raspberry Pi 3B+ oder höher, Raspberry Pi OS Lite (Bullseye/Bookworm)
#
#  Diese Version:
#   • FIX Admin-Reiter: RFID & Radios laden/anzeigen zuverlässig
#   • /api/rfid spielt Mappings (Folder/Radio/URL) ab
#   • Kiosk 800x480, Scale/DPI konfigurierbar
#   • Robuster Neuftech-USB-Reader, MPD/Uploads gefixt
# ==================================================================

set -euo pipefail

# -------------------- Variablen ------------------------------
PI_USER="${SUDO_USER:-pi}"
PI_HOME="$(getent passwd "$PI_USER" | cut -d: -f6)"

ROOT_DIR="$PI_HOME/kiddy-music-box"
APP_DIR="$ROOT_DIR/app"
RFID_DIR="$ROOT_DIR/rfid"
SHARED="$ROOT_DIR/shared"
AUDIOFOLDERS="$SHARED/audiofolders"
SHORTCUTS="$SHARED/shortcuts"

PORT="8080"
MPD_CONF="/etc/mpd.conf"

SERVICE_WEB="kmb-web"
SERVICE_RFID="kmb-rfid"

CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
if command -v chromium >/dev/null 2>&1; then
  BROWSER="chromium"
elif command -v chromium-browser >/dev/null 2>&1; then
  BROWSER="chromium-browser"
else
  if [[ "$CODENAME" == "bookworm" ]]; then BROWSER="chromium"; else BROWSER="chromium-browser"; fi
fi

# -------------------- Kiosk-Tuning-Parameter -----------------
echo "==> Kiosk-Tuning (Enter = Standard)"
read -r -p "Chromium Scale (0.9–1.5) [1.05]: " KMB_SCALE_INPUT || true
KMB_SCALE="${KMB_SCALE_INPUT:-1.05}"
read -r -p "Xft DPI (96–140) [110]: " KMB_DPI_INPUT || true
KMB_DPI="${KMB_DPI_INPUT:-110}"

# -------------------- Schritt 1: Pakete ----------------------
echo "==> [1/20] Pakete (IPv4 erzwingen)…"
echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 >/dev/null || true

sudo apt update
sudo apt install -y \
  mpd mpc python3-pip git curl python3-evdev \
  xserver-xorg x11-xserver-utils xinit openbox unclutter \
  fonts-dejavu-core

# Browser nachinstallieren, falls fehlt
if ! command -v "$BROWSER" >/dev/null 2>&1; then
  if [[ "$BROWSER" == "chromium" ]]; then
    sudo apt install -y chromium
  else
    sudo apt install -y chromium-browser || sudo apt install -y chromium || true
  fi
fi

echo "==> [2/20] Python-Abhängigkeiten…"
pip3 install --break-system-packages fastapi "uvicorn[standard]" python-mpd2 requests python-multipart aiofiles

# -------------------- Schritt 2: Verzeichnisse ---------------
echo "==> [3/20] Verzeichnisse…"
mkdir -p "$APP_DIR/static" "$RFID_DIR" "$AUDIOFOLDERS" "$SHORTCUTS"
chown -R "$PI_USER":"$PI_USER" "$ROOT_DIR"
mkdir -p "$PI_HOME/RPi-Jukebox-RFID"
[ -e "$PI_HOME/RPi-Jukebox-RFID/shared" ] || ln -s "$SHARED" "$PI_HOME/RPi-Jukebox-RFID/shared"

# -------------------- Schritt 3: MPD konfigurieren ----------
echo "==> [4/20] MPD-Konfiguration…"
USE_PULSE="no"; USE_PIPEWIRE="no"
if pactl info >/dev/null 2>&1 || command -v pulseaudio >/dev/null 2>&1; then USE_PULSE="yes"; fi
if command -v pw-cli >/dev/null 2>&1 || systemctl --user status pipewire >/dev/null 2>&1; then USE_PIPEWIRE="yes"; fi

sudo tee "$MPD_CONF" >/dev/null <<EOF
music_directory        "$AUDIOFOLDERS"
playlist_directory     "/var/lib/mpd/playlists"
db_file                "/var/lib/mpd/tag_cache"
state_file             "/var/lib/mpd/state"
sticker_file           "/var/lib/mpd/sticker.sql"

user                   "mpd"
bind_to_address        "localhost"
port                   "6600"
restore_paused         "yes"
auto_update            "yes"
filesystem_charset     "UTF-8"

audio_output {
    type        "alsa"
    name        "ALSA"
    mixer_type  "software"
}
EOF

if [[ "$USE_PULSE" == "yes" ]]; then
  sudo tee -a "$MPD_CONF" >/dev/null <<'EOF'
audio_output {
    type        "pulse"
    name        "PulseAudio"
}
EOF
fi
if [[ "$USE_PIPEWIRE" == "yes" ]]; then
  sudo tee -a "$MPD_CONF" >/dev/null <<'EOF'
audio_output {
    type        "pipewire"
    name        "PipeWire"
}
EOF
fi

sudo mkdir -p /var/lib/mpd/playlists
sudo chown -R mpd:audio /var/lib/mpd
sudo chmod -R 775 /var/lib/mpd

sudo mkdir -p "$AUDIOFOLDERS"
sudo chown -R "$PI_USER":"$PI_USER" "$ROOT_DIR"
sudo usermod -a -G audio "$PI_USER" || true
sudo usermod -a -G audio mpd || true
sudo chmod 755 "$PI_HOME"
sudo chmod -R a+rX "$ROOT_DIR"

sudo systemctl stop mpd || true
sudo rm -rf /run/mpd
sudo install -d -o mpd -g audio /run/mpd

sudo systemctl daemon-reload
sudo systemctl enable --now mpd
sleep 1
mpc update || true

# -------------------- Schritt 4: Radios Basisdatei ----------
echo "==> [5/20] Radios-Datei…"
cat > "$SHARED/webradios.json" <<'JSON'
{
  "kids_antenne_bayern": {
    "name": "Antenne Bayern – Hits für Kids",
    "url": "https://<HIER-DIREKTE-STREAM-URL-EINTRAGEN>"
  },
  "wdr_maus": {
    "name": "Die Maus im Radio (WDR)",
    "url": "https://<HIER-DIREKTE-STREAM-URL-EINTRAGEN>"
  }
}
JSON
chown "$PI_USER":"$PI_USER" "$SHARED/webradios.json"

# -------------------- Schritt 5: Backend ---------------------
echo "==> [6/20] Backend schreiben…"
cat > "$APP_DIR/main.py" << 'PY'
from fastapi import FastAPI, HTTPException, UploadFile, File, Form, Query
from fastapi.responses import FileResponse, StreamingResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pathlib import Path
from mimetypes import guess_type
from mpd import MPDClient
from pydantic import BaseModel
from typing import List, Optional, Dict, Any
import subprocess, json, io, csv, time

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
SHARED = ROOT / "shared"
AUDIOFOLDERS = SHARED / "audiofolders"
SHORTCUTS = SHARED / "shortcuts"
WEBRADIOS_FILE = SHARED / "webradios.json"
LAST_SEEN_FILE = SHARED / "last_seen_uid.json"

MUSIC_DIR = AUDIOFOLDERS
COVER_CANDIDATES = ["cover.jpg","cover.png","folder.jpg","folder.png","front.jpg","front.png","album.jpg","album.png"]

app = FastAPI(title="kiddy-music-box")
static_dir = BASE / "static"
app.mount("/static", StaticFiles(directory=static_dir), name="static")

@app.get("/", response_class=HTMLResponse)
def root():
    idx = static_dir / "index.html"
    return idx.read_text(encoding="utf-8")

def _mpd():
    c = MPDClient(); c.timeout = 5; c.idletimeout = None
    c.connect("localhost", 6600); return c

def _load_radios() -> Dict[str, Dict[str, Any]]:
    if WEBRADIOS_FILE.exists():
        try: return json.loads(WEBRADIOS_FILE.read_text(encoding="utf-8"))
        except Exception: return {}
    return {}

def _save_radios(data: Dict[str, Dict[str, Any]]):
    WEBRADIOS_FILE.parent.mkdir(parents=True, exist_ok=True)
    WEBRADIOS_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

def _is_rel_to(base: Path, p: Path) -> bool:
    try:
        p.resolve().relative_to(base.resolve()); return True
    except Exception:
        return False

def _safe_abs_in_music(rel: str) -> Path:
    p = (MUSIC_DIR / rel).resolve()
    if not _is_rel_to(MUSIC_DIR, p): raise HTTPException(400, "Pfad liegt außerhalb von audiofolders")
    return p

def _find_cover_in(folder: Path):
    for name in COVER_CANDIDATES:
        p = folder / name
        if p.exists(): return p
    for ext in ("*.jpg","*.jpeg","*.png","*.gif","*.webp"):
        pics = list(folder.glob(ext))
        if pics: return pics[0]
    return None

# ---------- Player ----------
class SeekBody(BaseModel): delta_sec: int
class VolumeBody(BaseModel): volume: int

@app.get("/api/state")
def state():
    c=_mpd()
    try:
        st=c.status(); cur=c.currentsong() or {}
    finally:
        c.close(); c.disconnect()
    return {
        "state": st.get("state"),
        "volume": int(st.get("volume","0")),
        "elapsed": float(st.get("elapsed","0")),
        "duration": float(st.get("duration","0")),
        "song": {
            "file": cur.get("file"),
            "title": cur.get("title") or cur.get("name") or (Path(cur.get("file","")).stem if cur.get("file") else None),
            "artist": cur.get("artist"),
            "album": cur.get("album")
        }
    }

@app.post("/api/play")
def play(): c=_mpd(); c.play(); c.close(); c.disconnect(); return {"ok":True}
@app.post("/api/pause")
def pause(): c=_mpd(); c.pause(1); c.close(); c.disconnect(); return {"ok":True}
@app.post("/api/resume")
def resume(): c=_mpd(); c.pause(0); c.close(); c.disconnect(); return {"ok":True}
@app.post("/api/stop")
def stop(): c=_mpd(); c.stop(); c.close(); c.disconnect(); return {"ok":True}
@app.post("/api/next")
def next(): c=_mpd(); c.next(); c.close(); c.disconnect(); return {"ok":True}
@app.post("/api/prev")
def prev(): c=_mpd(); c.previous(); c.close(); c.disconnect(); return {"ok":True}

@app.post("/api/seek")
def seek(body: SeekBody):
    c=_mpd(); st=c.status(); cur=float(st.get("elapsed","0"))
    new=max(0,cur+body.delta_sec); c.seekcur(int(new))
    c.close(); c.disconnect(); return {"ok":True,"position":new}

@app.post("/api/volume")
def volume(body: VolumeBody):
    v=max(0,min(100,body.volume)); c=_mpd(); c.setvol(v); c.close(); c.disconnect()
    return {"ok":True,"volume":v}

@app.post("/api/shutdown")
def shutdown():
    subprocess.Popen(["sudo","/sbin/shutdown","-h","now"]); return {"ok":True}

# ---------- Webradio: CRUD ----------
class RadioBody(BaseModel):
    id: str
    name: str
    url: str

@app.get("/api/radios")
def list_radios(): return _load_radios()

@app.post("/api/radios")
def upsert_radio(body: RadioBody):
    radios=_load_radios()
    radios[body.id]={"name": body.name, "url": body.url}
    _save_radios(radios)
    return {"ok":True, "id": body.id}

@app.delete("/api/radios/{radio_id}")
def delete_radio(radio_id: str):
    radios=_load_radios()
    if radio_id in radios:
        del radios[radio_id]; _save_radios(radios); return {"ok":True}
    raise HTTPException(404, "Radio nicht gefunden")

@app.post("/api/radio/{radio_id}/play")
def play_radio(radio_id: str):
    radios=_load_radios(); r=radios.get(radio_id)
    if not r or not r.get("url"): raise HTTPException(404, "Radio preset not found")
    c=_mpd()
    try:
        c.stop(); c.clear(); c.add(r["url"]); c.play()
    finally:
        c.close(); c.disconnect()
    return {"ok":True,"radio":radio_id}

# ---------- RFID: UID speichern + Mapping auflösen + abspielen ----------
class RFIDBody(BaseModel): uid: str

def _interpret_shortcut_content(content: str):
    s=content.strip()
    if s.lower().startswith("radio:"): return {"type":"radio","id":s.split(":",1)[1].strip()}
    if s.lower().startswith("http://") or s.lower().startswith("https://"): return {"type":"url","url":s}
    cand=(SHARED / s).resolve()
    if cand.is_dir(): return {"type":"folder","path":cand}
    return None

def _resolve_shortcut(uid: str):
    sc=SHORTCUTS/uid
    if not sc.exists(): return None
    if sc.is_symlink():
        target=sc.resolve()
        if target.is_dir(): return {"type":"folder","path":target}
        try: content=target.read_text(encoding="utf-8")
        except Exception: return None
        return _interpret_shortcut_content(content)
    if sc.is_file():
        try: content=sc.read_text(encoding="utf-8")
        except Exception: return None
        return _interpret_shortcut_content(content)
    if sc.is_dir(): return {"type":"folder","path":sc.resolve()}
    return None

@app.post("/api/rfid")
def rfid(body: RFIDBody):
    SHARED.mkdir(parents=True, exist_ok=True)
    LAST_SEEN_FILE.write_text(json.dumps({"uid":body.uid,"ts":time.time()}), encoding="utf-8")
    res=_resolve_shortcut(body.uid)
    if not res: raise HTTPException(404, "Shortcut/UID nicht gefunden")
    c=_mpd()
    try:
        c.stop(); c.clear()
        if res["type"]=="folder":
            folder=res["path"]
            if not str(folder).startswith(str(MUSIC_DIR)): raise HTTPException(400,"Ziel liegt nicht in audiofolders")
            rel=folder.relative_to(MUSIC_DIR); c.add(str(rel)); c.play(); return {"ok":True,"folder":str(rel)}
        if res["type"]=="radio":
            radios=_load_radios(); r=radios.get(res["id"])
            if not r or not r.get("url"): raise HTTPException(404,"Radio preset not found")
            c.add(r["url"]); c.play(); return {"ok":True,"radio":res["id"]}
        if res["type"]=="url":
            c.add(res["url"]); c.play(); return {"ok":True,"url":res["url"]}
        raise HTTPException(400,"Unbekannter Shortcut-Typ")
    finally:
        c.close(); c.disconnect()

@app.get("/api/cards/last_seen")
def last_seen_card():
    if LAST_SEEN_FILE.exists():
        try: return json.loads(LAST_SEEN_FILE.read_text(encoding="utf-8"))
        except Exception: pass
    return {"uid": None, "ts": None}

# ---------- Ordner / Dateien ----------
@app.get("/api/folders")
def list_folders(deep: bool = Query(False)):
    root=MUSIC_DIR
    items = sorted([str(p.relative_to(root)) for p in (root.rglob("*") if deep else root.iterdir()) if p.is_dir()])
    return {"root": str(root), "folders": items}

class NewFolderBody(BaseModel):
    name: str
    parent: Optional[str] = None

@app.post("/api/folders")
def create_folder(body: NewFolderBody):
    parent=_safe_abs_in_music(body.parent) if body.parent else MUSIC_DIR
    target=(parent/body.name).resolve()
    if not _is_rel_to(MUSIC_DIR, target): raise HTTPException(400,"Pfad außerhalb von audiofolders")
    target.mkdir(parents=True, exist_ok=True)
    return {"ok":True,"folder":str(target.relative_to(MUSIC_DIR))}

@app.delete("/api/folders")
def delete_folder(path: str = Query(...)):
    target=_safe_abs_in_music(path)
    if not target.exists() or not target.is_dir(): raise HTTPException(404,"Ordner nicht gefunden")
    try: target.rmdir()
    except OSError: raise HTTPException(400,"Ordner ist nicht leer")
    return {"ok":True}

@app.get("/api/files")
def list_files(path: str = Query(...)):
    folder=_safe_abs_in_music(path)
    if not folder.exists() or not folder.is_dir(): raise HTTPException(404,"Ordner nicht gefunden")
    files=[]
    for p in sorted(folder.iterdir()):
        if p.is_file(): files.append({"name":p.name,"size":p.stat().st_size})
    return {"folder":path,"files":files}

@app.post("/api/upload")
async def upload_files(path: str = Form(...), files: List[UploadFile] = File(...)):
    folder=_safe_abs_in_music(path)
    folder.mkdir(parents=True, exist_ok=True)
    saved=[]
    for f in files:
        dest=(folder / Path(f.filename).name)
        ext=dest.suffix.lower()
        if ext not in {".mp3",".flac",".m4a",".aac",".ogg",".wav",".wma",".jpg",".jpeg",".png",".gif",".webp",".bmp",".svg"}:
            raise HTTPException(400,f"Dateityp nicht erlaubt: {f.filename}")
        with dest.open("wb") as out:
            while True:
                chunk=await f.read(1024*1024)
                if not chunk: break
                out.write(chunk)
        saved.append(dest.name)
    return {"ok":True,"saved":saved}

@app.delete("/api/file")
def delete_file(path: str = Query(...), name: str = Query(...)):
    folder=_safe_abs_in_music(path)
    target=(folder/name).resolve()
    if not _is_rel_to(folder,target) or not target.exists() or not target.is_file(): raise HTTPException(404,"Datei nicht gefunden")
    target.unlink()
    return {"ok":True}

# ---------- Karten-CRUD ----------
@app.get("/api/cards")
def list_cards():
    cards=[]
    if not SHORTCUTS.exists(): return cards
    for sc in sorted(SHORTCUTS.iterdir()):
        uid=sc.name; entry={"uid":uid,"type":None,"target":None}
        if sc.is_symlink() and sc.resolve().is_dir():
            entry["type"]="folder"
            try: entry["target"]=str(sc.resolve().relative_to(AUDIOFOLDERS))
            except Exception: entry["target"]=str(sc.resolve())
        elif sc.is_file():
            try: content=sc.read_text(encoding="utf-8").strip()
            except Exception: content=""
            if content.lower().startswith("radio:"):
                entry["type"]="radio"; entry["target"]=content.split(":",1)[1].strip()
            elif content.lower().startswith("http://") or content.lower().startswith("https://"):
                entry["type"]="url"; entry["target"]=content
            else:
                cand=(SHARED/content).resolve()
                if cand.is_dir():
                    entry["type"]="folder"
                    try: entry["target"]=str(cand.relative_to(AUDIOFOLDERS))
                    except Exception: entry["target"]=str(cand)
        elif sc.is_dir():
            entry["type"]="folder"
            try: entry["target"]=str(sc.resolve().relative_to(AUDIOFOLDERS))
            except Exception: entry["target"]=str(sc.resolve())
        cards.append(entry)
    return cards

class CardBody(BaseModel):
    uid: str
    type: str
    target: str

@app.post("/api/cards")
def upsert_card(body: CardBody):
    sc=SHORTCUTS/body.uid
    SHORTCUTS.mkdir(parents=True, exist_ok=True)
    if body.type=="folder":
        folder=_safe_abs_in_music(body.target)
        if not folder.is_dir(): raise HTTPException(404,"Ordner nicht gefunden")
        if sc.exists() or sc.is_symlink(): sc.unlink()
        sc.symlink_to(folder)
        return {"ok":True,"uid":body.uid,"type":"folder","target":str(folder.relative_to(AUDIOFOLDERS))}
    if body.type=="radio":
        content=f"radio:{body.target}\n"
    elif body.type=="url":
        content=body.target.strip()+"\n"
    else:
        raise HTTPException(400,"Unbekannter Typ")
    if sc.exists() or sc.is_symlink(): sc.unlink()
    sc.write_text(content, encoding="utf-8")
    return {"ok":True,"uid":body.uid,"type":body.type,"target":body.target}

@app.delete("/api/cards/{uid}")
def delete_card(uid: str):
    sc=SHORTCUTS/uid
    if not sc.exists() and not sc.is_symlink(): raise HTTPException(404,"UID nicht gefunden")
    sc.unlink()
    return {"ok":True}

@app.get("/api/cards.csv")
def cards_csv():
    rows=[["uid","type","target"]]
    for item in list_cards():
        rows.append([item.get("uid"), item.get("type") or "", item.get("target") or ""])
    buf=io.StringIO(); w=csv.writer(buf, delimiter=";")
    for r in rows: w.writerow(r)
    buf.seek(0)
    return StreamingResponse(iter([buf.getvalue()]), media_type="text/csv",
                             headers={"Content-Disposition":"attachment; filename=kiddy_mappings.csv"})
PY

# -------------------- Schritt 6: Frontend -------------------
echo "==> [7/20] Frontend mit Reitern – FIX IDs & Reloads…"
cat > "$APP_DIR/static/index.html" << 'HTML'
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Kiddy Music Box</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 980px; margin: 1rem auto; padding: 0 1rem; background:#f6f7fb }
  .nav { display:flex; gap:.5rem; margin-bottom:1rem }
  .nav button { padding:.5rem .9rem; border:1px solid #ccc; background:#fff; border-radius:.5rem; cursor:pointer }
  .nav button.active { background:#e9f3ff; border-color:#9cc2ff }
  .grid { display:grid; gap:.75rem; }
  .row { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center }
  button { padding:.6rem .9rem; border:1px solid #ccc; border-radius:.5rem; background:#fff; cursor:pointer }
  .screen { border:1px solid #ddd; border-radius:.5rem; padding:1rem; background:#fff }
  .title { font-weight:600 }
  .muted { color:#666; font-size:.9rem }
  input[type=range]{ width:100% }
  img#cover { width:100%; margin:.5rem 0; border-radius:.5rem; border:1px solid #ddd; object-fit:cover; max-height:320px; background:#fafafa }
  .tabs { display:flex; gap:.5rem; margin-bottom:.5rem; }
  .tabs button { padding:.45rem .7rem; border:1px solid #ccc; background:#fff; border-radius:.45rem; }
  .tabs button.active { background:#eef4ff; border-color:#9cc2ff }
  .hidden { display:none }
  input, select { padding:.45rem .5rem; border:1px solid #ccc; border-radius:.45rem; background:#fff }
  .list { border:1px solid #ddd; border-radius:.5rem; padding:.5rem; max-height:380px; overflow:auto; background:#fff }
  .dd { border:2px dashed #bbb; border-radius:.5rem; padding:1rem; text-align:center; color:#555; background:#fafafa }
  .dd.drag { background:#eef7ff; border-color:#59f }
  .small { font-size:.9rem }
</style>
</head>
<body>
  <h1>Kiddy Music Box</h1>

  <div class="nav">
    <button id="tabPlayerBtn" class="active" onclick="showTab('player')">🎵 Player</button>
    <button id="tabAdminBtn" onclick="showTab('admin')">🛠️ Admin</button>
    <a class="small" href="/api/cards.csv" style="margin-left:auto">⬇️ CSV-Export</a>
  </div>

  <!-- Player -->
  <div id="tabPlayer" class="grid">
    <div class="screen">
      <div class="title" id="title">–</div>
      <div class="muted" id="meta">–</div>
      <div class="muted" id="time">0:00 / 0:00</div>
    </div>
    <img id="cover" alt="Cover" src="/static/placeholder_cover.svg" />
    <div class="row">
      <button onclick="call('prev')">⏮️</button>
      <button onclick="call('stop')">⏹️</button>
      <button onclick="call('pause')">⏸️</button>
      <button onclick="call('resume')">▶️</button>
      <button onclick="call('next')">⏭️</button>
    </div>
    <div class="row">
      <button onclick="seek(-10)">⏪ 10s</button>
      <button onclick="seek(10)">⏩ 10s</button>
    </div>
    <div>
      <label>Lautstärke</label>
      <input type="range" min="0" max="100" id="vol" oninput="setVol(this.value)" />
    </div>
    <div class="row">
      <select id="radioSelect"></select>
      <button onclick="playSelectedRadio()">📻 Radio spielen</button>
      <button onclick="shutdown()">🛑 Ausschalten</button>
    </div>
  </div>

  <!-- Admin -->
  <div id="tabAdmin" class="grid hidden">
    <div class="screen">
      <div class="tabs">
        <button id="aTabFolders" class="active" onclick="adminTab('folders')">📁 Ordner</button>
        <button id="aTabFiles" onclick="adminTab('files')">🗂️ Dateien</button>
        <button id="aTabRFID" onclick="adminTab('RFID')">🪪 RFID</button>
        <button id="aTabRadios" onclick="adminTab('Radios')">📻 Radios</button>
      </div>

      <!-- Ordner -->
      <div id="adminFolders">
        <div class="row small">
          <input id="newFolderName" placeholder="Neuer Ordnername">
          <select id="parentFolderSelect"></select>
          <button onclick="createFolder()">Ordner anlegen</button>
        </div>
        <div class="list" id="folderList"></div>
      </div>

      <!-- Dateien -->
      <div id="adminFiles" class="hidden">
        <div class="row small">
          <span>Aktueller Ordner: <strong id="curFolderName">–</strong></span>
        </div>
        <div id="dropzone" class="dd">Dateien hierher ziehen & ablegen (Audio/Cover)</div>
        <input id="fileInput" type="file" multiple style="margin:.5rem 0">
        <div class="list" id="fileList"></div>
      </div>

      <!-- RFID -->
      <div id="adminRFID" class="hidden">
        <div class="row small">
          <button onclick="refreshLastSeen()">🧲 Karte auflegen</button>
          <span>Letzte UID: <strong id="lastUid">–</strong></span>
          <span class="muted" id="lastUidAge"></span>
        </div>
        <div class="row small">
          <input id="uidInput" placeholder="UID eintippen oder übernehmen">
          <button onclick="useLastUid()">Letzte UID übernehmen</button>
        </div>
        <div class="row small">
          <label>Zieltyp:</label>
          <select id="cardType">
            <option value="folder">Ordner</option>
            <option value="radio">Radio</option>
            <option value="url">Direkte URL</option>
          </select>
          <select id="cardFolder"></select>
          <select id="cardRadio" class="hidden"></select>
          <input id="cardUrl" class="hidden" placeholder="https://…">
          <button onclick="saveCard()">Zuordnen/Speichern</button>
        </div>
        <div class="list" id="cardList"></div>
      </div>

      <!-- Radios -->
      <div id="adminRadios" class="hidden">
        <div class="row small">
          <input id="rId" placeholder="ID (z.B. kids_antenne_bayern)">
          <input id="rName" placeholder="Anzeigename">
          <input id="rUrl" placeholder="Direkte Stream-URL (mp3/aac)">
          <button onclick="saveRadio()">Speichern</button>
        </div>
        <div class="list" id="radioList"></div>
      </div>

    </div>
  </div>

  <script src="/static/app.js"></script>
</body>
</html>
HTML

cat > "$APP_DIR/static/app.js" << 'JS'
/* --------- Tab-Steuerung --------- */
function showTab(name){
  const isAdmin = name==='admin';
  document.getElementById('tabPlayer').classList.toggle('hidden', isAdmin);
  document.getElementById('tabAdmin').classList.toggle('hidden', !isAdmin);
  document.getElementById('tabPlayerBtn').classList.toggle('active', !isAdmin);
  document.getElementById('tabAdminBtn').classList.toggle('active', isAdmin);
  if(isAdmin){ loadAdmin(); adminTab('folders'); }
}

/* Feste ID-Map: vermeidet Schreibfehler (RFID/Radios) */
const ADMIN_IDS = {
  folders: {panel:'adminFolders', btn:'aTabFolders', onshow: ()=>loadFolders()},
  files:   {panel:'adminFiles',   btn:'aTabFiles',   onshow: ()=>{/* bleibt leer */}},
  RFID:    {panel:'adminRFID',    btn:'aTabRFID',    onshow: ()=>{loadCards(); refreshLastSeen();}},
  Radios:  {panel:'adminRadios',  btn:'aTabRadios',  onshow: ()=>loadRadios()},
};

function adminTab(key){
  Object.entries(ADMIN_IDS).forEach(([k,def])=>{
    document.getElementById(def.panel)?.classList.toggle('hidden', k!==key);
    document.getElementById(def.btn)?.classList.toggle('active', k===key);
  });
  ADMIN_IDS[key]?.onshow?.();
}

/* --------- Player-Steuerung --------- */
async function call(action){ await fetch(`/api/${action}`, {method:'POST'}); refresh(); }
async function seek(delta){ await fetch(`/api/seek`, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({delta_sec:delta})}); refresh(); }
async function setVol(v){ await fetch(`/api/volume`, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({volume:parseInt(v)})}); }
async function shutdown(){ if(confirm("Raspberry jetzt herunterfahren?")){ await fetch(`/api/shutdown`, {method:'POST'}); } }
function setCover(){ const img=document.getElementById('cover'); if(!img) return; img.onerror=()=>{img.src='/static/placeholder_cover.svg'}; img.src=`/api/cover?ts=${Date.now()}`; }
async function refresh(){
  const r=await fetch('/api/state'); const s=await r.json();
  const vol = document.getElementById('vol'); if(vol) vol.value = s.volume ?? 0;
  const title = s.song?.title || '–';
  const artist = s.song?.artist || ''; const album = s.song?.album || '';
  const tEl = document.getElementById('title'); if(tEl) tEl.textContent = title;
  const mEl = document.getElementById('meta'); if(mEl) mEl.textContent = [artist, album].filter(Boolean).join(' — ') || '–';
  const fmt=t=>{t=Math.floor(t||0); const m=Math.floor(t/60),sec=(t%60).toString().padStart(2,'0'); return `${m}:${sec}`;}
  const timeEl = document.getElementById('time'); if(timeEl) timeEl.textContent = `${fmt(s.elapsed)} / ${fmt(s.duration)}`;
  setCover();
}

/* --------- Radios --------- */
async function loadRadios(){
  const r = await fetch('/api/radios'); const radios = await r.json();
  const sel = document.getElementById('radioSelect');
  const cardRadio = document.getElementById('cardRadio');
  const list = document.getElementById('radioList');
  if(sel) sel.innerHTML = '';
  if(cardRadio) cardRadio.innerHTML='';
  if(list) list.innerHTML='';

  Object.entries(radios).forEach(([id, obj])=>{
    const name = obj.name || id; const url = obj.url || '';
    if(sel){ const opt1 = document.createElement('option'); opt1.value=id; opt1.textContent=name; sel.appendChild(opt1); }
    if(cardRadio){ const opt2 = document.createElement('option'); opt2.value=id; opt2.textContent=name; cardRadio.appendChild(opt2); }
    if(list){
      const row = document.createElement('div'); row.className='row small';
      row.innerHTML = `<code style="flex:1">${id}</code><span style="flex:1">${name}</span><span style="flex:2">${url}</span>
                       <button onclick="prefillRadio('${id}')">Bearb.</button>
                       <button onclick="delRadio('${id}')">Löschen</button>`;
      list.appendChild(row);
    }
  });
}
function prefillRadio(id){
  fetch('/api/radios').then(r=>r.json()).then(radios=>{
    const r = radios[id]; if(!r) return;
    document.getElementById('rId').value = id;
    document.getElementById('rName').value = r.name || '';
    document.getElementById('rUrl').value = r.url || '';
    adminTab('Radios');
  });
}
async function saveRadio(){
  const id = document.getElementById('rId').value.trim();
  const name = document.getElementById('rName').value.trim();
  const url = document.getElementById('rUrl').value.trim();
  if(!id || !name || !url){ alert('Bitte ID, Name und URL angeben'); return; }
  const r = await fetch('/api/radios', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({id, name, url})});
  if(!r.ok){ alert('Fehler beim Speichern'); return; }
  document.getElementById('rId').value=''; document.getElementById('rName').value=''; document.getElementById('rUrl').value='';
  await loadRadios(); alert('Gespeichert');
}
async function delRadio(id){
  if(!confirm(`Radio löschen?\n${id}`)) return;
  const r = await fetch(`/api/radios/${encodeURIComponent(id)}`, {method:'DELETE'});
  if(!r.ok){ alert('Fehler beim Löschen'); return; }
  await loadRadios();
}
async function playSelectedRadio(){
  const sel = document.getElementById('radioSelect'); if(!sel || !sel.value) return;
  await fetch(`/api/radio/${encodeURIComponent(sel.value)}/play`, {method:'POST'}); setTimeout(refresh, 300);
}

/* --------- Ordner/Dateien --------- */
async function loadFolders(){
  const r = await fetch('/api/folders?deep=true'); const data = await r.json();
  const list = document.getElementById('folderList');
  const selParent = document.getElementById('parentFolderSelect');
  const selCardFolder = document.getElementById('cardFolder');
  if(selParent){ selParent.innerHTML=''; const o=document.createElement('option'); o.value=''; o.textContent='(Wurzel)'; selParent.appendChild(o); }
  if(selCardFolder){ selCardFolder.innerHTML=''; }
  if(list) list.innerHTML = '';
  (data.folders||[]).forEach(rel=>{
    if(list){
      const row = document.createElement('div'); row.className='row small';
      row.innerHTML = `<a href="#" onclick="selectFolder('${rel}');adminTab('files');return false;" style="flex:1">${rel}</a>
                       <button onclick="deleteFolder('${rel}')">Löschen</button>`;
      list.appendChild(row);
    }
    if(selParent){ const optP = document.createElement('option'); optP.value=rel; optP.textContent=rel; selParent.appendChild(optP); }
    if(selCardFolder){ const optF = document.createElement('option'); optF.value=rel; optF.textContent=rel; selCardFolder.appendChild(optF); }
  });
}
async function createFolder(){
  const name = document.getElementById('newFolderName').value.trim();
  const parent = document.getElementById('parentFolderSelect').value || null;
  if(!name){ alert('Bitte Ordnername eingeben'); return; }
  const r = await fetch('/api/folders', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({name, parent})});
  if(!r.ok){ alert('Fehler beim Anlegen'); return; }
  document.getElementById('newFolderName').value=''; await loadFolders();
}
async function deleteFolder(rel){
  if(!confirm(`Ordner löschen? (nur wenn leer)\n${rel}`)) return;
  const r = await fetch(`/api/folders?path=${encodeURIComponent(rel)}`, {method:'DELETE'});
  if(!r.ok){ alert('Fehler (Ordner evtl. nicht leer)'); return; }
  await loadFolders();
  const cur = document.getElementById('curFolderName').textContent;
  if(cur===rel){ document.getElementById('fileList').innerHTML=''; document.getElementById('curFolderName').textContent='–'; }
}
async function selectFolder(rel){
  document.getElementById('curFolderName').textContent = rel;
  const r = await fetch(`/api/files?path=${encodeURIComponent(rel)}`); const data = await r.json();
  const list = document.getElementById('fileList');
  if(list) list.innerHTML = '';
  (data.files||[]).forEach(f=>{
    const row = document.createElement('div'); row.className='row small';
    row.innerHTML = `<span style="flex:1">${f.name}</span>
                     <span class="muted" style="width:100px;text-align:right">${(f.size/1024).toFixed(1)} KB</span>
                     <button onclick="deleteFile('${data.folder}','${f.name}')">🗑️</button>`;
    list.appendChild(row);
  });
}
async function deleteFile(folder, name){
  if(!confirm(`Datei löschen?\n${name}`)) return;
  const r = await fetch(`/api/file?path=${encodeURIComponent(folder)}&name=${encodeURIComponent(name)}`, {method:'DELETE'});
  if(!r.ok){ alert('Fehler beim Löschen'); return; }
  await selectFolder(folder);
}
const dz = document.getElementById('dropzone');
const fi = document.getElementById('fileInput');
if(dz){
  ['dragenter','dragover'].forEach(ev=>dz.addEventListener(ev, (e)=>{e.preventDefault(); dz.classList.add('drag');}));
  ['dragleave','drop'].forEach(ev=>dz.addEventListener(ev, (e)=>{e.preventDefault(); dz.classList.remove('drag');}));
  dz.addEventListener('drop', async (e)=>{
    const rel = document.getElementById('curFolderName').textContent;
    if(!rel || rel==='–'){ alert('Bitte zuerst einen Ordner wählen'); return; }
    const files = e.dataTransfer.files; if(!files.length) return;
    await doUpload(rel, files);
  });
}
if(fi){
  fi.addEventListener('change', async ()=>{
    const rel = document.getElementById('curFolderName').textContent;
    if(!rel || rel==='–'){ alert('Bitte zuerst einen Ordner wählen'); fi.value=''; return; }
    await doUpload(rel, fi.files); fi.value='';
  });
}
async function doUpload(rel, files){
  const fd = new FormData(); fd.append('path', rel);
  for(const f of files){ fd.append('files', f); }
  const r = await fetch('/api/upload', {method:'POST', body: fd});
  if(!r.ok){ alert('Upload fehlgeschlagen'); return; }
  await selectFolder(rel);
}

/* --------- RFID --------- */
function onTypeChange(){
  const t = document.getElementById('cardType').value;
  document.getElementById('cardFolder').classList.toggle('hidden', t!=='folder');
  document.getElementById('cardRadio').classList.toggle('hidden', t!=='radio');
  document.getElementById('cardUrl').classList.toggle('hidden', t!=='url');
}
document.getElementById('cardType')?.addEventListener('change', onTypeChange);

async function loadCards(){
  const r = await fetch('/api/cards'); const cards = await r.json();
  const el = document.getElementById('cardList'); if(!el) return;
  el.innerHTML = '';
  cards.forEach(c=>{
    const row = document.createElement('div'); row.className='row small';
    row.innerHTML = `<span style="width:160px"><code>${c.uid||''}</code></span>
                     <span style="width:80px">${c.type||''}</span>
                     <span style="flex:1">${c.target||''}</span>
                     <button onclick="delCard('${c.uid}')">🗑️</button>`;
    el.appendChild(row);
  });
}
async function saveCard(){
  const uid = document.getElementById('uidInput').value.trim(); if(!uid){ alert('Bitte UID eingeben'); return; }
  const type = document.getElementById('cardType').value; let target = '';
  if(type==='folder'){ target = document.getElementById('cardFolder').value; if(!target){ alert('Ordner wählen'); return; } }
  if(type==='radio'){ target = document.getElementById('cardRadio').value; if(!target){ alert('Radio wählen'); return; } }
  if(type==='url'){ target = document.getElementById('cardUrl').value.trim(); if(!target){ alert('URL eingeben'); return; } }
  const r = await fetch('/api/cards', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({uid, type, target})});
  if(!r.ok){ alert('Fehler beim Speichern'); return; }
  await loadCards(); alert('Gespeichert');
}
async function delCard(uid){
  if(!confirm(`Zuordnung für ${uid} löschen?`)) return;
  const r = await fetch(`/api/cards/${encodeURIComponent(uid)}`, {method:'DELETE'});
  if(!r.ok){ alert('Fehler beim Löschen'); return; }
  await loadCards();
}
async function refreshLastSeen(){
  const r = await fetch('/api/cards/last_seen'); const d = await r.json();
  const uid = d.uid || '–'; document.getElementById('lastUid').textContent = uid;
  if(d.ts){ const age = Math.max(0, Math.floor(Date.now()/1000 - d.ts)); document.getElementById('lastUidAge').textContent = `(${age}s)`; }
  else { document.getElementById('lastUidAge').textContent = ''; }
}
function useLastUid(){ const uid = document.getElementById('lastUid').textContent; if(uid && uid!=='–'){ document.getElementById('uidInput').value = uid; } }

/* --------- Admin Init --------- */
async function loadAdmin(){ await loadFolders(); await loadRadios(); await loadCards(); onTypeChange(); }

/* --------- Ticker --------- */
setInterval(refresh, 1500); refresh(); loadRadios();
showTab('player');
JS

cat > "$APP_DIR/static/placeholder_cover.svg" << 'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"><rect width="120" height="120" fill="#eee"/><circle cx="60" cy="60" r="34" fill="#ddd"/><circle cx="60" cy="60" r="6" fill="#bbb"/></svg>
SVG

# -------------------- Schritt 7: RFID Reader -----------------
echo "==> [8/20] RFID-Reader (Neuftech USB-HID)…"
cat > "$RFID_DIR/reader_usb.py" << 'PY'
#!/usr/bin/env python3
import time, logging, requests, select
from evdev import InputDevice, categorize, ecodes, list_devices

API = "http://127.0.0.1:8080/api/rfid"
LOGLEVEL = logging.INFO
MIN_LEN = 5
POST_TIMEOUT = 2.0

logging.basicConfig(level=LOGLEVEL, format="%(asctime)s %(levelname)s: %(message)s")

DIGIT_KEYS = {
    ecodes.KEY_0:'0', ecodes.KEY_1:'1', ecodes.KEY_2:'2', ecodes.KEY_3:'3',
    ecodes.KEY_4:'4', ecodes.KEY_5:'5', ecodes.KEY_6:'6', ecodes.KEY_7:'7',
    ecodes.KEY_8:'8', ecodes.KEY_9:'9',
    ecodes.KEY_KP0:'0', ecodes.KEY_KP1:'1', ecodes.KEY_KP2:'2', ecodes.KEY_KP3:'3',
    ecodes.KEY_KP4:'4', ecodes.KEY_KP5:'5', ecodes.KEY_KP6:'6', ecodes.KEY_KP7:'7',
    ecodes.KEY_KP8:'8', ecodes.KEY_KP9:'9',
    ecodes.KEY_A:'A', ecodes.KEY_B:'B', ecodes.KEY_C:'C', ecodes.KEY_D:'D',
    ecodes.KEY_E:'E', ecodes.KEY_F:'F'
}
ENTER_KEYS = {ecodes.KEY_ENTER, ecodes.KEY_KPENTER}

def enumerate_candidate_devices():
    devs = []
    for path in list_devices():
        d = InputDevice(path)
        name = (d.name or "").lower()
        caps = d.capabilities().keys()
        if ecodes.EV_KEY not in caps:
            continue
        if any(x in name for x in ["mouse","touch","video","camera","power button"]):
            continue
        devs.append(d)
    return devs

def post_uid(uid: str):
    try:
        r = requests.post(API, json={"uid": uid}, timeout=POST_TIMEOUT)
        if r.status_code == 200:
            logging.info("RFID OK POST: %s", uid)
        else:
            logging.warning("Unbekannte Karte (%s): %s", uid, r.text)
    except Exception as e:
        logging.error("POST-Fehler: %s", e)

def main():
    logging.info("Starte RFID-Reader (evdev, multi-device, KP-Enter)…")
    devs = enumerate_candidate_devices()
    if not devs:
        logging.error("Keine passenden Eingabegeräte gefunden. In 3s neuer Versuch…")
        time.sleep(3)
        devs = enumerate_candidate_devices()
    if not devs:
        logging.error("Abbruch: keine EV_KEY-Devices.")
        return

    for d in devs:
        logging.info("Device: %s (%s)", d.name, d.path)
        try: d.grab()
        except Exception as e: logging.warning("Kein exklusiver Zugriff auf %s (ok): %s", d.path, e)

    buf = []; last_t = 0.0
    try:
        while True:
            r, _, _ = select.select(devs, [], [], 1.0)
            if not r:
                if buf and (time.time() - last_t > 1.0): buf.clear()
                continue
            for dev in r:
                for event in dev.read():
                    if event.type != ecodes.EV_KEY: continue
                    keyevent = categorize(event)
                    if keyevent.keystate != keyevent.key_down: continue
                    code = keyevent.scancode
                    now = time.time()
                    if now - last_t > 1.0 and buf: buf.clear()
                    last_t = now

                    if code in ENTER_KEYS:
                        uid = ''.join(buf).strip(); buf.clear()
                        if len(uid) >= MIN_LEN:
                            logging.info("UID gelesen: %s", uid)
                            post_uid(uid); time.sleep(0.2)
                        continue
                    ch = DIGIT_KEYS.get(code)
                    if ch: buf.append(ch)
    finally:
        for d in devs:
            try: d.ungrab()
            except Exception: pass

if __name__ == "__main__":
    main()
PY
chmod +x "$RFID_DIR/reader_usb.py"
chown -R "$PI_USER":"$PI_USER" "$ROOT_DIR"

# -------------------- Schritt 8: udev-Regel ------------------
echo "==> [9/20] udev-Regel (input-Gruppe)…"
echo 'KERNEL=="event*", SUBSYSTEM=="input", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-input.rules >/dev/null
sudo udevadm control --reload || true
sudo udevadm trigger || true
sudo usermod -a -G input "$PI_USER" || true

# -------------------- Schritt 9: Services --------------------
echo "==> [10/20] Services (Web & RFID)…"
sudo tee /etc/systemd/system/${SERVICE_WEB}.service >/dev/null <<SERVICE
[Unit]
Description=kiddy-music-box Web (FastAPI)
After=network.target mpd.service

[Service]
User=$PI_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port $PORT
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

sudo tee /etc/systemd/system/${SERVICE_RFID}.service >/dev/null <<SERVICE
[Unit]
Description=kiddy-music-box RFID Reader (USB HID)
After=network-online.target

[Service]
User=$PI_USER
WorkingDirectory=$RFID_DIR
ExecStart=/usr/bin/python3 $RFID_DIR/reader_usb.py
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

# -------------------- Schritt 10: Kiosk (Autologin + 800x480)
echo "==> [11/20] Kiosk via Autologin + ~/.bash_profile + xrandr 800x480…"

sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $PI_USER --noclear %I \$TERM
EOF
sudo systemctl daemon-reload
sudo systemctl restart getty@tty1.service

sudo -u "$PI_USER" mkdir -p "$PI_HOME/.config/openbox"
sudo -u "$PI_USER" bash -lc "cat > '$PI_HOME/.config/openbox/autostart' <<'AUTOSTART'
unclutter -idle 1 &
xset -dpms; xset s off; xset s noblank
if command -v xrandr >/dev/null 2>&1; then
  xrandr --output DSI-1  --mode 800x480 2>/dev/null || \
  xrandr --output HDMI-1 --mode 800x480 2>/dev/null || true
fi
echo -e 'Xft.dpi: __KMB_DPI__' | xrdb -merge
sleep 2
BROWSER_BIN=\"$(command -v chromium || command -v chromium-browser)\"
\$BROWSER_BIN \
  --kiosk \
  --app=http://localhost:8080 \
  --window-size=800,480 \
  --force-device-scale-factor=__KMB_SCALE__ \
  --noerrdialogs --disable-infobars --disable-session-crashed-bubble \
  --check-for-update-interval=31536000 \
  --overscroll-history-navigation=0 \
  --no-first-run --disable-translate &
AUTOSTART"
sudo sed -i "s#__KMB_SCALE__#${KMB_SCALE}#g" "$PI_HOME/.config/openbox/autostart"
sudo sed -i "s#__KMB_DPI__#${KMB_DPI}#g"   "$PI_HOME/.config/openbox/autostart"
sudo -u "$PI_USER" bash -lc "cat > '$PI_HOME/.bash_profile' <<'BASH'
if [[ -z \$DISPLAY && \$(tty) == /dev/tty1 ]]; then
  startx -- -nocursor
  logout
fi
BASH"
sudo -u "$PI_USER" bash -lc "echo 'exec openbox-session' > '$PI_HOME/.xinitrc'"

# -------------------- Schritt 11: Berechtigungen -------------
echo "==> [12/20] Shutdown ohne Passwort…"
echo "$PI_USER ALL=NOPASSWD:/sbin/shutdown" | sudo tee /etc/sudoers.d/kiddy-music-box >/dev/null

# -------------------- Schritt 12: Dienste starten ------------
echo "==> [13/20] Dienste aktivieren…"
sudo systemctl daemon-reload
sudo systemctl enable --now mpd ${SERVICE_WEB} ${SERVICE_RFID}

# -------------------- Schritt 13: Hinweise -------------------
echo "==> [14/20] Hinweis: ggf. einmal ab-/anmelden (input-Gruppe)."

# -------------------- Schritt 14: Schnelltests ---------------
echo "==> [15/20] API-Check…"; sleep 1
curl -sS http://127.0.0.1:$PORT/api/state || true
echo "==> [16/20] RFID-Log (letzte 20)…"
sudo journalctl -u ${SERVICE_RFID} -n 20 --no-pager || true

# -------------------- Schritt 15: config.txt (optional) ------
echo "==> [17/20] Optional: framebuffer 800x480 in /boot/config.txt setzen?"
read -r -p "config.txt anpassen (framebuffer_width/height)? (y/N) " yn || true
if [[ "${yn,,}" == "y" ]]; then
  sudo sed -i '/^#*framebuffer_width=/d;/^#*framebuffer_height=/d' /boot/config.txt
  echo "framebuffer_width=800"  | sudo tee -a /boot/config.txt >/dev/null
  echo "framebuffer_height=480" | sudo tee -a /boot/config.txt >/dev/null
fi

# -------------------- Schritt 16: Feste IP (optional) --------
echo "==> [18/20] (Optional) feste IP setzen"
read -r -p "Feste IP setzen? (y/N) " yn || true
if [[ "${yn,,}" == "y" ]]; then
  read -r -p "Interface (eth0/wlan0) [wlan0]: " ifc; ifc=${ifc:-wlan0}
  read -r -p "IP (z.B. 192.168.1.60/24): " ip
  read -r -p "Gateway (z.B. 192.168.1.1): " gw
  read -r -p "DNS (z.B. 192.168.1.1): " dns
  sudo bash -c "cat >> /etc/dhcpcd.conf" <<EOF

interface $ifc
static ip_address=$ip
static routers=$gw
static domain_name_servers=$dns
EOF
fi

# -------------------- Schritt 17: Kiosk-Hinweis --------------
echo "==> [19/20] Kiosk: Scale=${KMB_SCALE}, DPI=${KMB_DPI}. Anpassbar durch erneutes Skript-Ausführen."

# -------------------- Schritt 18: Neustart -------------------
read -r -p "Jetzt neu starten? (Y/n) " yn || true
if [[ "${yn,,}" != "n" ]]; then
  echo "==> [20/20] Reboot…"
  sudo reboot
else
  echo "==> Fertig. Kiosk startet beim nächsten Login auf tty1 automatisch."
fi
