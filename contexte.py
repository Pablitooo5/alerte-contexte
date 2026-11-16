"""Alerte Contexte — appelé par le hook « Stop » de Claude Code, quand Claude vient de finir une réponse.

Lit le fichier de la conversation, calcule la taille du contexte (en tokens), et dépose une alerte
pour l'app si un seuil vient d'être franchi. Ne bloque jamais Claude : aucune sortie, toujours code 0.
Rien n'est envoyé sur Internet.
"""
import json
import os
import sys
import time

HOME = os.path.expanduser("~")
DIR = os.path.join(HOME, ".claude", "alerte-contexte")
EVENTS = os.path.join(DIR, "events")
STATE = os.path.join(DIR, "state")
CONFIG = os.path.join(DIR, "config.json")

DEFAULTS = {"window": 200000, "percent": 50, "capOn": False, "cap": 300000, "paused": False}


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG) as f:
            cfg.update(json.load(f))
    except Exception:
        pass
    return cfg


def scan(path):
    """Taille du contexte au dernier échange, taille maximale vue, et titre de la conversation."""
    last = 0
    biggest = 0
    title = None
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"custom-title"' in line:
                try:
                    title = json.loads(line).get("customTitle") or title
                except Exception:
                    pass
                continue
            if '"usage"' not in line or '"assistant"' not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("type") != "assistant" or e.get("isSidechain"):
                continue
            u = (e.get("message") or {}).get("usage") or {}
            total = sum(int(u.get(k) or 0) for k in
                        ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"))
            if total > 0:
                last = total
                biggest = max(biggest, total)
    return last, biggest, title


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    cfg = load_config()
    if cfg.get("paused"):
        return
    path = data.get("transcript_path")
    if not path or not os.path.exists(path):
        return
    sid = "".join(c if c.isalnum() or c in "-_" else "_" for c in str(data.get("session_id") or "default"))

    tokens, biggest, title = scan(path)
    if tokens <= 0:
        return

    # Si la conversation a déjà dépassé la taille réglée, c'est que Claude a une mémoire plus grande.
    window = int(cfg.get("window") or 200000)
    if biggest > window:
        window = 1000000 if biggest <= 1000000 else biggest

    percent = float(cfg.get("percent") or 50)
    first = window * percent / 100
    if cfg.get("capOn"):
        first = min(first, float(cfg.get("cap") or 300000))
    second = max(first * 1.2, min(window * 0.85, first * 1.5))

    level = 2 if tokens >= second else 1 if tokens >= first else 0

    os.makedirs(STATE, exist_ok=True)
    state_path = os.path.join(STATE, sid + ".json")
    shown = 0
    try:
        with open(state_path) as f:
            shown = int(json.load(f).get("level", 0))
    except Exception:
        pass
    if level < shown:             # conversation compactée, ou seuil changé : on repart de là
        shown = level

    if level > shown:
        cwd = data.get("cwd") or ""
        name = title or os.path.basename(cwd.rstrip("/"))
        if not name or name.startswith("scratch-"):
            name = "Cette conversation"
        event = {
            "title": name,
            "tokens": tokens,
            "window": window,
            "pct": round(tokens * 100 / window),
            "threshold": round(first * 100 / window),
            "level": level,
        }
        os.makedirs(EVENTS, exist_ok=True)
        tmp = os.path.join(EVENTS, f".{sid}.tmp")
        with open(tmp, "w") as f:
            json.dump(event, f, ensure_ascii=False)
        os.replace(tmp, os.path.join(EVENTS, f"{int(time.time() * 1000)}-{sid}.json"))
        shown = level

    with open(state_path, "w") as f:
        json.dump({"level": shown, "tokens": tokens}, f)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
