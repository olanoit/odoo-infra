# 06 — Operaciones Diarias (Cheatsheet)

> Referencia rápida de los comandos más usados.

---

## Estado del entorno

```bash
# Ver todos los contenedores y su estado de salud
./scripts/ops.sh health

# Ver solo los que están corriendo
docker compose ps

# Ver uso de CPU/RAM de cada contenedor en tiempo real
docker stats

# Ver uso de disco (volúmenes y backups)
df -h                                      # disco del servidor
du -sh backups/*/                          # espacio de backups (volumen central)
docker system df                           # espacio usado por Docker
```

---

## Iniciar y detener

```bash
# ─── Iniciar TODO (orden correcto: DB → Nginx → Odoo) ───────────────────
./scripts/ops.sh start

# ─── Detener TODO ────────────────────────────────────────────────────────
./scripts/ops.sh stop

# ─── Iniciar un solo contenedor ─────────────────────────────────────────
docker compose start odoo19_motomarket_sta

# ─── Detener un solo contenedor ─────────────────────────────────────────
docker compose stop odoo19_motomarket_sta

# ─── Detener y eliminar contenedores (conserva volúmenes y datos) ────────
docker compose down

# ─── Eliminar TODO incluyendo volúmenes (⚠️ BORRA DATOS) ─────────────────
docker compose down -v   # PELIGROSO — solo en entornos de prueba
```

---

## Reiniciar servicios

```bash
# Reiniciar UN contenedor Odoo
docker compose restart odoo19_motomarket_sta

# Reiniciar Nginx (después de cambiar configuración)
docker compose restart nginx

# Reiniciar la base de datos (raro, usar con cuidado)
docker compose restart db

# Reiniciar TODOS los servicios
docker compose restart
```

---

## Ver logs

```bash
# Logs en tiempo real de un contenedor
docker compose logs -f odoo19_motomarket_sta

# Últimas N líneas + seguir en tiempo real
./scripts/ops.sh logs odoo19_motomarket_sta 200

# Solo errores
docker logs odoo19_motomarket_sta 2>&1 | grep -E "ERROR|CRITICAL|Traceback"

# Logs de Nginx (accesos)
docker logs odoo_nginx 2>&1 | tail -50

# Logs de PostgreSQL
docker logs odoo_postgres 2>&1 | tail -50

# Ver logs de TODOS los servicios
docker compose logs -f --tail=20
```

---

## Actualizar módulos (ver guía completa en doc 04)

```bash
# Actualizar un módulo
./scripts/ops.sh module odoo19_motomarket_sta motomarket_sta_principal mi_modulo update

# Instalar un módulo nuevo
./scripts/ops.sh module odoo19_motomarket_sta motomarket_sta_principal mi_modulo install

# Actualizar múltiples módulos
./scripts/ops.sh module odoo19_motomarket_sta motomarket_sta_principal "modulo1,modulo2" update
```

---

## Ejecutar comandos dentro de un contenedor

```bash
# Shell interactivo dentro del contenedor Odoo
docker exec -it odoo19_motomarket_sta bash

# Ejecutar un comando Python en el contexto de Odoo (scaffold, etc.)
docker exec -it odoo19_motomarket_sta python3 -c "import odoo; print(odoo.__version__)"

# Ejecutar query SQL directamente en PostgreSQL
docker exec -it odoo_postgres psql -U odoo -d motomarket_sta_principal -c "SELECT version();"

# Acceder a psql interactivo de una DB
docker exec -it odoo_postgres psql -U odoo -d motomarket_sta_principal
```

---

## Gestión de bases de datos

```bash
# Listar todas las bases de datos
docker exec odoo_postgres psql -U odoo -l

# Listar solo las DBs de Odoo (excluye system DBs)
docker exec odoo_postgres psql -U odoo -t -c \
  "SELECT datname FROM pg_database WHERE datistemplate=false AND datname!='postgres' ORDER BY datname;"

# Crear una nueva DB vacía (Odoo la inicializará al acceder)
docker exec odoo_postgres createdb -U odoo motomarket_sta_pruebas

# Eliminar una DB (⚠️ irreversible)
docker exec odoo_postgres dropdb -U odoo motomarket_sta_pruebas

# Ver tamaño de cada DB
docker exec odoo_postgres psql -U odoo -c \
  "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;"

# Ver conexiones activas
docker exec odoo_postgres psql -U odoo -c \
  "SELECT datname, count(*), state FROM pg_stat_activity GROUP BY datname, state ORDER BY datname;"
```

---

## Consultas SQL en un proyecto específico

```bash
# Usar el shortcut del script:
./scripts/ops.sh db-query odoo19_motomarket_sta motomarket_sta_principal \
  "SELECT login, name, active FROM res_users ORDER BY login LIMIT 20;"

# Ver los módulos instalados en una DB
./scripts/ops.sh db-query odoo19_motomarket_sta motomarket_sta_principal \
  "SELECT name, state, latest_version FROM ir_module_module WHERE state='installed' ORDER BY name;"

# Ver tamaño de las tablas más grandes
./scripts/ops.sh db-query odoo19_motomarket_sta motomarket_sta_principal \
  "SELECT tablename, pg_size_pretty(pg_total_relation_size(tablename::regclass)) AS size FROM pg_tables WHERE schemaname='public' ORDER BY pg_total_relation_size(tablename::regclass) DESC LIMIT 20;"
```

---

## Actualizar imágenes Docker

```bash
# Actualizar imagen de un Odoo específico (baja la nueva patch version)
./scripts/ops.sh update-image odoo19_motomarket_sta

# Actualizar todas las imágenes
docker compose pull

# Aplicar las imágenes descargadas (reinicia los contenedores afectados)
docker compose up -d --remove-orphans

# Limpiar imágenes antiguas para liberar espacio
docker image prune -f
```

---

## SSL — Renovación y gestión

```bash
# Renovar certificados manualmente (normalmente es automático)
./scripts/ops.sh ssl-renew

# Ver fecha de vencimiento de los certificados
docker compose run --rm certbot certificates

# Ver fecha sin Certbot
echo | openssl s_client -connect motomarket-sta.extendrix.work:443 2>/dev/null \
  | openssl x509 -noout -dates
```

---

## Backups (volumen central ./backups)

```bash
# Backup completo (DB + filestore) → ./backups/motomarket/
./scripts/ops.sh backup motomarket odoo19_motomarket_sta motomarket_sta_principal

# Listar todos los backups disponibles
./scripts/ops.sh list-backups
./scripts/ops.sh list-backups motomarket

# Restaurar (auto-detecta filestore del mismo timestamp)
./scripts/ops.sh restore odoo19_motomarket_sta motomarket_sta_copia \
  motomarket/db/20260511_020000_motomarket_sta_principal.sql.gz

# Backup de TODAS las DBs de staging
./scripts/ops.sh backup-all

# Tamaño usado por backups
du -sh backups/*/
```

Guía completa en [05-backups.md](05-backups.md).

---

## Acceso remoto a la DB (túnel SSH)

Útil para conectarse con DBeaver/pgAdmin desde tu máquina local:

```bash
# Crear un túnel SSH que mapea el PostgreSQL del servidor a tu localhost:5433
ssh -L 5433:localhost:5432 usuario@IP_SERVIDOR -N &

# Ahora conectar DBeaver a:
#   Host: localhost
#   Port: 5433
#   User: odoo
#   Password: (la del .env)
```

---

## Configuración por servidor (override)

```bash
# Ver la configuración activa de un contenedor (fusión de odoo.conf + CLI override)
docker inspect odoo19_motomarket_sta \
  --format '{{range .Args}}{{.}} {{end}}' | tr ' ' '\n'

# Ver addons_path efectivo dentro del contenedor
docker exec odoo19_motomarket_sta python3 -c \
  "import odoo.tools; print(odoo.tools.config['addons_path'])"

# Aplicar cambios del override a un contenedor específico
docker compose up -d --force-recreate odoo19_motomarket_sta

# Ver si hay override activo
cat /opt/odoo-infra/docker-compose.override.yml

# Ver la configuración final que Docker Compose usaría (incluye override)
docker compose config
```

Ver guía completa en [07-configuracion-por-servidor.md](07-configuracion-por-servidor.md).

---

## Comandos de emergencia

```bash
# Ver si hay un proceso bloqueando la DB
./scripts/ops.sh db-query odoo19_motomarket_sta motomarket_sta_principal \
  "SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state FROM pg_stat_activity WHERE state != 'idle' AND query_start < now() - interval '5 minutes';"

# Matar un proceso de DB bloqueado
./scripts/ops.sh db-query odoo19_motomarket_sta motomarket_sta_principal \
  "SELECT pg_terminate_backend(PID_A_MATAR);"

# Forzar la reconstrucción de un contenedor sin datos
docker compose stop odoo19_motomarket_sta
docker compose rm -f odoo19_motomarket_sta
docker compose up -d odoo19_motomarket_sta

# Si Nginx no recarga bien la config nueva:
docker compose exec nginx nginx -t          # probar config
docker compose exec nginx nginx -s reload   # recargar sin downtime
```
