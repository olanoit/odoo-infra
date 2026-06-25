# OLANOIT — Odoo Multi-Version Orchestration (Staging)

**Esta versión del orquestador está dedicada exclusivamente a entornos de _staging_.**
Todos los contenedores, bases de datos y dominios usan el sufijo `_sta`. No se
despliegan instancias `dev` ni `prod` desde este repo.

| Convención    | Formato                            | Ejemplo                          |
|---------------|------------------------------------|----------------------------------|
| Contenedor    | `odoo{VERSION}_{PROYECTO}_sta`     | `odoo19_farmaniacos_sta`          |
| Base de datos | `{proyecto}_sta_*`                 | `farmaniacos_sta_principal`       |
| Subdominio    | `{proyecto}-sta.<dominio>`         | `farmaniacos-sta.OLANOIT.work`  |
| Puertos host  | `{ver}010..{ver}099` (HTTP) + 1 LP | `19020/19021`                    |

---

## Contenedores activos

| Contenedor              | Versión | Proyecto    | Subdominio                       | HTTP  | LP    |
|-------------------------|---------|-------------|----------------------------------|-------|-------|
| `odoo19_farmaniacos_sta` | 19      | farmaniacos  | farmaniacos-sta.OLANOIT.work    | 19020 | 19021 |

Para añadir otro proyecto de staging, ver
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
│   ├── 18/                         ← addons para todos los Odoo 18
│   └── 19/                         ← addons para todos los Odoo 19
│
├── enterprise/                     ← addons Odoo Enterprise, separados por versión
│   ├── odoo18/
│   └── odoo19/
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
│   ├── nginx-dedupe.sh             ← limpia bloques duplicados en confs de nginx
│   ├── backup-cron.sh             ← backup-all + retención, para cron
│   └── odoo-entrypoint.sh          ← instala requirements.txt de shared-addons al startup
│
└── docs/                           ← guías paso a paso
    ├── 01-instalacion.md
    ├── 02-agregar-proyecto-dominio.md
    ├── 03-addons-personalizados.md
    ├── 04-actualizar-modulo.md
    ├── 05-backups.md
    ├── 06-operaciones-cheatsheet.md
    ├── 07-configuracion-por-servidor.md
    └── 08-checklist-produccion.md
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
| `scripts/nginx-dedupe.sh`    | Limpia bloques duplicados en `00-upstreams.conf` y `vhosts-projects.conf` (típico tras varias corridas de `sync-projects.sh` en escenarios de reset).    |
| `scripts/odoo-entrypoint.sh` | Wrapper de arranque del container Odoo: instala `requirements.txt` de módulos en `shared-addons/` antes de pasarle el control al entrypoint oficial.    |
| `scripts/backup-cron.sh`     | Backup automático no interactivo (`backup-all`) + retención configurable (`RETENTION_DAYS`). Pensado para `cron`. Ver [docs/05-backups.md](docs/05-backups.md).    |

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

# 3. Emitir SSL (DNS debe apuntar al servidor primero)
chmod +x scripts/*.sh && ./scripts/setup-ssl.sh

# 5. Levantar todo
./scripts/ops.sh start

# 6. Estado
./scripts/ops.sh health
```

---

## Comandos más usados

```bash
./scripts/ops.sh health
./scripts/ops.sh logs odoo19_farmaniacos_sta 200
./scripts/ops.sh restart odoo19_farmaniacos_sta

# Actualizar un módulo en una DB de staging
./scripts/ops.sh module odoo19_farmaniacos_sta farmaniacos_sta_principal mi_modulo update

# Backup (DB + filestore → ./backups/farmaniacos/)
./scripts/ops.sh backup farmaniacos odoo19_farmaniacos_sta farmaniacos_sta_principal

# Listar backups disponibles
./scripts/ops.sh list-backups farmaniacos

# Restaurar (auto-detecta filestore por timestamp)
./scripts/ops.sh restore odoo19_farmaniacos_sta farmaniacos_sta_copia \
  farmaniacos/db/20260511_020000_farmaniacos_sta_principal.sql.gz

# Restaurar un backup que viene de otro servidor (.tar.gz / .zip / .sql.gz)
./scripts/ops.sh restore-external odoo18_reycar_sta reycar_sta_principal \
  /opt/backups_odoo/conexion_prod_FULL_2026-05-12.tar.gz

# Neutralizar una DB recién importada de producción (apaga cron, mail, pagos…)
./scripts/ops.sh neutralize odoo18_reycar_sta reycar_sta_principal

# Nuevo proyecto staging
./scripts/new-project.sh clientenuevo 19 sta 19030

# Sincronizar overrides (agrega bloque por defecto a proyectos que no lo tienen)
./scripts/sync-overrides.sh                  # dry-run
./scripts/sync-overrides.sh --apply          # aplicar a todos los faltantes

# Eliminar un proyecto staging (pide confirmación, IRREVERSIBLE)
./scripts/delete-project.sh clientenuevo sta --dry-run    # previsualizar
./scripts/delete-project.sh clientenuevo sta              # aplicar
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
