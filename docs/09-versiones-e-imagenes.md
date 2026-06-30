# 09 — Versiones e imágenes (infraestructura multi-versión)

> **Estado:** plan de diseño aprobado. Documento vivo: se actualiza a medida
> que se implementa en la rama `feature/multi-version-infra`.

Este documento describe cómo el orquestador deja de estar orientado a **Odoo 14**
y pasa a soportar **cualquier versión de Odoo** mediante un **archivo de
configuración de infraestructura de imágenes**, manteniendo el flujo de trabajo
actual (`projects-registry.conf` → `sync-projects.sh` → `--apply`).

---

## 1. Objetivo

Hoy la mecánica ya es *version-aware* (la versión es un campo del registry y se
interpola como `{VERSION}` en rutas, nombres y la imagen `odoo:${VERSION}.0`),
pero quedan tres acoplamientos que impiden tratar la versión como un parámetro
de primera clase:

1. **La imagen siempre es `odoo:${VERSION}.0` de Docker Hub** — no se puede
   buildear, usar un registry privado ni pinear un digest.
2. **PostgreSQL está clavado en `postgres:13-alpine`** y sus parámetros son fijos.
3. **La lógica por versión está dispersa y duplicada** (el branch `VERSION >= 16`
   vive en dos scripts; los *quirks* de Odoo 14 están hardcodeados en el
   entrypoint).

La solución introduce una **capa de perfiles por versión**, **build obligatorio
parametrizado** y un **resolver único compartido** por todos los scripts.

### Decisiones de diseño tomadas

| Decisión | Elección |
|---|---|
| Alcance del config de imágenes | **Build obligatorio siempre** (toda instancia se construye desde un Dockerfile parametrizado por versión). |
| PostgreSQL | **Un único Postgres compartido, configurable** (imagen/versión y parámetros pasan a `config/infra.conf`/`.env`). |
| Dónde implementar | **Rama `feature/multi-version-infra`** sobre este repo → PR. |
| `requirements.txt` de los addons | **Opción A — instalación en runtime** (se mantiene el comportamiento actual; el build solo agrega base + deps de sistema y hornea el entrypoint). |

---

## 2. Diagnóstico — acoplamientos a Odoo 14

Inventario consolidado (rutas:línea) de lo que hay que generalizar.

### 2.1 Branding y ejemplos (cosmético)
- `README.md:1,3,6-7,20,50,93` — título/descr. "Orquestación Odoo 14".
- `docker-compose.yml:2,6,14-15` — header y rango de puertos `14010–14099`.
- `scripts/ops.sh:1020` — "Gestión de entorno Odoo 14".
- `docs/despliegue-merida.md`, `docs/01-instalacion.md:65`, `docs/08-checklist-produccion.md:16`.

### 2.2 Imagen Docker (núcleo del pedido)
- `scripts/sync-projects.sh:323` — `image: odoo:${VERSION}.0`.
- `scripts/new-project.sh:147` — `image: odoo:${VERSION}.0`.
- `docker-compose.yml:114` — plantilla comentada `image: odoo:{VERSION}.0`.
- **No soporta:** build local, registry privado, override de imagen por proyecto.

### 2.3 PostgreSQL
- `docker-compose.yml:21-23` — comentario "PostgreSQL 13 para rama Odoo 14".
- `docker-compose.yml:27` — `image: postgres:13-alpine` (no version-aware).
- `docker-compose.yml:34-46` — parámetros fijos (`shared_buffers`, etc.).
- `postgres/init/01-extensions.sql` — extensiones globales (OK, se conservan).

### 2.4 Lógica version-aware (ya existe, pero duplicada / implícita)
- `scripts/sync-projects.sh:250-256` y `scripts/new-project.sh:79-85` —
  `(( VERSION >= 16 ))` → `gevent_port` + `websocket_*` vs `longpolling_port`.
  **Misma lógica en dos lugares** (riesgo de divergencia).
- `scripts/odoo-entrypoint.sh:10-48` — sanitización de addons-path (quirk Odoo 14).
- `scripts/odoo-entrypoint.sh:100-125` — inyección de `admin_passwd` + stripping de
  `--admin-passwd` (quirk Odoo 14, no acepta el flag por CLI).
- `scripts/odoo-entrypoint.sh:54-66` — detección `pip3`/`pip` y `--break-system-packages`
  (esto es runtime-detection robusta; se conserva).

---

## 3. Arquitectura propuesta

### 3.1 Archivo de configuración de imágenes

```
config/
├── infra.conf              # global (no-secreto): Postgres, registry, subnet, tag-prefix
└── versions/
    ├── 14.conf             # perfil Odoo 14
    ├── 16.conf
    ├── 17.conf
    ├── 18.conf
    └── 19.conf
```

**`config/infra.conf`** — knobs que consumen los SCRIPTS (sourceable en bash):

```sh
# Imágenes Odoo buildeadas: registry destino (vacío = solo local) y prefijo de tag.
IMAGE_REGISTRY=
IMAGE_TAG_PREFIX=extendrix
```

> **Importante (separación de responsabilidades):** Docker Compose solo interpola
> variables desde `.env` / el entorno, **no** desde `config/infra.conf`. Por eso
> lo que consume `docker-compose.yml` (imagen y tuning de Postgres, subnet de la
> red) vive en `.env` con defaults seguros en el compose (`${VAR:-default}`), y
> `config/infra.conf` queda solo para lo que usan los scripts al generar los
> servicios. Knobs en `.env` (todos opcionales): `POSTGRES_IMAGE`,
> `PG_MAX_CONNECTIONS`, `PG_SHARED_BUFFERS`, `PG_EFFECTIVE_CACHE_SIZE`,
> `PG_MAINTENANCE_WORK_MEM`, `PG_WORK_MEM`, `PG_MIN_WAL_SIZE`, `PG_MAX_WAL_SIZE`,
> `DOCKER_NETWORK_SUBNET`.

**`config/versions/<V>.conf`** — perfil por versión (la "infra de imágenes"):

```sh
# Imagen base del build (FROM). Puede ser oficial, privada o un digest.
ODOO_BASE_IMAGE=odoo:18.0
# Dockerfile a usar para esta versión (permite uno específico si hiciera falta).
DOCKERFILE=build/Dockerfile

# Estilo de puerto de tiempo real y websockets.
PORT_STYLE=gevent          # gevent | longpolling
HAS_WEBSOCKETS=true

# Quirks (reemplazan los chequeos "es 14" del entrypoint).
SUPPORTS_ADMIN_PASSWD_CLI=true   # 14=false → el wrapper inyecta admin_passwd
NEEDS_ADDONS_SANITIZE=false      # 14=true → filtra dirs vacíos del addons-path

# Compatibilidad informativa / validación.
PG_RECOMMENDED=16
```

> **Soportar una versión nueva = agregar un archivo en `config/versions/`.** Si no
> existe el perfil, el resolver deriva valores por defecto a partir del número de
> versión (igual que hoy con `VERSION >= 16`), de modo que nada se rompe.

### 3.2 Build obligatorio parametrizado

```
build/
├── Dockerfile              # genérico, parametrizado por ARG
└── 14/Dockerfile           # (opcional) override solo si una versión lo requiere
```

`build/Dockerfile` (Opción A — **sin** instalar requirements de addons en build):

```dockerfile
ARG ODOO_BASE_IMAGE=odoo:18.0
FROM ${ODOO_BASE_IMAGE}
ARG ODOO_VERSION
# Deps de sistema comunes, locales, etc. (NO los requirements de los addons).
# Hornear el wrapper de arranque en la imagen (en vez de bind-mount).
COPY scripts/odoo-entrypoint.sh /odoo-entrypoint.sh
ENTRYPOINT ["/bin/sh", "/odoo-entrypoint.sh"]
```

- En `docker-compose.yml` el servicio pasa de `image:` a **`build:` con `args`**
  (`ODOO_BASE_IMAGE`, `ODOO_VERSION`) **más un `image:` tag**
  (`${IMAGE_TAG_PREFIX}/odoo:${V}`) para **cachear y reutilizar** el build entre
  instancias de la misma versión.
- Los `requirements.txt` de los addons (shared/extra/enterprise) se siguen
  instalando **en el arranque** desde los volúmenes montados (Opción A), tal como
  hace hoy `odoo-entrypoint.sh`.

### 3.3 Resolver único de perfiles

```
scripts/lib/version-profile.sh
```

Expone `load_version_profile <V>` que: carga `config/infra.conf` +
`config/versions/<V>.conf`, aplica defaults derivados de la versión si falta el
archivo, y exporta las variables (`ODOO_BASE_IMAGE`, `PORT_STYLE`,
`SUPPORTS_ADMIN_PASSWD_CLI`, etc.).

Lo consumen **`sync-projects.sh`, `new-project.sh`, `sync-overrides.sh` y
`odoo-entrypoint.sh`** → se elimina la duplicación del branch `VERSION >= 16` y los
quirks dejan de ser "es 14" para ser flags del perfil.

### 3.4 Entrypoint guiado por flags

| Antes (implícito "es 14") | Después (flag del perfil) |
|---|---|
| Siempre intenta inyectar `admin_passwd` y stripear `--admin-passwd` | Solo si `SUPPORTS_ADMIN_PASSWD_CLI=false` |
| Siempre sanea addons-path | Solo si `NEEDS_ADDONS_SANITIZE=true` |
| Detección `pip3`/`pip` y `--break-system-packages` | Se conserva (runtime-detection robusta) |

El entrypoint horneado lee el perfil (montado o vía env var inyectada por el
servicio) para decidir.

### 3.5 PostgreSQL compartido configurable

`docker-compose.yml` toma `POSTGRES_IMAGE` y los parámetros de tuning desde
`.env` (con defaults seguros vía `${VAR:-default}`). Se mantiene **un solo**
servicio `db` para todo el servidor (válido para Odoo 14–19 con PG 13; subible
si se requiere). La subnet de la red interna también es configurable
(`DOCKER_NETWORK_SUBNET`).

---

## 4. Plan de ejecución

Rama: **`feature/multi-version-infra`**.

| Fase | Contenido | Estado |
|---|---|---|
| **0** | Inventario exhaustivo de acoplamientos a "14"/imagen. | ✅ Hecho (sección 2) |
| **1** | Crear `config/infra.conf`, `config/versions/*.conf` y `scripts/lib/version-profile.sh`. Defaults = comportamiento actual (sin cambio de conducta). | ✅ Hecho |
| **2** | Crear `build/Dockerfile`; migrar generación de servicios a `build:` + tag cacheable; hornear el entrypoint. | ✅ Hecho |
| **3** | Refactor: `sync-projects.sh`, `new-project.sh`, `sync-overrides.sh`, `odoo-entrypoint.sh` consumen el resolver; quitar `VERSION >= 16` duplicado y quirks hardcodeados. | ✅ Hecho |
| **4** | PostgreSQL configurable desde `.env` (Compose solo interpola desde `.env`/entorno; `infra.conf` queda para los scripts). | ✅ Hecho |
| **5** | Docs + branding neutro + ejemplo multi-versión (se conserva `merida/14`). | ✅ Hecho |
| **6** | Validación: dry-run de `sync-projects.sh` con 14 + otra versión, `nginx -t`, build de imágenes, levantar instancia de prueba. | ⬜ |

### Criterios de aceptación
- Agregar una línea `proyecto:18:prod:...:18010` al registry y correr
  `sync-projects.sh --apply` despliega una instancia Odoo 18 sin tocar código.
- Cambiar `POSTGRES_IMAGE` en `.env` cambia la imagen de Postgres.
- Definir `ODOO_BASE_IMAGE=miregistry/odoo:18-custom` en `config/versions/18.conf`
  hace que el build parta de esa imagen.
- El proyecto `merida` (Odoo 14) sigue funcionando idéntico (no-regresión).

---

## 5. Cómo operar (multi-versión)

### Agregar una versión de Odoo nueva
1. Crear el perfil `config/versions/<V>.conf` (copiar uno existente y ajustar
   `ODOO_BASE_IMAGE` y los flags). Si no se crea, el resolver deriva defaults por
   número de versión.
2. Crear las carpetas de addons por versión que correspondan:
   `shared-addons/<V>/` y `enterprise/odoo<V>/`.
3. Inspeccionar el perfil resuelto: `./scripts/lib/version-profile.sh <V>`.
4. Registrar el proyecto en `projects-registry.conf`
   (`proyecto:<V>:entorno:dominio:puerto`) y aplicar:
   `./scripts/sync-projects.sh --apply --start`.

### Usar una imagen privada o un digest para una versión
Editar `config/versions/<V>.conf`:
```sh
ODOO_BASE_IMAGE=miregistry.com/odoo:18-custom   # o odoo@sha256:...
```
El build de esa versión partirá de esa imagen como `FROM`.

### Cambiar PostgreSQL o el tuning
Editar `.env` (Compose lo lee de ahí, no de `config/infra.conf`):
```sh
POSTGRES_IMAGE=postgres:16-alpine
PG_SHARED_BUFFERS=1GB
```
Luego: `docker compose up -d db` (recreación del cluster; ojo con la
compatibilidad de versión mayor de PG — requiere dump/restore al subir mayor).

### Rebuild de imágenes
```sh
docker compose build <contenedor>      # build de una instancia
docker compose build                   # build de todas
```
Las instancias de la misma versión comparten el tag `extendrix/odoo:<V>`.

### Migrar un proyecto YA desplegado al esquema de build
Los servicios creados antes de esta capa siguen con `image: odoo:<V>.0` y su
bloque viejo; no se tocan automáticamente. Para migrarlos: regenerar el bloque
(o editarlo a mano para usar `build:` + `image:` como en la PLANTILLA de
`docker-compose.yml`) y `docker compose up -d --build <contenedor>`.

---

## 6. Compatibilidad y migración

- **Sin proyectos por defecto** se mantiene; el ejemplo sigue siendo `merida/14`.
- Los proyectos ya desplegados **no se recrean** salvo que se aplique build/override.
- Si no se crean los `config/versions/*.conf`, el resolver usa defaults derivados
  de la versión → el repo sigue funcionando "como antes" hasta migrar.
- La numeración de puertos `{ver}010–{ver}099` se documenta por versión (válida para
  14/16/17/18/19).

---

## 7. Fuera de alcance (posibles fases futuras)

- PostgreSQL **por versión** de Odoo (un servicio `db` por versión).
- Instalación de `requirements.txt` de addons **en build** (Opción B).
- Override de imagen **por proyecto** (no solo por versión).
- Publicación/push automático de las imágenes buildeadas a un registry.
