# 02 — Agregar un Nuevo Proyecto de Staging

> **Objetivo:** Agregar una nueva instancia Odoo de **staging** (`_sta`).
> **Ejemplo práctico:** Agregar `odoo14_merida_sta` con dominio `merida-sta.odoo-rideco.mx`.
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
CERTBOT_EMAIL=support@extendrix.com      # usada por --ssl para emitir/renovar certs

# Una variable DOMAIN_ por cada instancia
# Formato: DOMAIN_<PROYECTO>_<ENTORNO>=<subdominio>
DOMAIN_MERIDA_STA=merida-sta.odoo-rideco.mx
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
merida:14:sta:merida-sta.odoo-rideco.mx:14020
```

> El puerto HTTP debe estar libre y respetar la convención de rangos
> (Odoo 14: `14010–14099`, incrementos de 10). Ver tabla más abajo.

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
# Si el proyecto es Odoo 14 y el módulo ya está en shared-addons/14/, ya está disponible.
# Para agregar un nuevo módulo compartido a una versión específica:
cd shared-addons/14/    # según la versión del proyecto
git clone -b 14.0 https://github.com/Extendrix/al_l10n_pe_edi.git
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
| Odoo 14      | 14010–14099     | HTTP + 1         | 14010, 14020, 14030...  |

> Las otras versiones compatibles siguen la convención `{ver}010–{ver}099`
> (incrementos de 10).
> El puerto de longpolling es siempre **puerto HTTP + 1** (ej: HTTP=14030 → LP=14031).

| Contenedor                  | HTTP host | Longpolling host |
|-----------------------------|-----------|------------------|
| odoo14_merida_prod          | 14010     | 14011            |
| odoo14_merida_sta           | 14020     | 14021            |
| odoo14_merida_dev           | 14030     | 14031            |
| odoo14_motomarket_prod      | 14040     | 14041            |

---

## Opción 2 — Configuración manual (paso a paso)

Para casos donde se necesita control total sobre cada archivo.

> Antes de empezar, agregá la variable del nuevo dominio en `.env` (igual que en el
> Paso 1 de la Opción 1). Sin eso, `setup-ssl.sh` no podrá renovar el certificado
> después y `ops.sh health` no listará el dominio.
>
> ```dotenv
> DOMAIN_MERIDA_STA=merida-sta.odoo-rideco.mx
> ```

### PARTE A — Estructura de directorios

```bash
PROYECTO="merida"
VERSION="odoo14"
ENTORNO="sta"

mkdir -p projects/${PROYECTO}/${VERSION}/${ENTORNO}/config
mkdir -p projects/${PROYECTO}/${VERSION}/${ENTORNO}/addons

# Volumen central de backups (compartido entre todos los proyectos)
mkdir -p backups/${PROYECTO}/db
mkdir -p backups/${PROYECTO}/filestore
```

### PARTE B — Archivo `odoo.conf`

```bash
./scripts/new-project.sh merida 14 sta 14020
```

El archivo generado ya incluye los paths correctos. Verifica los valores críticos:

```ini
# Debe estar vacío (no 127.0.0.1) para que nginx pueda conectar vía red Docker
http_interface =

# Debe incluir enterprise y shared-addons
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons,/mnt/extra-addons

# Listado de bases de datos deshabilitado (seguridad). El gestor web no lista DBs.
list_db = False
```

> La master password (`admin_passwd`) **no** está en el `odoo.conf`: la inyecta
> el wrapper `odoo-entrypoint.sh` en un config de runtime desde
> `ODOO_MASTER_PASSWD` (`.env`). Odoo 14 no acepta `--admin-passwd` por CLI.
> Asegúrate de tener esa variable definida o el contenedor no arrancará.

### PARTE C — Servicio en `docker-compose.yml`

```yaml
  odoo14_merida_sta:
    image: odoo:14.0
    container_name: odoo14_merida_sta
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
      - odoo14_merida_sta_data:/var/lib/odoo
      - ./scripts/odoo-entrypoint.sh:/odoo-entrypoint.sh:ro
      - ./projects/merida/odoo14/sta/config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./projects/merida/odoo14/sta/addons:/mnt/extra-addons
      - ./shared-addons/14:/mnt/shared-addons:ro
      - ./enterprise/odoo14:/mnt/enterprise:ro
      - ./backups:/backups
    ports:
      - "127.0.0.1:14020:8069"
      - "127.0.0.1:14021:8072"
    networks:
      - odoo_net
    # El wrapper inyecta admin_passwd (Odoo 14 no soporta --admin-passwd por CLI)
    entrypoint: ["/bin/sh", "/odoo-entrypoint.sh"]
    command: ["odoo", "--config=/etc/odoo/odoo.conf"]
    mem_limit: 3g
    cpus: 2.0
    healthcheck:
      test: ["CMD-SHELL", "curl -s -o /dev/null -w '%{http_code}' http://localhost:8069/ | grep -qE '^[23]'"]
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
  odoo14_merida_sta_data:
    name: odoo14_merida_sta_data
```

### PARTE D — Upstream en Nginx

Abrir `nginx/conf.d/00-upstreams.conf` y agregar antes del marcador `__SYNC_UPSTREAMS_INSERT__`:

```nginx
# --- ODOO 14 | MERIDA | STAGING ---
upstream up_merida_sta_http {
    server odoo14_merida_sta:8069 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 16;
}
upstream up_merida_sta_lp {
    server odoo14_merida_sta:8072 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 8;
}
```

### PARTE E — Vhost en Nginx

Abrir `nginx/conf.d/vhosts-projects.conf` y agregar antes del marcador `__SYNC_VHOSTS_INSERT__`:

```nginx
server {
    listen 80;
    server_name merida-sta.odoo-rideco.mx;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl; http2 on;
    server_name merida-sta.odoo-rideco.mx;

    ssl_certificate     /etc/letsencrypt/live/merida-sta.odoo-rideco.mx/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/merida-sta.odoo-rideco.mx/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/merida-sta.odoo-rideco.mx/chain.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL_merida_sta:10m;
    ssl_session_timeout 1d; ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=63072000" always;
    # ssl_stapling deshabilitado: Let's Encrypt ya no embebe OCSP responder URL.
    resolver 8.8.8.8 valid=300s; resolver_timeout 5s;
    client_max_body_size 200m;

    location ~* /web/login {
        limit_req zone=odoo_login burst=3 nodelay;
        proxy_pass http://up_merida_sta_http;
        include /etc/nginx/conf.d/odoo-proxy-params.conf;
    }
    location /websocket {
        proxy_pass http://up_merida_sta_lp;
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
        proxy_pass http://up_merida_sta_lp;
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
        proxy_pass http://up_merida_sta_http;
        include /etc/nginx/conf.d/odoo-proxy-params.conf;
        expires 30d; add_header Cache-Control "public, immutable"; access_log off;
    }
    location / {
        proxy_pass http://up_merida_sta_http;
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
  -d merida-sta.odoo-rideco.mx
docker compose exec nginx nginx -s reload
```

### PARTE G — Levantar el contenedor

```bash
# Levantar Odoo primero, luego recargar nginx
docker compose up -d odoo14_merida_sta
docker compose restart nginx

# Verificar estado
./scripts/ops.sh health
./scripts/sync-projects.sh --validate
```

### Verificación final

```bash
curl -I https://merida-sta.odoo-rideco.mx
# Debe responder: HTTP/2 200 o 301 redirect a /web
```

---

## SSL con certificado wildcard (reutilizar el de producción)

Si ya tenés un certificado **wildcard** (`*.odoo-rideco.mx`), no hace falta emitir
un cert nuevo por cada subdominio: el wildcard ya lo cubre. El script
`wildcard-ssl.sh` puebla `live/<subdominio>/` reutilizando ese cert, y el vhost
(que apunta a `live/<subdominio>/`) lo toma sin cambios.

Hay dos modos:

| Modo        | Cuándo                                                        | Renovación |
|-------------|--------------------------------------------------------------|------------|
| **symlink** | El wildcard ya vive en el volumen certbot de este servidor   | Automática (el subdominio sigue al wildcard) |
| **copia**   | El wildcard está en otro servidor / backup / ruta del host   | Manual (re-copiar al renovar) |

```bash
# Symlink al wildcard local (autodetecta el lineage que cubre el subdominio):
./scripts/wildcard-ssl.sh merida.odoo-rideco.mx

# Indicando explícitamente el lineage wildcard del volumen:
./scripts/wildcard-ssl.sh merida.odoo-rideco.mx --wildcard odoo-rideco.mx

# Copia desde un directorio externo con fullchain.pem/privkey.pem/chain.pem:
./scripts/wildcard-ssl.sh merida.odoo-rideco.mx --from /ruta/al/wildcard

# Copia indicando archivos sueltos:
./scripts/wildcard-ssl.sh merida.odoo-rideco.mx \
    --fullchain /ruta/fullchain.pem --privkey /ruta/privkey.pem
```

> El script verifica que el SAN del cert realmente cubra el subdominio, opera el
> filesystem de certs dentro del contenedor `certbot` (sin problemas de permisos)
> y recarga nginx tras validar la config (`nginx -t`).

**Integración automática con `sync-projects.sh`:** al correr `--ssl`, si existe un
wildcard en el volumen que cubre el dominio, se reutiliza (symlink) en lugar de
emitir un cert individual — ahorra rate-limits de Let's Encrypt y evita la
validación ACME http-01. Para forzar la emisión individual aunque haya wildcard:

```bash
./scripts/sync-projects.sh --ssl --no-wildcard
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
./scripts/delete-project.sh merida sta --dry-run

# 2. Ejecutar (pide confirmación: hay que escribir "BORRAR merida_sta")
./scripts/delete-project.sh merida sta

# Conservar DBs y/o backups si querés poder restaurar después
./scripts/delete-project.sh merida sta --keep-db --keep-backups
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

