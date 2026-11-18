# Instalación de la API (para Claude Code)

> Este archivo está escrito para que **Claude Code lo lea y haga la instalación**.
> Si eres una persona: abre Claude Code en la carpeta del repo y pídele
> *"Lee docs/INSTALACION.md e instala la API de MickHub"*.

Claude: sigue los pasos en orden. Antes de cada comando que instale algo, cree
una base de datos o use `sudo`, dile al usuario qué vas a hacer y por qué. No
inventes valores: lo que no sepas, pregúntalo.

La app de escritorio y el comando `mickhub` **no necesitan esta API**: con ella
vacía funcionan igual, solo sin resúmenes de commits ni mensajes con IA. Esta
guía es solo para esa parte (`api/`).

---

## Paso 1. Elegir el modo (pregunta al usuario)

La API guarda los resúmenes en una PostgreSQL y llama a DeepSeek. El código es
el mismo en todos los modos; lo único que cambia es **dónde corre la API y dónde
vive la Postgres** (`DATABASE_URL`). No hay ningún flag de modo.

> ¿Vas a usar los resúmenes en **un solo equipo** o en **varios** (o el celular)?

| Respuesta | Modo | Dónde |
|---|---|---|
| Un solo equipo (o no sabe) | **Local** (recomendado para empezar) | API y Postgres en este equipo, solo en `127.0.0.1` |
| Varios equipos o el celular | **Nube** | API y Postgres en un servidor al que lleguen todos (Railway) |

Si duda, elige **Local**: se pasa a la nube después sin perder nada (ver al
final). Ojo: en local cada equipo tiene sus propios resúmenes; un commit ya
resumido en otro equipo se vuelve a resumir (y a pagar) aquí.

---

## Paso 2. Requisitos

Verifica (no instales sin avisar):

- `python3 --version` -> 3.11 o más.
- Una API key de DeepSeek (`https://platform.deepseek.com`). Pídesela al
  usuario; **nunca la escribas en un archivo versionado**, solo en `api/.env`.

## Paso 3. Código y dependencias

```bash
cd api
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt        # Windows: .venv\Scripts\pip
```

**NixOS**: si al arrancar falla con `ImportError` de `libz.so.1` o `libstdc++`,
hace falta `programs.nix-ld.enable = true` y exportar
`LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib` (igual que en
mcp-context).

---

## Paso 4a. Postgres en modo LOCAL

Elige la primera opción que exista en el equipo:

1. **Docker o Podman** (lo más limpio, no toca el sistema):

   ```bash
   # Genera una contraseña aleatoria y úsala aquí y en DATABASE_URL.
   docker run -d --name mickhub-db --restart unless-stopped \
     -e POSTGRES_PASSWORD=<contraseña-generada> -e POSTGRES_DB=mickhub \
     -p 127.0.0.1:5433:5432 -v mickhub-pg:/var/lib/postgresql/data \
     postgres:17
   ```

   El `127.0.0.1:` del `-p` importa: la base queda solo para este equipo. Usa el
   puerto 5433 para no chocar con la de mcp-context si ya corre en 5432.

2. **Postgres del sistema** (si ya está instalada, p. ej. la de mcp-context):
   crear una base `mickhub` aparte y usar ese usuario.

   En **NixOS** se declara en `/etc/nixos/configuration.nix`
   (`services.postgresql.enable = true;` y `ensureDatabases = [ "mickhub" ];`) y
   se aplica con `sudo -A nixos-rebuild switch`; avisa antes al usuario.

`DATABASE_URL=postgresql://postgres:<contraseña>@127.0.0.1:5433/mickhub`

## Paso 4b. Modo NUBE (Railway)

Es como está en producción: proyecto con un servicio `api` (desde `api/`, con
`railway up`; `railway.json` ya trae el comando de arranque y el healthcheck) y el
plugin de Postgres, cuya URL va como referencia en `DATABASE_URL`. Las variables
del Paso 5 van en el servicio, no en un `.env`.

---

## Paso 5. Archivo `api/.env`

```bash
cp .env.example .env      # estando en api/
```

Completar:

- `MICKHUB_API_TOKEN`: uno largo y aleatorio
  (`python3 -c 'import secrets;print(secrets.token_urlsafe(32))'`).
- `DATABASE_URL`: la del Paso 4a.
- `DEEPSEEK_API_KEY`.

**No hay que crear tablas**: la API las crea sola al arrancar
(`CREATE TABLE IF NOT EXISTS`).

## Paso 6. Arrancar la API (modo local)

Prueba a mano primero:

```bash
.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8765 --env-file .env
```

`--host 127.0.0.1`, nunca `0.0.0.0` en local: así nadie de la red llega a ella.

Para que arranque sola al iniciar sesión:

- **Linux (systemd de usuario, sin sudo)**: `~/.config/systemd/user/mickhub-api.service`

  ```ini
  [Unit]
  Description=API de MickHub (local)

  [Service]
  WorkingDirectory=<ruta-absoluta>/api
  ExecStart=<ruta-absoluta>/api/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8765 --env-file .env
  Restart=on-failure

  [Install]
  WantedBy=default.target
  ```

  ```bash
  systemctl --user daemon-reload
  systemctl --user enable --now mickhub-api
  ```

  En NixOS, si hace falta nix-ld, agregar
  `Environment=LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib`.

- **Windows (Programador de tareas, sin ventana)**:

  ```bat
  schtasks /create /sc onlogon /tn "MickHub API" /tr "\"<ruta>\api\.venv\Scripts\pythonw.exe\" -m uvicorn main:app --app-dir \"<ruta>\api\" --host 127.0.0.1 --port 8765 --env-file \"<ruta>\api\.env\""
  ```

---

## Paso 7. Conectar la app

En el `settings.json` de la app (Linux: `~/.local/share/com.mickaell.mickhub/settings.json`;
Windows: `%APPDATA%\com.mickaell\mickhub\settings.json`), poner `apiUrl` y
`apiToken`. Editar escribiendo atómico (archivo temporal + rename) y conservando
las demás claves; la app lo vigila y se recarga sola.

- Local: `"apiUrl": "http://127.0.0.1:8765"`.
- Nube: la URL pública del servicio.

## Paso 8. Verificar

1. `curl http://127.0.0.1:8765/health` -> `{"ok":true}`.
2. `curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/summaries` -> `401`
   (sin token se niega).
3. En la app, aparece la pestaña **Resúmenes** (Ctrl+3). Abrir un commit en el
   Historial: el resumen aparece en unos segundos. Si falla con un error de
   DeepSeek, revisar la key y `DEEPSEEK_MODEL`.

Cuéntale al usuario el modo elegido, dónde quedó la base y cómo se arranca la API.

---

## Pasar de local a la nube

Nada se pierde:

1. Crear la Postgres de la nube (Paso 4b).
2. `pg_dump <url-local> | psql <url-nube>`
3. Cambiar `apiUrl` (y `apiToken` si es otro) en el `settings.json` de cada equipo.
4. Apagar la local: `systemctl --user disable --now mickhub-api` o borrar la tarea
   de Windows.

---

[Volver al README](../README.md)
