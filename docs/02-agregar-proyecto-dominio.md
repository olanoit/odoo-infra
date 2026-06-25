# 02 — Agregar un Nuevo Proyecto de Staging

> **Objetivo:** Agregar una nueva instancia Odoo de **staging** (`_sta`).
> **Ejemplo práctico:** Agregar `odoo19_micliente_sta` con dominio `micliente-sta.tudominio.com`.
>
> Este orquestador solo despliega entornos staging. Si necesitás dev o prod, usá
> otro repo o servidor — acá todo se llama `_sta`.

---

## Opción 1 — Automatización con `sync-projects.sh` (Recomendado)

El script aplica automáticamente todos los cambios necesarios:
directorios, `odoo.conf`, servicio en `docker-compose.yml`, upstream y vhost en Nginx.

> **Orden importante:** `.env` se edita **primero** porque dos scripts dependen de
> él. `sync-projects.sh --ssl` aborta si `CERTBOT_EMAIL` no está definido, y
> `setup-ssl.sh` (renovaciones, re-emisiones) recorre todas las `DOMAIN_*` del
> `.env` — si no agregás la variable del nuevo proyecto, su certificado nunca se
> renueva automáticamente.

### Paso 1 — Editar `.env` (variables del nuevo proyecto)

```bash
nano .env
```

Agregar **una línea `DOMAIN_*`** por cada instancia nueva y comprobar que existan
las dos variables globales:

```dotenv
# Globales (ya existen del setup inicial — verificar que estén)
POSTGRES_PASSWORD=TuContraseñaSegura     # usada por todos los contenedores Odoo
CERTBOT_EMAIL=admin@tudominio.com        # usada por --ssl para emitir/renovar certs

# Una variable DOMAIN_ por cada instancia
# Formato: DOMAIN_<PROYECTO>_<ENTORNO>=<subdominio>
DOMAIN_MICLIENTE_STA=micliente-sta.tudominio.com
```

**¿Para qué se usa cada cosa?**

| Variable                 | Quién la lee                                      | Para qué                          |
|--------------------------|---------------------------------------------------|-----------------------------------|
| `POSTGRES_PASSWORD`      | `docker-compose.yml` (postgres + todos los Odoo)  | Conexión a la DB                  |
| `CERTBOT_EMAIL`          | `sync-projects.sh --ssl`, `setup-ssl.sh`          | Notificaciones de Let's Encrypt   |
| `DOMAIN_<PROY>_<ENT>`    | `setup-ssl.sh`, `ops.sh health`                   | Renovación SSL y vista de estado  |

> El dominio también se pone en el siguiente paso (`projects-registry.conf`), pero
> esa entrada solo la usa `sync-projects.sh` durante el despliegue inicial. Para que
> el cert se **renueve** después, el dominio tiene que estar en `.env`.

### Paso 2 — Editar `projects-registry.conf`

```bash
nano projects-registry.conf
```

Agregar una línea con el formato `PROYECTO:VERSION:ENTORNO:DOMINIO:PUERTO_HTTP`
(el dominio debe coincidir exactamente con el valor de `DOMAIN_*` del paso 1):

```
micliente:19:sta:micliente-sta.tudominio.com:19020
```

> El puerto HTTP debe estar libre y respetar la convención de rangos
> (Odoo 19: `19010–19099`, incrementos de 10). Ver tabla más abajo.

### Paso 3 — Dry-run (ver qué haría el script)

```bash
./scripts/sync-projects.sh
```

Esto muestra los archivos que se crearían/modificarían sin tocar nada. Útil para
verificar el plan antes de aplicar.

### Paso 4 — Aplicar

> **Ejecutá solo UNO de estos comandos** según lo que necesites hacer.

```bash
# [A] Aplicar archivos únicamente (sin SSL ni levantar)
./scripts/sync-projects.sh --apply

# [B] Aplicar + emitir certificado SSL
./scripts/sync-projects.sh --apply --ssl

# [C] Aplicar + SSL + levantar contenedor
./scripts/sync-projects.sh --apply --ssl --start

# [D] TODO en uno: aplicar + SSL + levantar + validar  ← RECOMENDADO
./scripts/sync-projects.sh --apply --ssl --start --validate
```

**¿Cuándo usar cada uno?**

| Comando | Úsalo cuando... |
|---------|-----------------|
| `[A]` | El DNS aún no apunta al servidor (el SSL fallaría) |
| `[B]` | Quieres levantar el contenedor manualmente después |
| `[C]` | Ya tienes SSL o lo harás después |
| `[D]` | El DNS ya apunta al servidor — caso normal |

El script aplica automáticamente:
- Estructura de directorios y `odoo.conf`
- Carpetas del volumen central de backups: `backups/<proyecto>/{db,filestore}`
- Bloque de servicio en `docker-compose.yml` (con volúmenes `shared-addons`, `enterprise` y `./backups`)
- Entrada de volumen en `docker-compose.yml`
- Upstream en `nginx/conf.d/00-upstreams.conf`
- Vhost en `nginx/conf.d/vhosts-projects.conf`
- Certificado auto-firmado temporal (para que nginx arranque antes del cert real)

Los proyectos ya desplegados son detectados y omitidos automáticamente.

### Paso 5 — Agregar módulos compartidos (si aplica)

```bash
# shared-addons está separado por versión de Odoo: shared-addons/<VERSION>/
# Si el proyecto es Odoo 19 y el módulo ya está en shared-addons/19/, ya está disponible.
# Para agregar un nuevo módulo compartido a una versión específica:
cd shared-addons/19/    # o 18/, 17/ — según la versión del proyecto
git clone -b 19.0 https://github.com/extendrix/al_l10n_pe_edi.git
```

### Paso 6 — Validar el despliegue

```bash
./scripts/sync-projects.sh --validate
```

| Estado | Significado |
|--------|-------------|
| `[✓] Running · healthy` | Contenedor operativo y healthcheck OK |
| `[~] Running · healthcheck iniciando` | Arrancando, espera ~60s y vuelve a validar |
| `[✗] Detenido` | Contenedor parado — ejecuta `docker compose up -d <nombre>` |
| `[✗] unhealthy` | Contenedor falla healthcheck — revisa logs |
| `[✗] No definido` | Falta en `docker-compose.yml` — ejecuta con `--apply` |

---

## Tabla de referencia rápida — Puertos asignados

| Versión Odoo | Puerto HTTP host | Puerto LP host   | Convención HTTP         |
|--------------|-----------------|------------------|-------------------------|
| Odoo 17      | 17010–17099     | HTTP + 1         | 17010, 17020, 17030...  |
| Odoo 18      | 18010–18099     | HTTP + 1         | 18010, 18020, 18030...  |
| Odoo 19      | 19010–19099     | HTTP + 1         | 19010, 19020, 19030...  |

> El puerto de longpolling es siempre **puerto HTTP + 1** (ej: HTTP=19030 → LP=19031).

| Contenedor                  | HTTP host | Longpolling host |
|-----------------------------|-----------|------------------|
| odoo19_micliente_sta        | 19020     | 19021            |
| odoo19_otroproyecto_sta     | 19030     | 19031            |
| odoo19_tercercliente_sta    | 19040     | 19041            |

---

## Opción 2 — Configuración manual (paso a paso)

Para casos donde se necesita control total sobre cada archivo.

> Antes de empezar, agregá la variable del nuevo dominio en `.env` (igual que en el
> Paso 1 de la Opción 1). Sin eso, `setup-ssl.sh` no podrá renovar el certificado
> después y `ops.sh health` no listará el dominio.
>
> ```dotenv
> DOMAIN_MICLIENTE_STA=micliente-sta.tudominio.com
> ```

### PARTE A — Estructura de directorios

```bash
PROYECTO="micliente"
VERSION="odoo19"
ENTORNO="sta"

mkdir -p projects/${PROYECTO}/${VERSION}/${ENTORNO}/config
mkdir -p projects/${PROYECTO}/${VERSION}/${ENTORNO}/addons

# Volumen central de backups (compartido entre todos los proyectos)
mkdir -p backups/${PROYECTO}/db
mkdir -p backups/${PROYECTO}/filestore
```

### PARTE B — Archivo `odoo.conf`

```bash
./scripts/new-project.sh micliente 19 sta 19030
```

El archivo generado ya incluye los paths correctos. Verifica los valores críticos:

```ini
# Debe estar vacío (no 127.0.0.1) para que nginx pueda conectar vía red Docker
http_interface =

# Debe incluir enterprise y shared-addons
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons,/mnt/extra-addons

# Listado de bases de datos habilitado
list_db = True
```

### PARTE C — Servicio en `docker-compose.yml`

```yaml
  odoo19_micliente_sta:
    image: odoo:19.0
    container_name: odoo19_micliente_sta
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      HOST: db
      PORT: 5432
      USER: ${POSTGRES_USER:-odoo}
      PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - odoo19_micliente_sta_data:/var/lib/odoo
      - ./projects/micliente/odoo19/sta/config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./projects/micliente/odoo19/sta/addons:/mnt/extra-addons
      - ./shared-addons/19:/mnt/shared-addons:ro
      - ./enterprise/odoo19:/mnt/enterprise:ro
      - ./backups:/backups
    ports:
      - "127.0.0.1:19020:8069"
      - "127.0.0.1:19021:8072"
    networks:
      - odoo_net
    command: odoo --config=/etc/odoo/odoo.conf
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8069/web/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    logging:
      driver: "json-file"
      options: { max-size: "100m", max-file: "5" }
```

Agregar el volumen en la sección `volumes:`:

```yaml
  odoo19_micliente_sta_data:
    name: odoo19_micliente_sta_data
```

### PARTE D — Upstream en Nginx

Abrir `nginx/conf.d/00-upstreams.conf` y agregar antes del marcador `__SYNC_UPSTREAMS_INSERT__`:

```nginx
# --- ODOO 19 | MICLIENTE | STAGING ---
upstream up_micliente_sta_http {
    server odoo19_micliente_sta:8069 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 16;
}
upstream up_micliente_sta_lp {
    server odoo19_micliente_sta:8072 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 8;
}
```

### PARTE E — Vhost en Nginx

Abrir `nginx/conf.d/vhosts-projects.conf` y agregar antes del marcador `__SYNC_VHOSTS_INSERT__`:

```nginx
server {
    listen 80;
    server_name micliente-sta.tudominio.com;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl; http2 on;
    server_name micliente-sta.tudominio.com;

    ssl_certificate     /etc/letsencrypt/live/micliente-sta.tudominio.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/micliente-sta.tudominio.com/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/micliente-sta.tudominio.com/chain.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL_micliente_sta:10m;
    ssl_session_timeout 1d; ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=63072000" always;
    # ssl_stapling deshabilitado: Let's Encrypt ya no embebe OCSP responder URL.
    resolver 8.8.8.8 valid=300s; resolver_timeout 5s;
    client_max_body_size 200m;

    location ~* /web/login {
        limit_req zone=odoo_login burst=3 nodelay;
        proxy_pass http://up_micliente_sta_http;
        include /etc/nginx/conf.d/odoo-proxy-params.conf;
    }
    location /websocket {
        proxy_pass http://up_micliente_sta_lp;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 28800s; proxy_send_timeout 28800s;
    }
    location /longpolling {
        proxy_pass http://up_micliente_sta_lp;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection        "";
        proxy_redirect off;
        proxy_next_upstream off;
        proxy_read_timeout 28800s;
        proxy_send_timeout 28800s;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        proxy_pass http://up_micliente_sta_http;
        include /etc/nginx/conf.d/odoo-proxy-params.conf;
        expires 30d; add_header Cache-Control "public, immutable"; access_log off;
    }
    location / {
        proxy_pass http://up_micliente_sta_http;
        include /etc/nginx/conf.d/odoo-proxy-params.conf;
    }
}
```

### PARTE F — Certificado SSL

```bash
# Emitir el certificado
./scripts/setup-ssl.sh
# (el script maneja automáticamente el orden de arranque y la config temporal)

# O solo para el nuevo dominio (si el resto ya tiene SSL activo):
docker compose run --rm --entrypoint certbot certbot certonly \
  --webroot --webroot-path=/var/www/certbot \
  --email $(grep CERTBOT_EMAIL .env | cut -d= -f2) --agree-tos --no-eff-email \
  -d micliente-sta.tudominio.com
docker compose exec nginx nginx -s reload
```

### PARTE G — Levantar el contenedor

```bash
# Levantar Odoo primero, luego recargar nginx
docker compose up -d odoo19_micliente_sta
docker compose restart nginx

# Verificar estado
./scripts/ops.sh health
./scripts/sync-projects.sh --validate
```

### Verificación final

```bash
curl -I https://micliente-sta.tudominio.com
# Debe responder: HTTP/2 200 o 301 redirect a /web
```

---

## Troubleshooting SSL

### Síntoma: Certbot se cuelga indefinidamente al emitir un cert

`sync-projects.sh --ssl` ya hace esto automáticamente desde el commit de mejoras
SSL, pero si tenés que emitir un cert a mano y se cuelga, replicá los pasos:

```bash
# 1) Parar el contenedor de renovación automática (tiene el lock global)
docker compose stop certbot
docker ps -a --filter "name=certbot-run" -q | xargs -r docker rm -f
rm -f nginx/certbot/conf/.certbot.lock

# 2) Limpiar artefactos previos del dominio (live/archive/renewal)
docker compose run --rm --entrypoint sh certbot -c \
  "rm -rf /etc/letsencrypt/live/<dominio> \
           /etc/letsencrypt/archive/<dominio> \
           /etc/letsencrypt/renewal/<dominio>.conf"

# 3) Emitir con timeout (para no esperar una hora si algo está mal) y --verbose
timeout 120s docker compose run --rm --entrypoint certbot certbot certonly \
  --webroot --webroot-path=/var/www/certbot \
  --email "$(grep ^CERTBOT_EMAIL .env | cut -d= -f2)" \
  --agree-tos --no-eff-email --non-interactive --verbose \
  -d <dominio>

# 4) Si emitió OK, recargar nginx y levantar el certbot de renovación
docker compose exec nginx nginx -s reload
docker compose up -d certbot
```

> El cuelgue clásico se debe al **lock global de Certbot**
> (`/etc/letsencrypt/.certbot.lock`). El contenedor `odoo_certbot` corre
> renovaciones cada 12h y, si está activo cuando lanzas `certbot certonly`,
> el nuevo proceso espera el lock sin loguear nada. Por eso `sync-projects.sh`
> ahora pausa `odoo_certbot` antes del bucle y lo relevanta al terminar.

### Verificar que el challenge ACME llega bien al puerto 80

```bash
# Crear archivo de prueba en el directorio que sirve nginx
mkdir -p ./nginx/certbot/www/.well-known/acme-challenge
echo HOLA > ./nginx/certbot/www/.well-known/acme-challenge/test

# Probar desde Internet
curl -i http://<dominio>/.well-known/acme-challenge/test
# Esperado: HTTP/1.1 200 OK + "HOLA"
# Si da 404 o redirect → revisar nginx -T para ver qué vhost matchea
```

### Warning "ssl_stapling ignored, no OCSP responder URL"

Let's Encrypt dejó de embeber OCSP responder URL en sus certs (mayo 2025+).
La directiva `ssl_stapling on;` en nginx genera ruido en logs pero no rompe nada.
Las plantillas de este orquestador ya tienen esa directiva deshabilitada.

Si ves el warning en un vhost antiguo, comentá la línea:

```nginx
# ssl_stapling on; ssl_stapling_verify on;     ← comentar
```

---

## Eliminar un proyecto staging

> **Inverso de este flujo.** Detiene el contenedor y elimina **todo** lo que se
> creó: bases de datos, volumen Docker, backups, cert SSL, bloques de YAML/nginx
> y el directorio del proyecto. Operación irreversible (excepto lo que conserves
> con `--keep-*`).

```bash
# 1. Previsualizar (no toca nada)
./scripts/delete-project.sh micliente sta --dry-run

# 2. Ejecutar (pide confirmación: hay que escribir "BORRAR micliente_sta")
./scripts/delete-project.sh micliente sta

# Conservar DBs y/o backups si querés poder restaurar después
./scripts/delete-project.sh micliente sta --keep-db --keep-backups
```

**Qué hace internamente, en orden:**

1. Detiene y elimina el contenedor (`docker compose rm -f`).
2. Hace `dropdb --force` de cada DB con prefix `<proyecto>_<entorno>_*`.
3. Elimina el volumen Docker del proyecto (filestore + sessions).
4. Borra `./backups/<proyecto>/` (a menos que `--keep-backups`).
5. Borra `nginx/certbot/conf/{live,archive,renewal}/<dominio>`.
6. Quita el bloque del servicio + entrada de volumen en `docker-compose.yml`.
7. Quita el bloque `upstream` en `nginx/conf.d/00-upstreams.conf`.
8. Quita el bloque `server { }` (HTTP y HTTPS) en `nginx/conf.d/vhosts-projects.conf`.
9. Quita la línea de `projects-registry.conf` y la `DOMAIN_*` de `.env`.
10. Borra `projects/<proyecto>/odoo<ver>/<entorno>/`.
11. Recarga nginx con la nueva config.

**Opciones:**

| Flag                | Efecto                                                          |
|---------------------|-----------------------------------------------------------------|
| `--dry-run`         | Solo muestra el resumen; no toca nada.                         |
| `--keep-db`         | Conserva las bases de datos PostgreSQL.                        |
| `--keep-backups`    | Conserva `./backups/<proyecto>/`.                              |
| `--force`           | Salta la confirmación interactiva (uso en CI / scripts).       |

> Si más adelante querés reincorporar un proyecto eliminado con `--keep-db` o
> `--keep-backups`, basta con volver a agregar la línea en `projects-registry.conf`
> y correr `./scripts/sync-projects.sh --apply --ssl --start`. Las DBs/backups
> que quedaron en disco se quedan donde estaban y la nueva instancia los detecta.

