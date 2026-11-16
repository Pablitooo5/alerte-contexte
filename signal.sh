#!/bin/bash
# Alerte Contexte — appelé par le hook « Stop » de Claude Code.
#   check : calcule le contexte de la conversation et prévient l'app si besoin
#   demo  : lance la démo
# Ne bloque jamais Claude : aucune sortie, toujours code 0.
DIR="$HOME/.claude/alerte-contexte"
APP="$DIR/AlerteContexte.app"

if [ "$1" = "demo" ]; then
  pgrep -xq AlerteContexte || open -g "$APP"
  touch "$DIR/demo"
  exit 0
fi

/usr/bin/python3 -I "$DIR/contexte.py" >/dev/null 2>&1
if ls "$DIR/events/"*.json >/dev/null 2>&1; then
  pgrep -xq AlerteContexte || open -g "$APP"
fi
exit 0
