# 08 — Checklist de producción

> **Objetivo:** repasar qué cubre esta infraestructura para un despliegue de
> producción, qué debe verificar el operador antes de salir a producción, y qué
> limitaciones conocidas quedan fuera del alcance actual.

Esta guía complementa a [07-configuracion-por-servidor.md](07-configuracion-por-servidor.md)
(recursos) y [05-backups.md](05-backups.md) (respaldo y restauración).

---

## ✅ Lo que ya está cubierto

| Área | Cómo |
|------|------|
| **Master password fuera del repo** | `admin_passwd` se inyecta desde `ODOO_MASTER_PASSWD` (`.env`) por `--admin-passwd`. Ningún `odoo.conf` versionado contiene secretos. Sin la variable, los contenedores **no arrancan**. |
| **Gestor de DB no expuesto** | `list_db = False` en todos los `odoo.conf` + Nginx devuelve `404` en `/web/database`. |
| **Aislamiento de red** | Los puertos Odoo se publican solo en `127.0.0.1`; el acceso externo pasa siempre por Nginx con TLS. |
| **TLS moderno** | TLSv1.2/1.3, HSTS, ciphers ECDHE, renovación automática de certificados con Certbot. |
| **Límites de recursos** | `mem_limit` + `cpus` por contenedor (Docker) además de `limit-memory-*` (Odoo). Una instancia no puede tumbar al host. |
| **Rate-limiting de login** | `limit_req` en `/web/login` por vhost. |
| **Healthchecks + restart** | `healthcheck` en cada servicio y `restart: unless-stopped`. |
| **Rotación de logs** | `json-file` con `max-size`/`max-file` en todos los servicios. |
| **Backups + retención** | `scripts/backup-cron.sh` (DB + filestore + retención) listo para `cron`. |
| **Neutralización de DBs de prod** | `ops.sh neutralize` apaga cron/mail/pagos al traer una DB de producción a otro entorno. |

---

## 🔍 Verificar antes de salir a producción

- [ ] **`.env` con secretos fuertes y únicos.** `POSTGRES_PASSWORD` y
      `ODOO_MASTER_PASSWD` distintos entre sí. Genéralos con
      `openssl rand -base64 30 | tr -d '=+/' | cut -c1-30`.
- [ ] **`.env` no está en git** (ya está en `.gitignore`) ni en backups públicos.
- [ ] **Backups automáticos activos.** Instalar `backup-cron.sh` en `crontab` y
      **confirmar que corre** (revisar `./backups/_cron/`). Probar una
      **restauración real** en un entorno aparte: un backup sin restore probado no es un backup.
- [ ] **Copia off-site.** Encadenar `aws s3 sync` / `rclone` / `rsync` tras el
      backup nocturno. El backup en el mismo disco no protege ante fallo del disco.
- [ ] **Recursos dimensionados** al servidor real (ver perfiles en
      [07-configuracion-por-servidor.md](07-configuracion-por-servidor.md)) y
      tuning de PostgreSQL (`shared_buffers`, `effective_cache_size`) acorde a la RAM.
- [ ] **Firewall del host**: solo 80/443 (y SSH restringido) abiertos a internet.
      Los puertos `19010+`/`8069` nunca deben ser accesibles desde fuera.
- [ ] **DNS** de cada dominio apunta al servidor antes de emitir SSL.
- [ ] **Monitoreo/alertas** (uptime, disco, RAM) y revisión periódica de logs.
- [ ] **Actualizaciones**: plan para parchear imágenes (`ops.sh update-image`) y
      el SO del host.

---

## ⚠️ Limitaciones conocidas (fuera del alcance actual)

Estas son decisiones de arquitectura asumidas conscientemente. Si tu caso las
necesita, planifícalas como trabajo aparte:

1. **PostgreSQL compartido con superusuario único.** Todas las instancias usan el
   mismo rol `odoo`. Comprometer una instancia da acceso a las DBs de todos los
   proyectos del servidor. Para aislamiento fuerte: un rol/credencial por proyecto
   (o una instancia de PostgreSQL por cliente).
2. **Dependencias instaladas en runtime.** `odoo-entrypoint.sh` ejecuta
   `pip install` en cada arranque desde los `requirements.txt` de `shared-addons`.
   Arranques no reproducibles y dependientes de la red. Para producción estricta:
   construir una **imagen propia** con dependencias fijadas (Dockerfile).
3. **Sin alta disponibilidad.** Un solo host, un solo Nginx, un solo PostgreSQL,
   sin réplica ni failover. Apto para producción de bajo SLA; para HA hace falta
   replicación de PostgreSQL y balanceo entre nodos.
4. **`--admin-passwd` y `PASSWORD` visibles vía `docker inspect`.** Aceptable para
   un host de un solo administrador; si necesitás ocultarlos, usar Docker secrets.

---

## Resumen

Con el `.env` correctamente configurado, backups automáticos **probados** y copia
off-site, esta infraestructura es apta para **producción de uno o varios clientes
sobre un único servidor** con SLA moderado. Para multi-cliente con aislamiento
fuerte de datos o alta disponibilidad, atender primero las limitaciones 1–3.
