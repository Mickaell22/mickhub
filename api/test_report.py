"""Check del recorte de /report, sin base ni IA: `.venv/bin/python test_report.py`."""

import os

os.environ.update(MICKHUB_API_TOKEN="t", DATABASE_URL="postgresql://x", DEEPSEEK_API_KEY="x", REPORT_MAX_CHARS="400")

from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402

sent = []
main._ask = lambda system, user: (sent.append(user), ("ok", 0, 0))[1]
api = TestClient(main.app, headers={"Authorization": "Bearer t"})


def items(n, body):
    return [{"repo": "r", "author": a, "date": f"2026-11-{d:02d}T10:00:00", "summary": f"título {a}{d}\n{body}"}
            for d in range(1, n + 1) for a in ("Ana", "Zoe")]


# Entra entero: va el resumen completo.
assert api.post("/report", json={"period": "hoy", "team": True, "items": items(1, "detalle")}).json()["cut"] == 0
assert "detalle" in sent[-1]
# No entra entero: va solo la primera línea de cada uno, de todos los autores (antes se perdía Zoe).
r = api.post("/report", json={"period": "x", "team": True, "items": items(3, "x" * 300)}).json()
assert r["cut"] == 0 and "xxx" not in sent[-1] and "título Zoe3" in sent[-1], sent[-1]
# Ni así: se cortan los más viejos, no un autor entero.
r = api.post("/report", json={"period": "x", "team": True, "items": items(10, "")}).json()
assert r["cut"] > 0 and "título Ana10" in sent[-1] and "título Zoe10" in sent[-1] and "título Ana1\n" not in sent[-1]
assert api.post("/report", json={"period": "x", "team": True, "items": []}).status_code == 400
assert TestClient(main.app).post("/report", json={"period": "x", "team": True, "items": []}).status_code == 401
print("ok")
