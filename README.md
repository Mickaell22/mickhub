# MickHub

Cliente de git de escritorio a mi medida, para Windows y Linux, con vista de solo lectura en Android.

- Todos mis repos de GitHub y Azure DevOps en una lista, con filtros y clonado en un clic.
- Cambios locales protegidos que nunca se cuelan en un commit.
- Historial con resúmenes por IA de lo que hizo cada commit y cada rama, buscable por hash, autor o texto.
- Temas, temporadas y personajes animados en los espacios vacíos.

## Descargar

Ejecutables portables, sin instalador: se descomprimen y se abren.

- **Linux x64**: [mickhub-linux-x64.tar.gz](https://github.com/Mickaell22/mickhub/releases/latest/download/mickhub-linux-x64.tar.gz) → `tar -xzf mickhub-linux-x64.tar.gz` y abrir `MickHub/mickhub`.
- **Windows x64**: [mickhub-windows-x64.zip](https://github.com/Mickaell22/mickhub/releases/latest/download/mickhub-windows-x64.zip) → descomprimir y abrir `MickHub\mickhub.exe`.

Necesita `git` instalado; en Windows, con el Git Credential Manager (viene con Git for Windows). Cada release trae `SHA256SUMS.txt` para verificar las descargas. MickHub avisa sola cuando hay una versión nueva y se actualiza en el lugar (verifica el SHA256 antes de instalar).

## Atajos

`Ctrl+T` repositorio · `Ctrl+B` rama · `Ctrl+Shift+N` nueva rama · `Ctrl+1`/`Ctrl+2` Cambios/Historial · `Ctrl+Shift+P` fetch/pull/push · `Ctrl+Enter` commit · `Ctrl+Shift+F` abrir carpeta · `Ctrl+Shift+A` abrir en el editor (con el archivo seleccionado) · `F5` refrescar · `Ctrl+/` todos los atajos.

Estado: en desarrollo (v1). Ya reemplaza a GitHub Desktop en lo diario: cambios, commit, historial con búsqueda, conflictos, ramas locales, apartados, candado de cambios locales y cuentas de GitHub y Azure DevOps a la vez. Detalles en [CLAUDE.md](./CLAUDE.md).
