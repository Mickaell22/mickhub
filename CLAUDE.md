# MickHub: contexto para Claude

Cliente de git de escritorio a la medida del dueño, para reemplazar a GitHub Desktop en su uso diario. Repo **público** en `github.com/Mickaell22/mickhub`, licencia MIT. El dueño es mickaell; las reglas generales (sin emojis, commits solo con permiso, nunca trailers de autoría, no hardcodear) viven en su CLAUDE.md global y mandan sobre todo.

Proyecto hermano: **Surco** (`../Surco`), su reproductor de música en Flutter. MickHub hereda de ahí el flujo de trabajo, el estilo de README y la idea de temas y decoraciones, pero mucho más cargada. Antes de reinventar algo de temas, paletas aleatorias, temporadas o `CustomPainter`, mirar cómo lo resolvió Surco (`lib/settings.dart`, `lib/theme.dart`, `lib/ui/decor.dart`) y sus trampas en `../Surco/CLAUDE.md`.

Estado: **esqueleto**. `app/` es un `flutter create --empty` (org `com.mickaell`, plataformas windows, linux y android) y `api/` es un FastAPI con solo `GET /health`. Todavía no hay funcionalidad.

## Por qué existe (el problema real)

GitHub Desktop se le queda corto en:
- No está sincronizado con sus proyectos: clonar implica buscar la URL. Quiere ver la lista completa de sus repos, con filtros, y clonar con un clic.
- **Cambios locales que nunca deben subirse**: en el trabajo mueve o edita archivos para que el proyecto corra en local, y en cada commit tiene que revisarlos a mano para que no se cuelen. Quiere ocultarlos "sí o sí".
- **Historial ilegible**: él usa Conventional Commits, pero sus compañeros escriben cosas como "ajustes" con 5 archivos tocados. Quiere que una IA (DeepSeek, ya tiene API key) lea el diff y escriba qué se hizo de verdad, guardado y buscable.

## Cómo lo usa (define prioridades)

- **Trabajo (Windows)**: repos en **Azure DevOps**. Lo que más hace: traer cambios (pull), commit y push **a su rama personal**. No crea ramas ahí. Usa dos cuentas a la vez: la del trabajo (repos de la empresa) y la personal (apuntes, mcp-context, etc.).
- **Casa (Kali Linux)**: solo la cuenta personal, repos en GitHub.
- **Celular (Android)**: solo para mirar (historial, resúmenes). Sin operaciones de git.
- Tiene varios dispositivos, por eso los datos van en la nube y no en una base local.

## Decisiones tomadas

- **App en Flutter** (desktop Windows + Linux, Android solo lectura). Lo eligió el dueño para no complicarse; ya lo maneja por Surco. Descartados: Electron (pesado), Tauri y Compose Multiplatform (aprender todo de nuevo).
- **Git se ejecuta llamando al `git` instalado**, no reimplementado (ni libgit2). Así usa el Git Credential Manager del sistema, que ya resuelve Azure DevOps y las dos cuentas sin que MickHub guarde contraseñas.
- **Backend mínimo en Railway**: API + Postgres. La app habla con la API, nunca directo con la base. Motivo: no repartir credenciales de la base ni la key de DeepSeek en cada dispositivo (y el celu). La key de DeepSeek vive solo en el servidor.
- API en **FastAPI** (Python), como mcp-context. Confirmado por el dueño.
- **Un solo repo** con carpetas divididas: `app/` (Flutter) y `api/` (FastAPI). Confirmado: antes hacía dos repos (front y back) y ya no quiere eso.
- Resúmenes con IA **solo para el dueño**, no para el equipo. No hace falta multiusuario ni permisos finos: una sola cuenta.
- El dueño confirmó que **sí puede mandar código del trabajo a la IA** ("son pro IA"). Igual dejar la IA configurable por repo.

## Alcance

### v1: reemplazar GitHub Desktop en lo diario
- Cuentas: GitHub (personal) y Azure DevOps (trabajo) a la vez.
- Lista de todos los repos de ambas cuentas, con filtros (cuenta, organización, clonado o no, búsqueda) y **clonar con un clic**.
- Ver cambios, stage, commit, pull y push a la rama actual.
- **Candado de cambios locales**: marcar un archivo como "cambio local protegido" y que nunca aparezca para commit. Por debajo, `git update-index --skip-worktree <archivo>` (archivos versionados) y `.git/info/exclude` (no versionados). Mostrar siempre una sección visible con lo protegido, para que no se olvide. Ojo: `skip-worktree` puede chocar en un `pull` si el remoto cambia ese archivo; manejar ese caso con un aviso claro, no fallar en silencio.
- Historial con búsqueda por hash, autor y texto.

### v2: la IA
- Resumen por commit con DeepSeek leyendo el diff, guardado en Postgres por **hash del commit**.
- **Deduplicar**: el mismo commit llega por varios caminos (su rama, merges desde la general). Como se identifica por hash, se resume una sola vez. Los **commits de merge** (dos o más padres) no van a la IA: se etiquetan "merge de X en Y" sin gastar tokens.
- Resumir bajo demanda o en segundo plano, pero nunca dos veces el mismo hash. Diffs muy grandes: recortar o resumir por archivo, para no quemar tokens.
- Descripción de ramas: qué trae una rama respecto de la base.
- Tabla buscable: hash, autor, fecha, mensaje original, resumen IA; filtros por usuario, repo, rama, fecha.

### Después (sin diseño todavía)
- Crear y cambiar ramas, resolver conflictos (en el trabajo no los usa; para lo personal sí puede servir).
- Vista de celular.

## Personalización (prioridad alta, explícita del dueño)

Quiere una personalización "ridículamente grande", **mucho más que Surco**. Lo que importa **no** es cambiar fuentes o colores a mano, sino **vida visual en los espacios vacíos**: decoraciones y personajes, como la decoración de Halloween de Surco (araña, telaraña, murciélagos) o como la mascota de Claude Code en la terminal. Que no se sienta "todo código".

- Paletas de colores aleatorias (como Surco: fija, cada día, al abrir).
- Temporadas y eventos **activados por defecto** (Halloween, Navidad, etc., como Surco).
- **Temas temáticos** con decoración propia: estilo pixel art retro, arcade de pelea, aventura de 16 bits, etc.
- **Personajes animados chiquitos**: por ejemplo, un gatito caminando por la parte inferior de la ventana. Mini animaciones, no fondos pesados.
- Fondos tipo wallpaper **generados dentro de la app** (dibujados), no imágenes descargadas.

Reglas para esto:
- **Nada de personajes o sprites de terceros** (Mario, Link, Mortal Kombat...). El repo es público y Nintendo y compañía tumban repos. El dueño los nombró solo como referencia de estilo: hacer **pixel art y personajes originales** inspirados en esos estilos.
- **Optimizado siempre**: dibujado con `CustomPainter` (o Flame solo si hiciera falta de verdad, justificarlo), animaciones lentas y baratas, pausadas cuando la ventana no está visible o minimizada, quietas si el sistema reduce animaciones, `IgnorePointer` para no robar clics, y nada animado detrás de listas largas.
- Nunca tapar contenido útil: diffs, listas de archivos, botones.

## Flujo de trabajo (heredado de Surco)

- **Conventional Commits** (`feat(repos):`, `fix(historial):`, `chore(release):`, `docs:`...). El dueño los usa.
- Commits chicos, uno por cambio lógico; cada commit compila y pasa tests.
- Antes de cada commit: `flutter analyze` sin issues y `flutter test` en verde. Verificar que el mensaje no tenga `Co-Authored-By` ni similares.
- Textos de la UI **en español con tildes y eñes**.
- Flutter está en `/opt/flutter/bin` y se corre como `mickaell` (Claude Code corre como root): `sudo -u mickaell -H bash -c 'export PATH=/opt/flutter/bin:$PATH; cd ...; flutter ...'`. Después de editar como root, `chown -R mickaell:mickaell .`.
- `gh` está logueado como `mickaell`; correrlo con `unset GH_TOKEN` (el GH_TOKEN de root es inválido).
- Todo valor configurable (URL de la API, tokens, DATABASE_URL, DEEPSEEK_API_KEY) va en variables de entorno con su `.env.example`; nunca en el código, ni como default. Repo público: nada de datos personales ni de la empresa en el código.

## Preguntas abiertas

- Cómo se autentica la app contra la API (una sola cuenta: token personal largo en variable de entorno o en el almacenamiento seguro del sistema).
- Cómo lista los repos de Azure DevOps (API REST con un PAT) y cómo guarda los tokens de GitHub y Azure en cada dispositivo (almacenamiento seguro del sistema, nunca texto plano).
- Primer set de temas temáticos y personajes a dibujar.
