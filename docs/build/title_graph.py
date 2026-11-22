"""Titulo animado estilo "Graph" del README: el nombre se arma sobre un grafo de commits.

Uso: python3 docs/build/title_graph.py [PALABRA] [salida.svg]
Frame 0 = completo (legible donde no hay animacion: npm, lectores que rasterizan).
Despues se apaga, la rama se dibuja, cada commit que aparece enciende su letra,
una rama sale y vuelve (merge) y un commit naranja recorre la linea en bucle.
"""

import sys

WORD = sys.argv[1] if len(sys.argv) > 1 else "MickHub"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/screenshots/title.svg"
SPLIT = 4  # letras en color claro; el resto, en azul ("Mick" + "Hub")
W, H, T, FS = 760, 170, 8.0, 72
FONT = "'DejaVu Sans Mono','JetBrains Mono',Consolas,monospace"
BLUE, ORANGE, GREEN, TEXT = "#2E8FFF", "#F0883E", "#3FB950", "#E6EDF3"

cw = 0.6 * FS  # ancho de un caracter monospace
x0 = W / 2 - cw * len(WORD) / 2
cs = [x0 + cw * i + cw / 2 for i in range(len(WORD))]
Y, L0, L1 = 126, cs[0] - 90, cs[-1] + 90
L = L1 - L0


def f(x):
    """Momento (fraccion de T) en que la rama que se dibuja llega a x."""
    return 0.09 + 0.45 * (x - L0) / L


def r3(v):
    return f"{v:.3f}"


def anim(attr, values, times):
    return f'<animate attributeName="{attr}" values="{values}" keyTimes="{times}" dur="{T}s" repeatCount="indefinite"/>'


def node(x, y, col, fi, r=7):
    return (f'  <circle cx="{x:.1f}" cy="{y}" r="{r}" fill="#0D1117" stroke="{col}" stroke-width="3">'
            + anim("r", f"{r};{r};0;0;{r + 4};{r};{r}", f"0;0.04;0.08;{r3(fi)};{r3(fi + .025)};{r3(fi + .05)};1") + "</circle>")


out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" fill="none" role="img" aria-label="{WORD}">',
       '  <!-- Estilo "Graph" (generado por docs/build/title_graph.py): el nombre se arma sobre un grafo de commits. -->',
       '  <defs><filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3"/></filter></defs>']
out.append(f'  <path d="M{L0:.1f} {Y} H{L1:.1f}" stroke="{BLUE}" stroke-width="3" stroke-linecap="round" stroke-dasharray="{L:.1f}" stroke-dashoffset="0">'
           + anim("stroke-dashoffset", f"0;0;{L:.1f};{L:.1f};0;0", f"0;0.04;0.08;{r3(f(L0))};{r3(f(L1))};1") + "</path>")
# Rama de una tarea: sale tras la 2da letra y vuelve (merge, verde) en la 5ta.
a, b = cs[1], cs[min(4, len(cs) - 1)]
branch = f"M{a:.1f} {Y} C{a + 20:.1f} {Y} {a + 20:.1f} {Y + 30} {a + 40:.1f} {Y + 30} L{b - 40:.1f} {Y + 30} C{b - 20:.1f} {Y + 30} {b - 20:.1f} {Y} {b:.1f} {Y}"
out.append(f'  <path d="{branch}" stroke="{ORANGE}" stroke-width="3" stroke-linecap="round" stroke-dasharray="200" stroke-dashoffset="0">'
           + anim("stroke-dashoffset", "0;0;200;200;0;0", f"0;0.04;0.08;{r3(f(a))};{r3(f(b))};1") + "</path>")
out.append(node((a + b) / 2, Y + 30, ORANGE, (f(a) + f(b)) / 2))
for i, x in enumerate(cs):
    out.append(node(x, Y, GREEN if x == b else BLUE, f(x)))
for i, (ch, x) in enumerate(zip(WORD, cs)):
    fi = f(x)
    out.append(f'  <text x="{x:.1f}" y="88" text-anchor="middle" font-family="{FONT}" font-size="{FS}" font-weight="bold" fill="{TEXT if i < SPLIT else BLUE}">{ch}'
               + anim("opacity", "1;1;0;0;1;1", f"0;0.04;0.08;{r3(fi)};{r3(fi + .04)};1")
               + f'<animateTransform attributeName="transform" type="translate" values="0 0;0 0;0 14;0 14;0 0;0 0" keyTimes="0;0.04;0.08;{r3(fi)};{r3(fi + .05)};1" dur="{T}s" repeatCount="indefinite"/></text>')
# Commit que recorre la rama ya armada (invisible en el primer frame).
out.append(f'''  <g opacity="0">
    <circle r="9" fill="{ORANGE}" filter="url(#glow)"/>
    <circle r="4.5" fill="#FFD8B0"/>
    <animateMotion path="M{L0:.1f} {Y} H{L1:.1f}" keyPoints="0;0;1;1" keyTimes="0;0.6;0.93;1" calcMode="linear" dur="{T}s" repeatCount="indefinite"/>
    {anim("opacity", "0;0;1;1;0;0", "0;0.6;0.62;0.91;0.93;1")}
  </g>
</svg>''')
with open(OUT, "w") as fh:
    fh.write("\n".join(out) + "\n")
