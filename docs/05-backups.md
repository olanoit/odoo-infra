# 05 — Backups y Restauración por Terminal (Staging)

> **Objetivo:** Crear y restaurar backups (DB + filestore) de las bases de staging
> usando un **único volumen central** compartido por todos los proyectos.
>
> Este entorno **solo opera con bases de staging** (`<proyecto>_sta_*`). Todos los
> ejemplos asumen ese sufijo.

---

## Volumen central de backups

Todos los backups viven en un único bind-mount en la raíz del repo:

```
./backups/                              ← raíz del volumen (host)
└── <proyecto>/
    ├── db/                             ← dumps PostgreSQL (.sql.gz)
    │   └── YYYYMMDD_HHMMSS_<db>.sql.gz
    └── filestore/                      ← filestore Odoo (.tar.gz)
        └── YYYYMMDD_HHMMSS_<db>_filestore.tar.gz
```

El directorio `./backups/` está montado como `/backups` dentro del contenedor de
PostgreSQL **y** dentro de cada contenedor Odoo (ver `docker-compose.yml`). Esto
permite que el dump SQL lo escriba `pg_dump` directamente sobre el volumen, y que
el tar del filestore lo arme el contenedor Odoo sin necesidad de copiar archivos
intermedios al host.

> El directorio está en `.gitignore`: nunca termina en el repo.

Ejemplo real con un proyecto:

```
./backups/motomarket/
├── db/
│   └── 20260511_020000_motomarket_sta_principal.sql.gz
└── filestore/
    └── 20260511_020000_motomarket_sta_principal_filestore.tar.gz
```

---

## Crear un backup (DB + filestore) por terminal

```bash
# SINTAXIS:
./scripts/ops.sh backup <proyecto> <contenedor> <base_de_datos>

# Ejemplo — staging principal de motomarket:
./scripts/ops.sh backup motomarket odoo19_motomarket_sta motomarket_sta_principal
```

Esto genera dos archivos con el **mismo timestamp** en `./backups/motomarket/`:

- `db/20260511_020000_motomarket_sta_principal.sql.gz` (pg_dump comprimido)
- `filestore/20260511_020000_motomarket_sta_principal_filestore.tar.gz`

Si la DB todavía no tiene adjuntos, el filestore se omite con un warning (es normal
en bases recién creadas).

### Backup de todas las DBs de staging detectadas

```bash
./scripts/ops.sh backup-all
```

Recorre todas las DBs reales (excluye `postgres` y templates), deduce el proyecto y
el contenedor por el nombre (`<proyecto>_<entorno>_*`) y respalda DB + filestore de
cada una en el volumen central.

---

## Listar backups disponibles

```bash
# Todos los proyectos
./scripts/ops.sh list-backups

# Solo un proyecto
./scripts/ops.sh list-backups motomarket
```

Equivalente manual:

```bash
ls -lh ./backups/motomarket/db/
ls -lh ./backups/motomarket/filestore/
```

---

## Restaurar un backup (DB + filestore)

```bash
# SINTAXIS:
./scripts/ops.sh restore <contenedor> <db_destino> <db_backup> [<filestore_backup>]
```

- `<db_backup>` y `<filestore_backup>` pueden ser **rutas absolutas en el host** o
  **rutas relativas a `./backups/`** (más cómodo).
- Si **omites** `<filestore_backup>`, el script busca uno con el **mismo timestamp**
  bajo `./backups/` y lo restaura automáticamente.
- Si la DB destino ya existe, el comando aborta. Bórrala primero (ver más abajo).
- El nombre de la DB destino **debe** respetar el `dbfilter` del contenedor
  (`^<proyecto>_sta_.*$`) para que Odoo la muestre en el selector.

### Ejemplos

```bash
# A) Restauración típica — auto-detecta el filestore por timestamp
./scripts/ops.sh restore \
  odoo19_motomarket_sta \
  motomarket_sta_copia \
  motomarket/db/20260511_020000_motomarket_sta_principal.sql.gz

# B) Especificando ambos archivos manualmente
./scripts/ops.sh restore \
  odoo19_motomarket_sta \
  motomarket_sta_qa \
  motomarket/db/20260511_020000_motomarket_sta_principal.sql.gz \
  motomarket/filestore/20260511_020000_motomarket_sta_principal_filestore.tar.gz

# C) Sobrescribir una DB existente (eliminarla primero)
docker exec odoo_postgres dropdb -U odoo motomarket_sta_copia
./scripts/ops.sh restore odoo19_motomarket_sta motomarket_sta_copia \
  motomarket/db/20260511_020000_motomarket_sta_principal.sql.gz
```

### Qué hace internamente el `restore`

1. Crea la DB vacía con `createdb`.
2. Restaura el dump con `zcat … | psql -d <db_destino>`.
3. Extrae el tar del filestore dentro del contenedor Odoo y lo **renombra** a la
   carpeta de la DB destino: `/var/lib/odoo/filestore/<db_destino>/`.
4. Reinicia el contenedor Odoo para que detecte la nueva DB.

> El renombrado del filestore es lo que permite restaurar `motomarket_sta_principal`
> como `motomarket_sta_copia` sin que Odoo pierda los adjuntos.

---

## Restaurar un backup que viene de OTRO servidor (producción → staging)

Cuando hay que importar a staging la DB de un cliente desde su servidor de producción, el archivo
**no respeta** la convención `YYYYMMDD_HHMMSS_<db>.sql.gz` ni vive bajo `./backups/`.
Para esos casos existe el comando dedicado **`restore-external`**, que:

- Detecta el formato por extensión: `.tar.gz`, `.tgz`, `.zip`, `.sql.gz` o `.sql`.
- Extrae el archivo, busca `dump.sql` (o `dump.sql.gz`) y `filestore/` automáticamente.
- **Remapea el OWNER** de todos los objetos al rol `odoo` (la DB de producción suele
  pertenecer a otro usuario PostgreSQL que aquí no existe).
- Neutraliza líneas conflictivas (`CREATE DATABASE`, `\connect`, `SET ROLE`).
- Carga con `ON_ERROR_STOP=0` y reporta cuántos errores hubo al final.
- Copia el filestore al volumen del contenedor y lo renombra a la DB destino.

### Sintaxis

```bash
./scripts/ops.sh restore-external <contenedor> <db_destino> <archivo>
```

### Ejemplo — importar producción de un cliente a su staging

Supongamos que se copió un backup de producción al servidor de staging en
`/opt/backups_odoo/conexion_prod250707_FULL_2026-05-12_09-20.tar.gz`,
y se quiere cargarlo en el proyecto `reycar`:

```bash
# 1. (Opcional) Inspeccionar el contenido del archivo
tar -tzf /opt/backups_odoo/conexion_prod250707_FULL_2026-05-12_09-20.tar.gz | head

# 2. Restaurar a una DB nueva en el contenedor de reycar
./scripts/ops.sh restore-external \
  odoo18_reycar_sta \
  reycar_sta_principal \
  /opt/backups_odoo/conexion_prod250707_FULL_2026-05-12_09-20.tar.gz

# 3. Neutralizar (apaga cron, mail saliente, payment providers, etc.)
./scripts/ops.sh neutralize odoo18_reycar_sta reycar_sta_principal
```

> El nombre de DB destino **debe** respetar el dbfilter del contenedor
> (`^<proyecto>_sta_.*`) para que Odoo la muestre en el selector.

### Formatos soportados

| Extensión       | Contenido típico                          | Filestore |
|-----------------|-------------------------------------------|-----------|
| `.tar.gz`/`.tgz`| `dump.sql` + `filestore/` (auto_backup, odoo-backup) | Sí, si está |
| `.zip`          | Formato nativo de Odoo (web/database/backup)         | Sí        |
| `.sql.gz`       | Solo `pg_dump` plano comprimido           | No        |
| `.sql`          | Solo `pg_dump` plano                      | No        |

Para `.sql`/`.sql.gz` se restaura **solo la DB**; los adjuntos quedarán rotos hasta que
se cargue manualmente un filestore por separado.

### Si la DB destino ya existe

```bash
docker exec odoo_postgres dropdb -U odoo --force reycar_sta_principal
./scripts/ops.sh restore-external odoo18_reycar_sta reycar_sta_principal /ruta/al/archivo.tar.gz
```

### Neutralizar después de importar producción

Antes de levantar Odoo contra una DB recién importada, es **fundamental** desactivar
cualquier integración que pueda generar efectos en sistemas reales del cliente:

```bash
./scripts/ops.sh neutralize <contenedor> <db>
```

Desactiva en SQL directo:

- `ir_cron` → todos los cron jobs apagados
- `ir_mail_server` → servidores SMTP saliente apagados
- `fetchmail_server` → servidores POP/IMAP entrantes apagados
- `payment_provider` / `payment_acquirer` → estado `disabled`
- `ir_config_parameter` → borra `web.base.url` y `web.base.url.freeze`

> **Revisar manualmente** después: API keys de integraciones (MercadoLibre,
> Stripe, etc.), webhooks, usuarios admin, cuentas bancarias, contraseñas.

### Resolución de problemas frecuentes

| Síntoma                                              | Causa probable / Solución                            |
|------------------------------------------------------|------------------------------------------------------|
| `relation res_users does not exist`                  | El dump cargó con errores graves. Revisar el log temporal que reporta `restore-external` y reintentar. |
| Odoo no muestra la DB en el selector                 | El nombre no coincide con el dbfilter del contenedor. Renombrar la DB destino respetando `<proyecto>_sta_*`. |
| Aparecen errores `role "..." does not exist`         | Normal — son objetos cuya pertenencia no se pudo remapear. El restore continúa y los datos quedan accesibles. |
| Tras login, Odoo redirige a URL de producción        | Falta neutralizar: `./scripts/ops.sh neutralize <ctr> <db>`. |
| Versión de Odoo en backup != staging                 | Tras restore, ejecutar `module <ctr> <db> base update` para migrar la DB. |
| `pg_dump: server version (X.Y); pg_dump version (Z.W)` | El dump fue hecho con una versión de PostgreSQL más nueva que la del staging. Actualizar PostgreSQL o pedir un dump compatible. |

---

## Automatizar backups con cron

```bash
crontab -e
```

```cron
# ─── Backups nocturnos de staging ──────────────────────────────────────────
# 02:00 — motomarket staging
0 2 * * * /opt/odoo-infra/scripts/ops.sh backup motomarket odoo19_motomarket_sta motomarket_sta_principal >> /var/log/odoo-backups.log 2>&1

# ─── Limpieza semanal — mantener solo los últimos 14 días ─────────────────
0 4 * * 0 find /opt/odoo-infra/backups/*/db/        -name "*.sql.gz" -mtime +14 -delete >> /var/log/odoo-backups.log 2>&1
0 4 * * 0 find /opt/odoo-infra/backups/*/filestore/ -name "*.tar.gz" -mtime +14 -delete >> /var/log/odoo-backups.log 2>&1
```

Para más proyectos, replicá la primera línea cambiando `<proyecto>`, contenedor y nombre de DB.

---

## Backup vía interfaz Odoo (alternativa puntual)

Solo para emergencias o cuando la terminal no esté disponible:

1. Ir a `https://<dominio_sta>/web/database/manager`
2. Clic en el ícono de descarga (↓) junto a la DB
3. Elegir formato: **ZIP** (incluye filestore) o **pg_dump** (solo DB)
4. Ingresar la Master Password (`admin_passwd` de `odoo.conf`)

> El terminal es preferible: backup atómico, comprimido, controlado por cron y sin
> límites de tamaño del navegador.

---

## Transferir backup fuera del servidor

```bash
# Al equipo local
scp usuario@IP_SERVIDOR:/opt/odoo-infra/backups/motomarket/db/*.sql.gz ~/backups/

# A AWS S3 (sincroniza todo el árbol de backups)
aws s3 sync /opt/odoo-infra/backups/ \
  s3://mi-bucket/odoo-staging-backups/ \
  --storage-class STANDARD_IA

# A Google Drive con rclone
rclone copy /opt/odoo-infra/backups/ gdrive:odoo-staging-backups/
```

---

## Verificar integridad de un backup

```bash
# DB
gzip -t backups/motomarket/db/20260511_020000_motomarket_sta_principal.sql.gz
echo "Exit code: $?"   # 0 = OK

# Filestore
gzip -t backups/motomarket/filestore/20260511_020000_motomarket_sta_principal_filestore.tar.gz
tar tzf  backups/motomarket/filestore/20260511_020000_motomarket_sta_principal_filestore.tar.gz | head
```

---

## Política de retención sugerida (staging)

| Tipo de backup | Retención | Frecuencia |
|----------------|-----------|------------|
| DB             | 14 días   | Diaria     |
| Filestore      | 14 días   | Diaria     |

```bash
# Espacio usado por proyecto
du -sh backups/*/
```
