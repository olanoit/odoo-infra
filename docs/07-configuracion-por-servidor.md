# 07 — Configuración por Servidor (docker-compose.override.yml)

> **Objetivo:** Personalizar recursos, addons y parámetros de Odoo por servidor  
> sin modificar archivos trackeados en git, para que `git pull` siempre funcione limpio.

---

## Arquitectura de dos capas

```
odoo.conf  (git ✓)           docker-compose.override.yml  (servidor, gitignored ✓)
─────────────────────────    ─────────────────────────────────────────────────────
• dbfilter                   • workers (ajustado al RAM del servidor)
• proxy_mode                 • limit_memory_* (ajustado al RAM del servidor)
• puertos (8069/8072)        • addons_path (subdirectorios de shared-addons)
• log_level base             • db_maxconn (ajustado a la carga esperada)
• defaults de entorno        • cualquier otro parámetro de Odoo
```

`docker-compose.override.yml` es fusionado automáticamente por Docker Compose.
Los argumentos CLI sobreescriben los valores de `odoo.conf`.

---

## Crear el archivo de override

### Opción A — Automático (recomendado)

`sync-projects.sh --apply` ya invoca `sync-overrides.sh` para el nuevo proyecto,
así que cada nuevo despliegue arranca con un bloque por defecto que incluye:

- `entrypoint` wrapper que instala `requirements.txt` de cualquier `shared-addons/`
- `--addons-path` con `extendrix_extra_addons/tools` (más enterprise, extra, core)
- `--workers=4` y limites de memoria 2GB/2.5GB

Para sincronizar overrides en proyectos **ya existentes** que no tienen entrada:

```bash
# Ver qué proyectos del registry no tienen override aún (dry-run)
./scripts/sync-overrides.sh

# Aplicar a todos los faltantes
./scripts/sync-overrides.sh --apply

# Solo a un proyecto
./scripts/sync-overrides.sh --apply micliente

# Forzar (sobrescribe entrada existente con la plantilla default)
./scripts/sync-overrides.sh --apply micliente --force

# Aplicar y recrear contenedores de una pasada
./scripts/sync-overrides.sh --apply --recreate
```

Después editá manualmente cualquier bloque para agregar:
- `mercadolibre` u otros subdirectorios de `shared-addons/` al `--addons-path`
- `environment: PYTHONPATH: ...` si el módulo lo necesita
- Recursos (`--workers`, `--limit-memory-*`) según el servidor

### Opción B — Manual

```bash
nano /opt/odoo-infra/docker-compose.override.yml
```

> El archivo no se commitea — ya está en `.gitignore`. Cada servidor tiene el suyo propio.

---

## Estructura del override

```yaml
# docker-compose.override.yml
# Personalización de este servidor — NO commitear al repositorio
services:

  odoo19_motomarket_sta:
    command:
      - odoo
      - --config=/etc/odoo/odoo.conf
      - --workers=4
      - --limit-memory-soft=2147483648
      - --limit-memory-hard=2684354560
      - --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons

  odoo19_otroproyecto_sta:
    command:
      - odoo
      - --config=/etc/odoo/odoo.conf
      - --workers=2
      - --limit-memory-soft=1073741824
      - --limit-memory-hard=1610612736
      - --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/extendrix_extra_addons/account,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons
```

> El `command:` usa **lista YAML** (cada flag en su línea) en lugar del estilo
> folded `>`. Es lo que genera `sync-overrides.sh` por defecto desde 2026-05-12.
> Ventaja: legible, fácil de agregar/quitar flags. El `--addons-path` sigue siendo
> una sola string con comas (Odoo no acepta paths en líneas separadas).

---

## Referencia de argumentos CLI de Odoo

Todos estos argumentos sobreescriben el valor equivalente en `odoo.conf`:

| Argumento CLI                | Config equivalente      | Unidad   |
|------------------------------|-------------------------|----------|
| `--workers N`                | `workers`               | número   |
| `--limit-memory-soft N`      | `limit_memory_soft`     | bytes    |
| `--limit-memory-hard N`      | `limit_memory_hard`     | bytes    |
| `--limit-time-cpu N`         | `limit_time_cpu`        | segundos |
| `--limit-time-real N`        | `limit_time_real`       | segundos |
| `--limit-request N`          | `limit_request`         | número   |
| `--max-cron-threads N`       | `max_cron_threads`      | número   |
| `--db-maxconn N`             | `db_maxconn`            | número   |
| `--addons-path PATH`         | `addons_path`           | rutas    |
| `--log-level LEVEL`          | `log_level`             | string   |
| `--http-port N`              | `http_port`             | número   |
| `--gevent-port N`            | `gevent_port`           | número   |

### Referencia de memoria (bytes)

| RAM   | Bytes             |
|-------|-------------------|
| 512 MB | 536,870,912      |
| 1 GB  | 1,073,741,824     |
| 1.5 GB| 1,610,612,736     |
| 2 GB  | 2,147,483,648     |
| 2.5 GB| 2,684,354,560     |
| 3 GB  | 3,221,225,472     |
| 4 GB  | 4,294,967,296     |
| 6 GB  | 6,442,450,944     |
| 8 GB  | 8,589,934,592     |

---

## Perfiles de recursos por tamaño de servidor

### Servidor pequeño (4 GB RAM, 2 vCPU) — 1–2 proyectos

```yaml
services:
  odoo19_micliente_sta:
    command:
      - odoo
      - --config=/etc/odoo/odoo.conf
      - --workers=2
      - --limit-memory-soft=1073741824
      - --limit-memory-hard=1610612736
      - --max-cron-threads=1
      - --db-maxconn=16
      - --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons
```

### Servidor mediano (8 GB RAM, 4 vCPU) — 2–4 proyectos

```yaml
services:
  odoo19_cliente1_sta:
    command:
      - odoo
      - --config=/etc/odoo/odoo.conf
      - --workers=4
      - --limit-memory-soft=2147483648
      - --limit-memory-hard=2684354560
      - --max-cron-threads=2
      - --db-maxconn=24
      - --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons

  odoo19_cliente2_sta:
    command:
      - odoo
      - --config=/etc/odoo/odoo.conf
      - --workers=4
      - --limit-memory-soft=2147483648
      - --limit-memory-hard=2684354560
      - --max-cron-threads=2
      - --db-maxconn=24
      - --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/extendrix_extra_addons/account,/mnt/extra-addons
```

### Servidor grande (16+ GB RAM, 8+ vCPU) — 4+ proyectos o carga alta

```yaml
services:
  odoo19_clientekey_sta:
    command:
      - odoo
      - --config=/etc/odoo/odoo.conf
      - --workers=8
      - --limit-memory-soft=3221225472
      - --limit-memory-hard=4294967296
      - --max-cron-threads=3
      - --db-maxconn=32
      - --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/extendrix_extra_addons/account,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons
```

### Modo depuración puntual (single-process)

Si en algún momento necesitás depurar un contenedor staging con logs detallados,
podés cambiar temporalmente al modo single-process (no para uso continuo):

```yaml
services:
  odoo19_micliente_sta:
    command:
      - odoo
      - --config=/etc/odoo/odoo.conf
      - --workers=0
      - --log-level=debug
      - --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons
```

> `--workers=0` activa el modo single-process con logs en consola. Acordate de
> revertirlo después de depurar.

---

## Selección de addons por proyecto

Ver estructura de `shared-addons`:

```bash
tree -L 2 shared-addons/
```

Según lo que necesita el proyecto, seleccionar los subdirectorios:

```yaml
# Solo tools (utilidades generales)
--addons-path=...,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons

# Solo account (facturación electrónica)
--addons-path=...,/mnt/shared-addons/extendrix_extra_addons/account,/mnt/extra-addons

# Ambos
--addons-path=...,/mnt/shared-addons/extendrix_extra_addons/account,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons

# Toda la carpeta shared-addons (sin filtrar por subdirectorio)
--addons-path=...,/mnt/shared-addons,/mnt/extra-addons
```

---

## Aplicar cambios al override

```bash
# Después de crear o editar docker-compose.override.yml:

# Aplicar a un solo contenedor (sin tocar los demás)
docker compose up -d --force-recreate odoo19_motomarket_sta

# Verificar que el comando activo incluye los parámetros esperados
docker inspect odoo19_motomarket_sta \
  --format '{{range .Args}}{{.}} {{end}}' | tr ' ' '\n'

# Verificar addons_path activo dentro del contenedor
docker exec odoo19_motomarket_sta python3 -c \
  "import odoo.tools; print(odoo.tools.config['addons_path'])"
```

---

## Flujo de trabajo: agregar un proyecto nuevo al override

Cuando `sync-projects.sh --apply` agrega un nuevo servicio, agregar también
su entrada al override del servidor:

```bash
# 1. Verificar cuáles addons necesita el nuevo proyecto
tree -L 2 shared-addons/

# 2. Agregar la entrada al override
nano /opt/odoo-infra/docker-compose.override.yml

# 3. Levantar el nuevo contenedor (usa el override automáticamente)
docker compose up -d odoo19_nuevoproyecto_sta

# 4. Verificar
docker inspect odoo19_nuevoproyecto_sta --format '{{range .Args}}{{.}} {{end}}'
```

---

## Diagnóstico de configuración activa

```bash
# Ver la configuración efectiva que usa Odoo (fusión de config + CLI)
docker exec odoo19_motomarket_sta python3 -c "
import odoo.tools
config = odoo.tools.config
print(f'workers:        {config[\"workers\"]}')
print(f'addons_path:    {config[\"addons_path\"]}')
print(f'limit_mem_soft: {config[\"limit_memory_soft\"] // 1024 // 1024} MB')
print(f'limit_mem_hard: {config[\"limit_memory_hard\"] // 1024 // 1024} MB')
print(f'db_maxconn:     {config[\"db_maxconn\"]}')
"
```
