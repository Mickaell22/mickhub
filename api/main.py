"""API de MickHub: resúmenes de commits con DeepSeek, guardados por hash.

La app manda el diff; la key de DeepSeek y la base viven solo aquí. Un solo
usuario (el dueño): se autentica con un token fijo en MICKHUB_API_TOKEN.
"""

import hmac
import os
from contextlib import asynccontextmanager
from datetime import datetime

import anthropic
from fastapi import Depends, FastAPI, Header, HTTPException
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel


def _require(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise RuntimeError(f"Falta la variable de entorno {name}")
    return v


API_TOKEN = _require("MICKHUB_API_TOKEN")
DATABASE_URL = _require("DATABASE_URL")
DEEPSEEK_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
DEEPSEEK_BASE_URL = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com/anthropic")
# DeepSeek retira nombres de modelo sin avisar: por eso va en el entorno.
DEEPSEEK_MODEL = os.environ.get("DEEPSEEK_MODEL", "deepseek-flash")
# En los modelos v4 el razonamiento sale de este presupuesto; corto, la
# respuesta llega vacía.
DEEPSEEK_MAX_TOKENS = int(os.environ.get("DEEPSEEK_MAX_TOKENS", "8192"))
DEEPSEEK_TIMEOUT = float(os.environ.get("DEEPSEEK_TIMEOUT", "120"))
# Lo que entra del diff a la IA; el resto se corta para no quemar tokens.
MAX_DIFF_CHARS = int(os.environ.get("MAX_DIFF_CHARS", "60000"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS summaries (
  hash TEXT PRIMARY KEY,
  repo TEXT NOT NULL,
  author TEXT NOT NULL,
  email TEXT NOT NULL,
  date TIMESTAMPTZ NOT NULL,
  message TEXT NOT NULL,
  summary TEXT NOT NULL,
  is_merge BOOLEAN NOT NULL DEFAULT FALSE,
  truncated BOOLEAN NOT NULL DEFAULT FALSE,
  model TEXT,
  tokens_in INT NOT NULL DEFAULT 0,
  tokens_out INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS summaries_repo_date ON summaries (repo, date DESC);
"""

pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=4, open=False, kwargs={"row_factory": dict_row})


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open()
    with pool.connection() as c:
        c.execute(SCHEMA)
    yield
    pool.close()


app = FastAPI(title="MickHub API", lifespan=lifespan)


def auth(authorization: str = Header("")):
    if not hmac.compare_digest(authorization.encode(), f"Bearer {API_TOKEN}".encode()):
        raise HTTPException(401, "Token inválido")


class Commit(BaseModel):
    hash: str
    repo: str
    author: str
    email: str
    date: datetime
    message: str
    parents: int
    diff: str = ""


PROMPT = (
    "Te paso un commit de git (mensaje y diff). Escribe en español qué cambió de verdad, "
    "sin repetir el mensaje si es vago. Describe, no revises: nada de opinar ni señalar errores. Formato: una primera "
    "línea corta con el resumen (estilo Conventional Commits: tipo(ámbito): qué), una línea "
    "en blanco y luego de 1 a 6 viñetas con '- ' sobre lo importante (qué hace, por qué si se "
    "deduce, archivos clave). Sin markdown extra, sin saludo, sin cerrar con preguntas."
)


def _summarize(c: Commit) -> tuple[str, bool, int, int]:
    """(resumen, truncado, tokens de entrada, tokens de salida)."""
    if not DEEPSEEK_API_KEY:
        raise HTTPException(503, "La API no tiene DEEPSEEK_API_KEY")
    diff = c.diff[:MAX_DIFF_CHARS]
    truncated = len(c.diff) > MAX_DIFF_CHARS
    client = anthropic.Anthropic(
        api_key=DEEPSEEK_API_KEY,
        base_url=DEEPSEEK_BASE_URL,
        timeout=DEEPSEEK_TIMEOUT,
        # El SDK mezcla ANTHROPIC_CUSTOM_HEADERS del entorno; nada de eso debe ir a DeepSeek.
        default_headers={"x-proxy-key": anthropic.Omit()},
    )
    note = "\n\n[El diff se cortó por tamaño; resume con lo visible.]" if truncated else ""
    r = client.messages.create(
        model=DEEPSEEK_MODEL,
        max_tokens=DEEPSEEK_MAX_TOKENS,
        system=PROMPT,
        messages=[{"role": "user", "content": f"Mensaje:\n{c.message}\n\nDiff:\n{diff}{note}"}],
    )
    text = "".join(b.text for b in r.content if b.type == "text").strip()
    if not text:
        raise HTTPException(502, "DeepSeek respondió sin texto")
    return text, truncated, r.usage.input_tokens, r.usage.output_tokens


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/summaries/{hash}", dependencies=[Depends(auth)])
def get_summary(hash: str):
    with pool.connection() as c:
        row = c.execute("SELECT * FROM summaries WHERE hash = %s", (hash,)).fetchone()
    if not row:
        raise HTTPException(404, "Sin resumen")
    return row


@app.post("/summaries", dependencies=[Depends(auth)])
def create_summary(commit: Commit):
    """Devuelve el resumen del commit; si no existe lo crea. Un hash se resume una sola vez."""
    with pool.connection() as c:
        row = c.execute("SELECT * FROM summaries WHERE hash = %s", (commit.hash,)).fetchone()
    if row:
        return row
    if commit.parents > 1:
        # Los merges no gastan tokens: su contenido ya está en los commits que unen.
        summary = (commit.message.splitlines() or ["Merge"])[0]
        truncated, tin, tout, model = False, 0, 0, None
    else:
        # ponytail: dos pedidos a la vez del mismo hash pagan la IA dos veces (gana el
        # primero en guardar). Con un solo usuario es raro; si molesta, un advisory lock por hash.
        summary, truncated, tin, tout = _summarize(commit)
        model = DEEPSEEK_MODEL
    with pool.connection() as c:
        c.execute(
            """INSERT INTO summaries (hash, repo, author, email, date, message, summary, is_merge,
                                      truncated, model, tokens_in, tokens_out)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT (hash) DO NOTHING""",
            (commit.hash, commit.repo, commit.author, commit.email, commit.date, commit.message, summary,
             commit.parents > 1, truncated, model, tin, tout),
        )
        return c.execute("SELECT * FROM summaries WHERE hash = %s", (commit.hash,)).fetchone()


@app.get("/summaries", dependencies=[Depends(auth)])
def search(q: str = "", repo: str = "", author: str = "", limit: int = 50, offset: int = 0):
    """Busca en mensaje, resumen, autor y hash. Más nuevos primero."""
    where, args = [], []
    if q:
        where.append("(message ILIKE %s OR summary ILIKE %s OR author ILIKE %s OR hash LIKE %s)")
        args += [f"%{q}%"] * 3 + [f"{q}%"]
    if repo:
        where.append("repo = %s")
        args.append(repo)
    if author:
        where.append("(author ILIKE %s OR email ILIKE %s)")
        args += [f"%{author}%"] * 2
    sql = "SELECT * FROM summaries" + (" WHERE " + " AND ".join(where) if where else "")
    sql += " ORDER BY date DESC LIMIT %s OFFSET %s"
    with pool.connection() as c:
        return c.execute(sql, (*args, min(max(limit, 1), 200), max(offset, 0))).fetchall()
