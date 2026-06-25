# 01 — Instalación desde Cero

> **Objetivo:** Tener el entorno completamente operativo en un servidor Ubuntu limpio.  
> **Tiempo estimado:** 30–45 minutos  
> **Prerrequisito:** Ubuntu 22.04 / 24.04 LTS, acceso root o sudo, dominio con DNS apuntando al servidor.

---

## Paso 1 — Preparar el servidor Ubuntu

```bash
# 1.1 Actualizar el sistema
sudo apt update && sudo apt upgrade -y

# 1.2 Instalar dependencias base
sudo apt install -y curl git unzip vim ca-certificates gnupg lsb-release dnsutils

# 1.3 Instalar Docker Engine (método oficial)
curl -fsSL https://get.docker.com | sudo sh

# 1.4 Agregar tu usuario al grupo docker (evitar usar sudo en cada comando)
sudo usermod -aG docker $USER

# 1.5 Aplicar el cambio de grupo SIN cerrar sesión
newgrp docker

# 1.6 Verificar instalación
docker --version            # debe ser >= 24.x
docker compose version      # debe ser >= 2.x
```

---

## Paso 2 — Clonar el proyecto al servidor

```bash
git clone https://github.com/Extendrix-Ecommmerce-Services/odoo-multi-version.git /opt/odoo-infra
cd /opt/odoo-infra

chmod +x scripts/*.sh
```

---

## Paso 3 — Configurar variables de entorno

```bash
cp .env.example .env
nano .env
```

Contenido mínimo requerido en `.env`:

```dotenv
POSTGRES_PASSWORD=TuContraseñaSegura2024!
CERTBOT_EMAIL=admin@tudominio.com

# Una variable DOMAIN_ por cada instancia
DOMAIN_MICLIENTE_STA=micliente-sta.tudominio.com
```

---

## Paso 4 — Registrar el primer proyecto

```bash
nano projects-registry.conf
```

Agregar una línea con el formato `PROYECTO:VERSION:ENTORNO:DOMINIO:PUERTO`:

```
micliente:19:sta:micliente-sta.tudominio.com:19020
```

Aplicar (genera directorios, odoo.conf, docker-compose, nginx):

```bash
./scripts/sync-projects.sh --apply
```

Ver detalles completos en [02-agregar-proyecto-dominio.md](02-agregar-proyecto-dominio.md).

---

## Paso 5 — Verificar que los DNS están propagados

> ⚠️ **Este paso es crítico.** Certbot fallará si el DNS no apunta al servidor.

```bash
# IP pública de este servidor
curl -s https://api.ipify.org

# Verificar que cada dominio resuelve a esa IP
dig +short micliente-sta.tudominio.com
```

Si el dominio usa un CNAME intermedio es válido — lo importante es que el último registro A apunte al servidor.

---

## Paso 6 — Emitir certificados SSL

```bash
./scripts/setup-ssl.sh
```

El script hace lo siguiente de forma automática:

1. Lee todas las variables `DOMAIN_*` del `.env`
2. Verifica DNS de cada dominio (maneja CNAMEs)
3. Levanta Nginx con config mínima (sin referencias a upstreams de Odoo)
4. Emite los certificados via Certbot (challenge webroot)
5. Restaura la config completa y recarga Nginx con SSL activo

> **Por qué necesitamos este paso separado:** Nginx no puede cargar el bloque HTTPS si los archivos `.pem` no existen, y no puede resolver los upstreams de Odoo si los contenedores no están corriendo. El script maneja ambos casos automáticamente.

---

## Paso 6.5 — Crear el override de configuración del servidor (opcional pero recomendado)

```bash
nano /opt/odoo-infra/docker-compose.override.yml
```

Este archivo permite personalizar recursos y addons por servidor sin tocar git:

```yaml
# docker-compose.override.yml — específico de este servidor, NO commitear
services:
  odoo19_micliente_sta:
    command: >
      odoo --config=/etc/odoo/odoo.conf
      --workers=4
      --limit-memory-soft=2147483648
      --limit-memory-hard=2684354560
      --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/extendrix_extra_addons/tools,/mnt/extra-addons
```

Ver perfiles de recursos y guía completa en [07-configuracion-por-servidor.md](07-configuracion-por-servidor.md).

---

## Paso 7 — Levantar todos los servicios

```bash
./scripts/ops.sh start
```

Orden de inicio: `db` → (healthcheck) → `instancias Odoo` → `nginx` + `certbot`

> **Importante:** Odoo debe iniciar antes que Nginx. Nginx resuelve los hostnames de los upstreams via DNS interno de Docker al arrancar — si Odoo no está corriendo, ese DNS falla y Nginx crashea.

---

## Paso 8 — Verificar que todo funciona

```bash
./scripts/ops.sh health
```

Todos los contenedores deben estar `running` con healthcheck `healthy`.

Acceder en el navegador a cada dominio registrado. Verás el selector de base de datos de Odoo.

---

## Paso 9 — Crear la primera base de datos

1. Ir a `https://<tu-dominio>/web/database/manager`
2. Clic en **"Create Database"**
3. Usar el nombre con el prefijo del entorno (ej: `micliente_sta_principal`)
4. Ingresar la Master Password definida en `odoo.conf` (`admin_passwd`)
5. Elegir país, idioma y demo data (desactivar en staging/producción)

---

## Estructura de directorios importantes

```
/opt/odoo-infra/
├── shared-addons/          ← módulos compartidos, por VERSIÓN de Odoo
│   ├── 18/                 ← módulos para todos los proyectos Odoo 18
│   │   └── al_l10n_pe_edi/
│   └── 19/                 ← módulos para todos los proyectos Odoo 19
│       └── al_l10n_pe_edi/
├── enterprise/
│   └── odoo19/             ← addons enterprise de Odoo 19 (si aplica)
├── backups/                ← volumen central de backups (DB + filestore, gitignored)
│   └── <proyecto>/{db,filestore}/
├── projects/
│   └── micliente/
│       └── odoo19/
│           └── sta/
│               └── addons/ ← addons EXCLUSIVOS de este proyecto staging
└── nginx/certbot/conf/     ← certificados SSL (gestionados por Certbot)
```

Dentro de cada contenedor Odoo, los paths quedan así:

| Path en contenedor    | Fuente en host                                        |
|-----------------------|-------------------------------------------------------|
| `/mnt/extra-addons`   | `projects/{proyecto}/odoo{ver}/{entorno}/addons/`     |
| `/mnt/shared-addons`  | `shared-addons/{VERSION}/`                            |
| `/mnt/enterprise`     | `enterprise/odoo{version}/`                           |

---

## Solución de problemas comunes

**Nginx en estado `restarting` al inicio:**
```bash
docker logs odoo_nginx --tail 20
# Si dice "host not found in upstream" → Odoo no está corriendo
# Solución: levantar primero Odoo, luego Nginx
docker compose up -d $(docker compose config --services | grep '^odoo')
docker compose restart nginx
```

**Certbot falla con "connection refused":**
```bash
# 1. Verificar que el puerto 80 está abierto en el firewall
sudo ufw allow 80 && sudo ufw allow 443

# 2. Verificar que el DNS resuelve al servidor (incluyendo CNAMEs)
dig +short micliente-sta.tudominio.com

# 3. Verificar que nginx está corriendo
docker compose ps nginx
```

**"live directory exists" al re-emitir certificado:**
```bash
# Limpiar artefactos del intento fallido y reintentar
docker compose run --rm --entrypoint sh certbot -c \
    "rm -rf /etc/letsencrypt/live/DOMINIO \
             /etc/letsencrypt/archive/DOMINIO \
             /etc/letsencrypt/renewal/DOMINIO.conf"
./scripts/setup-ssl.sh
```

**502 Bad Gateway después de SSL exitoso:**
```bash
# Odoo puede estar aún iniciando (esperar ~1 min) o tener http_interface mal configurado
docker logs odoo19_micliente_sta --tail 20
# Verificar en odoo.conf que http_interface está vacío (no 127.0.0.1)
grep http_interface projects/micliente/odoo19/sta/config/odoo.conf
```

**"Too many connections" en PostgreSQL:**
```bash
docker compose exec db psql -U odoo -c \
    "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"
# Reducir db_maxconn en odoo.conf y reiniciar el contenedor

```
