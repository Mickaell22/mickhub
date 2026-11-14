# MickHub

Cliente de git de escritorio a mi medida, para Windows y Linux, con vista de solo lectura en Android.

- Todos mis repos de GitHub y Azure DevOps en una lista, con filtros y clonado en un clic.
- Cambios locales protegidos que nunca se cuelan en un commit.
- Historial con resúmenes por IA de lo que hizo cada commit y cada rama, buscable por hash, autor o texto.
- Temas, temporadas y personajes animados en los espacios vacíos.

## Descargar

Ejecutables portables, sin instalador: se descomprimen y se abren.

- **Linux x64**: [mickhub-linux-x64.tar.gz](https://github.com/Mickaell22/mickhub/releases/latest/download/mickhub-linux-x64.tar.gz) → `tar -xzf mickhub-linux-x64.tar.gz` y abrir `MickHub/mickhub`.
- **Windows x64**: [mickhub-windows-x64.zip](https://github.com/Mickaell22/mickhub/releases/latest/download/mickhub-windows-x64.zip) → descomprimir y abrir `MickHub\MickHub.exe`.

Necesita `git` instalado; en Windows, con el Git Credential Manager (viene con Git for Windows). Cada release trae `SHA256SUMS.txt` para verificar las descargas. MickHub avisa sola cuando hay una versión nueva y se actualiza en el lugar (verifica el SHA256 antes de instalar).

## Atajos

`Ctrl+T` repositorio · `Ctrl+B` rama · `Ctrl+Shift+N` nueva rama · `Ctrl+1`/`Ctrl+2`/`Ctrl+3` Cambios/Historial/Resúmenes · `Ctrl+Shift+P` fetch/pull/push · `Ctrl+Enter` commit · `Ctrl+Shift+F` abrir carpeta · `Ctrl+Shift+A` abrir en el editor (con el archivo seleccionado) · `Ctrl+`` ` abrir en la terminal · `F5` refrescar · `Ctrl+/` todos los atajos.

## Resúmenes con IA (opcional)

Al abrir un commit en el Historial, MickHub muestra qué hizo de verdad, escrito por DeepSeek a partir del diff. Corre en una API propia (`api/`, FastAPI + Postgres) para que la key de DeepSeek no viaje a cada equipo; cada commit se resume una sola vez y los merges no gastan tokens. La pestaña **Resúmenes** busca entre todo lo resumido, en el repo abierto o en todos, y resume los últimos 50 commits de una vez. En Cambios, el botón con chispas del campo Resumen escribe el mensaje del commit a partir de lo marcado (con una pista opcional de qué hiciste).

1. Desplegar `api/` (en Railway: un servicio con la carpeta `api/` y un Postgres) con las variables de [`api/.env.example`](./api/.env.example).
2. En el `settings.json` de MickHub, poner `apiUrl` (la URL de la API) y `apiToken` (el mismo `MICKHUB_API_TOKEN`). Vacíos, el panel no aparece.

## Claude Code por MickHub (opcional)

El comando `mickhub` (en `cli/`) le da a cada sesión de Claude Code su propio grupo de cambios: lo que edita cae solo en su grupo, aunque haya varias sesiones en el mismo repo o incluso en el mismo archivo, y `mickhub commit` commitea solo ese grupo con la cuenta del repo. La app muestra los grupos en vivo.

```sh
cd cli && dart pub get && dart compile exe bin/mickhub.dart -o ~/.local/bin/mickhub
```

Luego, en `~/.claude/settings.json`, un hook `PreToolUse` y otro `PostToolUse` con `"matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit"` y `"command": "mickhub hook"`. Con eso, en los repos de MickHub, `git commit` y `git push` directos quedan bloqueados y Claude usa `mickhub commit` / `mickhub push`. `mickhub --help` lista el resto.

Estado: en desarrollo (v1). Ya reemplaza a GitHub Desktop en lo diario: cambios, commit, historial con búsqueda, conflictos, ramas locales, apartados, candado de cambios locales y cuentas de GitHub y Azure DevOps a la vez. Detalles en [CLAUDE.md](./CLAUDE.md).
