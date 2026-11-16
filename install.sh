#!/bin/bash
# Alerte Contexte — installation sur Mac.
#   curl -fsSL https://raw.githubusercontent.com/Pablitooo5/alerte-contexte/main/install.sh | bash
# Construit l'app sur ton Mac, la range dans ~/.claude/alerte-contexte et branche le hook « Stop » de Claude Code.
set -euo pipefail

REPO="Pablitooo5/alerte-contexte"
DEST="$HOME/.claude/alerte-contexte"
APP="$DEST/AlerteContexte.app"
SETTINGS="$HOME/.claude/settings.json"

say() { printf '%s\n' "$*"; }
fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

# --- Vérifications ---
[ "$(uname)" = "Darwin" ] || fail "Alerte Contexte ne fonctionne que sur Mac."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || fail "Il faut macOS 14 (Sonoma) ou plus récent."
xcrun --find swiftc >/dev/null 2>&1 || fail "Il manque les outils de développement d'Apple. Lance : xcode-select --install   puis relance l'installation."
[ -x /usr/bin/python3 ] || fail "python3 est introuvable. Lance : xcode-select --install"

# --- Récupérer les sources (dossier local, ou téléchargement depuis GitHub) ---
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [ -z "$SRC" ] || [ ! -f "$SRC/main.swift" ] || [ ! -f "$SRC/contexte.py" ]; then
  say "→ Téléchargement des sources"
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$SRC" --strip-components=1
fi

# --- Construire l'app ---
say "→ Construction de l'app (environ 30 secondes)"
pkill -x AlerteContexte 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DEST/events" "$DEST/state"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/overlay.html" "$APP/Contents/Resources/overlay.html"
/usr/bin/python3 -I "$SRC/make_sounds.py" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O "$SRC/main.swift" -o "$APP/Contents/MacOS/AlerteContexte" -framework Cocoa -framework WebKit
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
cp "$SRC/signal.sh" "$SRC/contexte.py" "$SRC/uninstall.sh" "$DEST/"
chmod +x "$DEST/signal.sh" "$DEST/uninstall.sh"

# --- Réglages : on devine la taille de mémoire de Claude d'après tes conversations récentes ---
if [ ! -f "$DEST/config.json" ]; then
  /usr/bin/python3 -I - "$DEST/config.json" <<'PY'
import glob, json, os, sys
files = sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")), key=os.path.getmtime, reverse=True)[:40]
biggest = 0
for path in files:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"usage"' not in line or '"assistant"' not in line:
                    continue
                try:
                    u = (json.loads(line).get("message") or {}).get("usage") or {}
                except Exception:
                    continue
                biggest = max(biggest, sum(int(u.get(k) or 0) for k in
                              ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")))
    except Exception:
        pass
window = 1000000 if biggest > 200000 else 200000
cfg = {"window": window, "percent": 50, "capOn": False, "cap": 300000, "paused": False, "sound": True}
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
print(f"   Mémoire de Claude détectée : {window:,} tokens".replace(",", " "))
PY
fi

# --- Brancher le hook de Claude Code ---
say "→ Branchement à Claude Code ($SETTINGS)"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.avant-alerte-contexte.bak"
/usr/bin/python3 -I - "$SETTINGS" "$DEST/signal.sh" <<'PY'
import json, os, sys
path, sig = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})
keep = [g for g in hooks.get("Stop", [])
        if not any("alerte-contexte/signal.sh" in (h.get("command") or "") for h in g.get("hooks", []))]
keep.append({"hooks": [{"type": "command", "command": f'"{sig}" check', "timeout": 10}]})
hooks["Stop"] = keep
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY

open -g "$APP"
say ""
say "✅ Alerte Contexte est installé."
say "   Une icône 🪧 est apparue dans la barre des menus : clique dessus → « Lancer la démo »."
say "   Pour désinstaller : ~/.claude/alerte-contexte/uninstall.sh"
