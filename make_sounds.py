"""Fabrique les bruitages d'Alerte Contexte (fichiers .wav), sans aucun fichier externe.
Usage : python3 make_sounds.py <dossier de sortie>"""
import math
import os
import struct
import sys
import wave

SR = 44100


def write(path, x, level=0.8):
    peak = max(1e-9, max(abs(v) for v in x))
    g = level / peak
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v * g)) * 32767)) for v in x))


def tone(dur, f0, f1, attack=0.01, vib_rate=0.0, vib_depth=0.0, shape="sine"):
    n, ph, out = int(SR * dur), 0.0, []
    for i in range(n):
        t = i / SR
        f = f0 * (f1 / f0) ** (t / dur)
        if vib_rate:
            f += vib_depth * math.sin(2 * math.pi * vib_rate * t)
        ph += 2 * math.pi * f / SR
        v = math.sin(ph) if shape == "sine" else (1.0 if math.sin(ph) > 0 else -1.0) * 0.4
        env = min(1.0, t / attack) * min(1.0, (dur - t) / 0.03)
        out.append(v * env)
    return out


def silence(dur):
    return [0.0] * int(SR * dur)


def pop():
    return [v * math.exp(-(i / SR) / 0.05) for i, v in enumerate(tone(0.14, 420, 900))]


def whistle():
    # Sifflet de contrôleur : deux coups, le second plus long, avec le roulement de la bille.
    return tone(0.2, 2600, 2550, vib_rate=32, vib_depth=140) + silence(0.08) + \
        tone(0.45, 2600, 2500, vib_rate=32, vib_depth=140)


def tick():
    return tone(0.03, 1500, 1400, attack=0.002, shape="square")


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    write(os.path.join(out_dir, "pop.wav"), pop(), 0.7)
    write(os.path.join(out_dir, "whistle.wav"), whistle(), 0.55)
    write(os.path.join(out_dir, "tick.wav"), tick(), 0.25)
