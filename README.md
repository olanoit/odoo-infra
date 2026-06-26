# EXTENDRIX — Orquestación Odoo 14

Orquestador de Odoo **14** sobre Docker: PostgreSQL + Nginx + Certbot, con un
contenedor Odoo por proyecto y entorno. La mecánica es **version-aware**, por lo
que también funciona con otras versiones compatibles de Odoo (la convención de
puertos y rutas usa `{VERSION}`), pero este repo está orientado y validado para
**Odoo 14**; todos los ejemplos lo usan.

**Sin proyectos por defecto.** El repo viene limpio: vos decidís qué desplegar.
Agregá tus proyectos en `projects-registry.conf` y ejecutá
`./scripts/sync-projects.sh --apply`. Los ejemplos de esta documentación usan
`merida` (Odoo 14) **solo como ilustración** — ver
[docs/despliegue-merida.md](docs/despliegue-merida.md).

| Convención    | Formato                              | Ejemplo                         |
|---------------|--------------------------------------|---------------------------------|
| Contenedor    | `odoo{VERSION}_{PROYECTO}_{ENTORNO}` | `odoo14_merida_prod`            |
| Base de datos | `{proyecto}_{entorno}_*`             | `merida_prod_principal`         |
| Subdominio    | `{proyecto}[-{entorno}].<dominio>`   | `merida.odoo-rideco.mx`         |
| Puertos host  | `{ver}010..{ver}099` (HTTP) + 1 LP   | `14010/14011`                   |

---

## Contenedores activos

**Ninguno por defecto.** El repo no trae proyectos preconfigurados. A medida que
registres y despliegues proyectos, sus contenedores aparecerán aquí.

Para agregar tu primer proyecto, ver
[02-agregar-proyecto-dominio.md](docs/02-agregar-proyecto-dominio.md).

---

## Estructura del proyecto

```
odoo-multi-version/
├── README.md                       ← este archivo
├── docker-compose.yml              ← define todos los servicios (Odoo, postgres, nginx, certbot)
├── docker-compose.override.yml     ← (gitignored) customización por servidor
├── .env.example                    ← plantilla de variables sensibles (copiar a .env)
├── projects-registry.conf          ← inventario de proyectos del servidor
│
├── projects/                       ← UN directorio por proyecto Odoo
│   └── {proyecto}/odoo{VER}/sta/
│       ├── config/odoo.conf        ← configuración de Odoo (workers, dbfilter, etc.)
│       └── addons/                 ← módulos EXCLUSIVOS del proyecto
│
├── shared-addons/                  ← módulos compartidos entre proyectos, por versión
│   └── 14/                         ← addons para todos los Odoo 14
│
├── enterprise/                     ← addons Odoo Enterprise, separados por versión
│   └── odoo14/
│
├── backups/                        ← (gitignored) backups DB + filestore de todos los proyectos
│   └── {proyecto}/
│       ├── db/                     ← dumps PostgreSQL (.sql.gz)
│       └── filestore/              ← filestore Odoo (.tar.gz)
│
├── nginx/                          ← configuración del reverse-proxy y SSL
│   ├── nginx.conf                  ← config global de nginx
│   ├── conf.d/
│   │   ├── 00-upstreams.conf       ← lista de backends Odoo (host:puerto)
│   │   ├── odoo-proxy-params.conf  ← headers comunes (X-Forwarded-For, etc.)
│   │   └── vhosts-projects.conf    ← server blocks (uno por dominio)
│   └── certbot/                    ← (gitignored) certs Let's Encrypt + webroot
│
├── postgres/init/                  ← scripts SQL ejecutados al crear el cluster por primera vez
│   └── 01-extensions.sql           ← habilita pg_trgm, unaccent, etc.
│
├── scripts/                        ← herramientas de operación
│   ├── ops.sh                      ← comando "navaja suiza" del día a día
│   ├── new-project.sh              ← crea la estructura de un proyecto nuevo
│   ├── sync-projects.sh            ← aplica projects-registry.conf al servidor
│   ├── sync-overrides.sh           ← regenera docker-compose.override.yml
│   ├── delete-project.sh           ← borra un proyecto entero (con confirmación)
│   ├── setup-ssl.sh                ← emite SSL inicial vía Certbot
│   ├── wildcard-ssl.sh             ← reutiliza un cert wildcard para un subdominio
│   ├── nginx-dedupe.sh             ← limpia bloques duplicados en confs de nginx
│   ├── backup-cron.sh             ← backup-all + retención, para cron
│   ├── clean-logs.sh              ← vacía los logs Docker de uno o todos los proyectos
│   └── odoo-entrypoint.sh          ← instala requirements.txt de los módulos al startup
│
└── docs/                           ← guías paso a paso
    ├── 01-instalacion.md
    ├── 02-agregar-proyecto-dominio.md
    ├── 03-addons-personalizados.md
    ├── 04-actualizar-modulo.md
    ├── 05-backups.md
    ├── 06-operaciones-cheatsheet.md
    ├── 07-configuracion-por-servidor.md
    ├── 08-checklist-produccion.md
    └── despliegue-merida.md         ← despliegue de merida (Odoo 14 + SSL wildcard)
```

---

## ¿Qué hace cada archivo? (explicación detallada)

### Configuración base

| Archivo                          | Para qué sirve                                                                                                                       |
|----------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| `docker-compose.yml`             | Receta de Docker: declara los contenedores (postgres compartido, nginx, certbot y un Odoo por proyecto), sus volúmenes y red. Es la "fuente de verdad" del servidor. **Se commitea al repo.** |
| `docker-compose.override.yml`    | Customización **por servidor** (workers, memoria, addons-path específicos). Docker lo merge encima del `docker-compose.yml`. **NO se commitea** — cada servidor tiene el suyo. Lo genera `sync-overrides.sh`. |
| `.env.example`                   | Plantilla de variables sensibles (POSTGRES_PASSWORD, **ODOO_MASTER_PASSWD**, CERTBOT_EMAIL, DOMAIN_*). Copialo a `.env` y editalo con los valores reales del servidor. |
| `.env`                           | (gitignored) valores reales. Lo lee `docker-compose.yml` y todos los scripts.                                                        |
| `projects-registry.conf`         | Lista plana de proyectos del servidor (uno por línea: `proyecto:version:entorno:dominio:puerto`). Es lo que lee `sync-projects.sh` para saber qué desplegar. |
| `.gitignore`                     | Marca qué archivos/dirs no se commitean (backups, override.yml, certs SSL, addons reales, etc.).                                     |

### Proyectos y módulos

| Path                                    | Para qué sirve                                                                                                          |
|-----------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `projects/<proyecto>/odoo<VER>/sta/`    | Carpeta-raíz de un proyecto staging. Contiene su odoo.conf y sus addons exclusivos.                                       |
| `projects/.../config/odoo.conf`         | Configuración de Odoo para ESE proyecto: dbfilter, workers, datos de conexión a postgres, etc. Generado por `new-project.sh`. |
| `projects/.../addons/`                  | Módulos que **solo usa este proyecto** (extra-addons). Se montan en `/mnt/extra-addons` dentro del contenedor.            |
| `shared-addons/<VERSION>/`              | Módulos que pueden usar **varios proyectos** de la MISMA versión de Odoo (ej: localización contable, MercadoLibre, biometría). Cada contenedor monta solo su versión. |
| `enterprise/odoo<VERSION>/`             | Addons de **Odoo Enterprise** (de pago, requieren licencia). Separados por versión.                                       |

### Backups

| Path                                       | Para qué sirve                                                                                |
|--------------------------------------------|------------------------------------------------------------------------------------------------|
| `backups/<proyecto>/db/`                   | Dumps de PostgreSQL en formato `.sql.gz` (gzipped). Generados por `ops.sh backup`.            |
| `backups/<proyecto>/filestore/`            | Archivos adjuntos de Odoo en `.tar.gz` (un tar por dump, con timestamp en el nombre).         |
| `backups/` (raíz)                          | Es bind-mount: el contenedor postgres y cada contenedor Odoo lo ven como `/backups`. Por eso `pg_dump` puede escribir directo ahí. |

### Servidor web (nginx + SSL)

| Archivo                                  | Para qué sirve                                                                                            |
|------------------------------------------|------------------------------------------------------------------------------------------------------------|
| `nginx/nginx.conf`                       | Config global de nginx (workers, log format, gzip, timeouts, etc.). Casi nunca se toca.                   |
| `nginx/conf.d/00-upstreams.conf`         | Define **a quién** enrutar cada dominio: `upstream up_<proyecto>_http { server odoo<VER>_<proyecto>_sta:8069; }`. El `00-` lo hace cargar primero. |
| `nginx/conf.d/odoo-proxy-params.conf`    | Headers reusables (X-Real-IP, X-Forwarded-For, X-Forwarded-Proto, etc.) que cada vhost incluye con `include`. |
| `nginx/conf.d/vhosts-projects.conf`      | Un bloque `server { ... }` por dominio: redirige 80→443, sirve SSL, hace proxy al upstream correspondiente. |
| `nginx/certbot/`                         | Subcarpetas `conf/` (certs emitidos) y `www/` (webroot para validación HTTP-01). Las edita Certbot, no vos. |

### Base de datos

| Archivo                            | Para qué sirve                                                                                |
|------------------------------------|------------------------------------------------------------------------------------------------|
| `postgres/init/01-extensions.sql`  | SQL que se ejecuta **una sola vez** cuando se crea el cluster PostgreSQL. Habilita extensiones que Odoo necesita (pg_trgm, unaccent). Si el volumen `postgres_data` ya existe, no se re-ejecuta. |

### Scripts de operación

| Script                       | Para qué sirve                                                                                                                                         |
|------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| `scripts/ops.sh`             | Comando "navaja suiza" del día a día: `start`, `stop`, `restart`, `logs`, `health`, `module`, `backup`, `restore`, `restore-external`, `neutralize`, `list-backups`, `db-query`, `nginx-reload`, `ssl-renew`. Ver `./scripts/ops.sh help`. |
| `scripts/new-project.sh`     | Crea la estructura inicial de un proyecto (carpetas + odoo.conf base). Se usa solo o como helper de `sync-projects.sh`.                                  |
| `scripts/sync-projects.sh`   | Lee `projects-registry.conf` y aplica todo lo que falta: inserta servicios en docker-compose, upstreams y vhosts en nginx, emite SSL. Idempotente.       |
| `scripts/sync-overrides.sh`  | Genera o regenera el `docker-compose.override.yml` con los bloques por defecto (entrypoint wrapper, addons-path con `tools`, workers, memoria).         |
| `scripts/delete-project.sh`  | Elimina un proyecto ENTERO (container, volumen, DB, backups, certs, bloques en conf). Pide confirmación tipeando `BORRAR <proyecto>_<entorno>`.          |
| `scripts/setup-ssl.sh`       | Emisión inicial de certificados SSL vía Certbot (legado — `sync-projects.sh --ssl` lo reemplaza en flujos nuevos).                                       |
| `scripts/wildcard-ssl.sh`    | Reutiliza un cert **wildcard** (`*.dominio`) para un subdominio en vez de emitir uno individual: symlink al wildcard local (renovación automática) o copia desde un origen externo. `sync-projects.sh --ssl` lo usa automáticamente cuando hay un wildcard que cubre el dominio. |
| `scripts/nginx-dedupe.sh`    | Limpia bloques duplicados en `00-upstreams.conf` y `vhosts-projects.conf` (típico tras varias corridas de `sync-projects.sh` en escenarios de reset).    |
| `scripts/odoo-entrypoint.sh` | Wrapper de arranque del container Odoo: instala `requirements.txt` de módulos en `shared-addons/` antes de pasarle el control al entrypoint oficial.    |
| `scripts/backup-cron.sh`     | Backup automático no interactivo (`backup-all`) + retención configurable (`RETENTION_DAYS`). Pensado para `cron`. Ver [docs/05-backups.md](docs/05-backups.md).    |
| `scripts/clean-logs.sh`      | Vacía los logs Docker de un proyecto (`<contenedor>`) o de todos (`--all`). Trunca sin reiniciar el contenedor. Soporta `--infra`, `--dry-run`, `--yes`.            |

### Documentación

| Archivo                                  | Contenido                                                          |
|------------------------------------------|---------------------------------------------------------------------|
| `docs/01-instalacion.md`                 | Setup desde Ubuntu limpio (instalar Docker, primer arranque).      |
| `docs/02-agregar-proyecto-dominio.md`    | Cómo agregar un proyecto staging paso a paso (incluye `.env`, registry, DNS, SSL). |
| `docs/03-addons-personalizados.md`       | Cómo manejar addons (extra, shared, enterprise) y la separación por versión. |
| `docs/04-actualizar-modulo.md`           | Cómo hacer `update`/`install` de un módulo desde terminal.         |
| `docs/05-backups.md`                     | Backup, restauración local, restauración de backups de OTROS servidores, política de retención. |
| `docs/06-operaciones-cheatsheet.md`      | Comandos del día a día agrupados por tarea.                        |
| `docs/07-configuracion-por-servidor.md`  | Cómo personalizar workers, memoria y addons-path por servidor con el override. |
| `docs/08-checklist-produccion.md`        | Checklist para salir a producción: qué está cubierto, qué verificar y limitaciones conocidas. |

---

## Inicio rápido

```bash
# 1. Requisitos (Ubuntu 22.04/24.04)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker

# 2. Configurar variables (POSTGRES_PASSWORD y ODOO_MASTER_PASSWD son obligatorias)
cp .env.example .env && nano .env
chmod +x scripts/*.sh

# 3. Registrar tu primer proyecto (formato proyecto:version:entorno:dominio:puerto)
nano projects-registry.conf
#   ej: merida:14:prod:merida.odoo-rideco.mx:14010

# 4. Aplicar: genera el servicio, nginx y odoo.conf, y levanta el contenedor
./scripts/sync-projects.sh --apply --start

# 5. SSL: si hay un wildcard que cubre el dominio, sync lo reutiliza solo;
#    si no, emite cert individual (cuando el DNS ya apunte a este servidor)
./scripts/sync-projects.sh --ssl

# 6. Estado
./scripts/ops.sh health
```

---

## Comandos más usados

```bash
./scripts/ops.sh health
./scripts/ops.sh logs odoo14_merida_prod 200
./scripts/ops.sh restart odoo14_merida_prod

# Actualizar un módulo
./scripts/ops.sh module odoo14_merida_prod merida_prod_principal mi_modulo update

# Backup (DB + filestore → ./backups/merida/)
./scripts/ops.sh backup merida odoo14_merida_prod merida_prod_principal

# Listar backups disponibles
./scripts/ops.sh list-backups merida

# Restaurar (auto-detecta filestore por timestamp)
./scripts/ops.sh restore odoo14_merida_prod merida_prod_copia \
  merida/db/20260511_020000_merida_prod_principal.sql.gz

# Restaurar un backup que viene de otro servidor (.tar.gz / .zip / .sql.gz)
./scripts/ops.sh restore-external odoo14_merida_prod merida_prod_principal \
  /opt/backups_odoo/conexion_prod_FULL_2026-05-12.tar.gz

# Neutralizar una DB recién importada de producción (apaga cron, mail, pagos…)
./scripts/ops.sh neutralize odoo14_merida_prod merida_prod_principal

# Nuevo proyecto (ej: staging de merida)
./scripts/new-project.sh merida 14 sta 14020

# Sincronizar overrides (agrega bloque por defecto a proyectos que no lo tienen)
./scripts/sync-overrides.sh                  # dry-run
./scripts/sync-overrides.sh --apply          # aplicar a todos los faltantes

# Eliminar un proyecto (pide confirmación, IRREVERSIBLE)
./scripts/delete-project.sh merida sta --dry-run    # previsualizar
./scripts/delete-project.sh merida sta              # aplicar
```

---

## Guías

| Guía | Descripción |
|---|---|
| [01 - Instalación](docs/01-instalacion.md) | Setup desde Ubuntu limpio |
| [02 - Nuevo proyecto/dominio](docs/02-agregar-proyecto-dominio.md) | Agregar proyecto de staging paso a paso |
| [03 - Addons personalizados](docs/03-addons-personalizados.md) | Gestión de módulos |
| [04 - Actualizar módulos](docs/04-actualizar-modulo.md) | Update/install por terminal |
| [05 - Backups](docs/05-backups.md) | Backup y restore (DB + filestore) en volumen central |
| [06 - Operaciones](docs/06-operaciones-cheatsheet.md) | Cheatsheet de comandos |
| [07 - Configuración por servidor](docs/07-configuracion-por-servidor.md) | Override de recursos por servidor |
| [08 - Checklist de producción](docs/08-checklist-produccion.md) | Verificaciones y limitaciones antes de salir a producción |
| [Despliegue de merida](docs/despliegue-merida.md) | Caso real: Odoo 14 + reutilización de SSL wildcard de producción |
