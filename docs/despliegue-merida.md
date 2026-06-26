# Despliegue del proyecto `merida` (Odoo 14 · producción)

Guía paso a paso para desplegar la instancia **merida** reutilizando el
certificado **SSL wildcard** de producción (`*.odoo-rideco.mx`), que cubre el
subdominio `merida.odoo-rideco.mx` sin necesidad de emitir un cert nuevo.

## Datos del proyecto

| Campo               | Valor                                    |
|---------------------|------------------------------------------|
| Proyecto            | `merida`                                 |
| Versión Odoo        | `14`                                     |
| Entorno             | `prod`                                   |
| Contenedor          | `odoo14_merida_prod`                     |
| Dominio             | `https://merida.odoo-rideco.mx`          |
| Puerto HTTP (host)  | `14010` (longpolling `14011`)            |
| Prefijo de DB       | `merida_prod_*`                          |
| Certificado         | Wildcard `*.odoo-rideco.mx` (copiado de producción) |

**Certificados de producción** (en este servidor, formato acme.sh):

```text
/opt/certificados/odoo-rideco.mx.cer      ← certificado del dominio (leaf)
/opt/certificados/odoo-rideco.mx.key      ← clave privada
/opt/certificados/odoo-rideco.mx_ca.cer   ← cadena CA (intermediates)
```

---

## Prerequisitos

- Estás en el servidor, dentro del directorio del repo `odoo-infra`.
  En los comandos se asume `/opt/odoo-infra` — **ajustá la ruta a la real**:

  ```bash
  cd /opt/odoo-infra
  ```

- El `.env` ya tiene las variables globales del setup inicial
  (`POSTGRES_PASSWORD`, `ODOO_MASTER_PASSWD`, `CERTBOT_EMAIL`, etc.).
- El DNS de `merida.odoo-rideco.mx` apunta a la IP de este servidor
  (necesario para que el tráfico HTTPS llegue; **no** hace falta validación
  ACME porque reutilizamos el wildcard).
- La infraestructura base está levantada (`db`, `nginx`):

  ```bash
  docker compose ps
  ```

---

## Paso 1 — Registrar el proyecto

El repo ya trae la línea de `merida` en `projects-registry.conf`. Verificá que
esté presente (y ajustá el dominio/puerto si tu servidor lo requiere):

```text
# Formato: PROYECTO:VERSION:ENTORNO:DOMINIO:PUERTO_HTTP
merida:14:prod:merida.odoo-rideco.mx:14010
```

> El puerto `14010` respeta el rango reservado de Odoo 14 (`14010–14099`).
> Si ya hubiera otro proyecto Odoo 14 en `14010`, usá `14020`, `14030`, etc.

---

## Paso 2 — Aplicar el proyecto (estructura + nginx + contenedor)

Esto crea `projects/merida/odoo14/prod/`, el `odoo.conf`, inserta el servicio en
`docker-compose.yml`, el upstream y el vhost en nginx (apuntando a
`live/merida.odoo-rideco.mx/`), genera un cert **provisional autofirmado** para
que nginx arranque, y levanta el contenedor.

```bash
# Ver primero qué haría (dry-run, no toca nada)
./scripts/sync-projects.sh

# Aplicar y levantar el contenedor
./scripts/sync-projects.sh --apply --start
```

> **No uses `--ssl` en este proyecto.** `--ssl` intentaría emitir un certificado
> individual vía Let's Encrypt (ACME http-01). Acá reutilizamos el wildcard de
> producción en el Paso 3.

---

## Paso 3 — Instalar el SSL wildcard de producción (modo copia)

El script `wildcard-ssl.sh` copia el certificado al directorio que el vhost ya
espera (`live/merida.odoo-rideco.mx/`), reemplazando el provisional autofirmado.
Verifica que el SAN del cert cubra el subdominio y recarga nginx tras validar la
config.

```bash
# 3.1 — Confirmar que el cert es wildcard *.odoo-rideco.mx
openssl x509 -in /opt/certificados/odoo-rideco.mx.cer -noout -ext subjectAltName
# Debe listar:  DNS:*.odoo-rideco.mx

# 3.2 — Armar el bundle (fullchain = leaf + CA) en un directorio temporal
mkdir -p /tmp/wildcard-rideco
cat /opt/certificados/odoo-rideco.mx.cer \
    /opt/certificados/odoo-rideco.mx_ca.cer > /tmp/wildcard-rideco/fullchain.pem
cp  /opt/certificados/odoo-rideco.mx.key     /tmp/wildcard-rideco/privkey.pem
cp  /opt/certificados/odoo-rideco.mx_ca.cer  /tmp/wildcard-rideco/chain.pem

# 3.3 — Instalar el cert para el subdominio y recargar nginx
./scripts/wildcard-ssl.sh merida.odoo-rideco.mx --from /tmp/wildcard-rideco

# 3.4 — Borrar el bundle temporal (contiene la clave privada)
rm -rf /tmp/wildcard-rideco
```

El script mapea los archivos así dentro del volumen de certbot:

| Origen (`/tmp/wildcard-rideco/`) | Destino (`live/merida.odoo-rideco.mx/`) | Lo usa nginx en |
|----------------------------------|------------------------------------------|-----------------|
| `fullchain.pem`                  | `fullchain.pem`                          | `ssl_certificate` |
| `privkey.pem`                    | `privkey.pem` (chmod 600)                | `ssl_certificate_key` |
| `chain.pem`                      | `chain.pem`                              | `ssl_trusted_certificate` |

---

## Paso 4 — Verificación

```bash
# Estado del contenedor e infra
./scripts/ops.sh health
./scripts/sync-projects.sh --validate

# Logs del arranque de Odoo
./scripts/ops.sh logs odoo14_merida_prod 80

# Responde por HTTPS con el cert válido (no autofirmado)
curl -I https://merida.odoo-rideco.mx
# Esperado: HTTP/2 200  o  301/302 redirect a /web

# Inspeccionar el cert servido (emisor real, no "self-signed")
echo | openssl s_client -connect merida.odoo-rideco.mx:443 \
     -servername merida.odoo-rideco.mx 2>/dev/null \
     | openssl x509 -noout -issuer -subject -dates -ext subjectAltName
```

Si todo está OK, entrá a `https://merida.odoo-rideco.mx` y creá la base de datos
`merida_prod_principal` (el `dbfilter` es `^merida_prod_.*$`, y el master password
es el `ODOO_MASTER_PASSWD` del `.env`).

---

## Renovación del certificado

Esta instalación es por **copia** (snapshot): cuando el wildcard de producción se
renueve en `/opt/certificados/`, hay que **repetir el Paso 3** para actualizar la
copia del subdominio.

> **Tip (renovación automática):** si el wildcard estuviera en el volumen de
> certbot de este servidor (no en `/opt/certificados`), podrías usar el modo
> **symlink** —`./scripts/wildcard-ssl.sh merida.odoo-rideco.mx`— y el subdominio
> seguiría al wildcard sin re-copiar. Con certificados externos, el modo copia es
> el adecuado.

Para automatizar el refresco de la copia, podés programar el Paso 3 en `cron`
(p. ej. semanal), reusando el mismo comando `wildcard-ssl.sh --from`.

---

## Acceso por IP (antes de propagar el DNS)

Odoo escucha solo en `127.0.0.1:14010` del servidor (no expuesto a internet), y
nginx enruta por `server_name`. Para probar `merida.odoo-rideco.mx` **antes** de
cambiar el DNS público, hacés que tu equipo resuelva el dominio a la IP de este
servidor con el archivo `hosts` local:

- **Linux / macOS:** `sudo nano /etc/hosts`
- **Windows:** abrir como administrador `C:\Windows\System32\drivers\etc\hosts`

Agregá esta línea (IP de este servidor):

```text
198.71.54.33   merida.odoo-rideco.mx
```

Ahora navegá a `https://merida.odoo-rideco.mx` desde ese equipo: llega a este
servidor y el certificado wildcard valida (cubre `*.odoo-rideco.mx`). **Quitá la
línea** cuando el DNS público ya apunte acá.

> Alternativa por túnel SSH (sin tocar `hosts`), accediendo directo a Odoo:
> ```bash
> ssh -L 8080:127.0.0.1:14010 root@198.71.54.33
> # luego abrí http://localhost:8080
> ```

---

## Cambiar el dominio del proyecto (ej. `merida2.odoo-rideco.mx`)

`change-domain.sh` reescribe el `server_name` del vhost, el `projects-registry.conf`
y el `.env`, y deja nginx apuntando al nuevo dominio. Como el nuevo subdominio
también está cubierto por el wildcard `*.odoo-rideco.mx`, se usa `--no-ssl` (para
**no** disparar la validación ACME de Let's Encrypt) y luego se reutiliza el
wildcard con `wildcard-ssl.sh`.

```bash
cd /opt/odoo-infra

# 1. Cambiar el dominio del proyecto (sin emitir cert ACME). El 3.º argumento es
#    el entorno: merida es 'prod'.
./scripts/change-domain.sh merida merida2.odoo-rideco.mx prod --no-ssl

# 2. Instalar el wildcard para el nuevo subdominio (modo copia, igual que el Paso 3)
mkdir -p /tmp/wildcard-rideco
cat /opt/certificados/odoo-rideco.mx.cer \
    /opt/certificados/odoo-rideco.mx_ca.cer > /tmp/wildcard-rideco/fullchain.pem
cp  /opt/certificados/odoo-rideco.mx.key     /tmp/wildcard-rideco/privkey.pem
cp  /opt/certificados/odoo-rideco.mx_ca.cer  /tmp/wildcard-rideco/chain.pem
./scripts/wildcard-ssl.sh merida2.odoo-rideco.mx --from /tmp/wildcard-rideco
rm -rf /tmp/wildcard-rideco

# 3. Apuntar el DNS de merida2.odoo-rideco.mx → 198.71.54.33 (registro A)
#    (o probarlo antes con el truco de /etc/hosts de la sección anterior)
```

Notas:

- **La base de datos no cambia.** El `dbfilter` sigue siendo `^merida_prod_.*$`;
  solo cambia el dominio por el que se accede.
- **Dominio viejo:** en modo reemplazo (por defecto) el vhost deja de responder a
  `merida.odoo-rideco.mx` y se elimina su cert. Si querés que el proyecto responda
  a **ambos** dominios, usá `--add` en lugar del reemplazo:
  ```bash
  ./scripts/change-domain.sh merida merida2.odoo-rideco.mx prod --add --no-ssl
  ./scripts/wildcard-ssl.sh merida2.odoo-rideco.mx --from /tmp/wildcard-rideco
  ```
- **Verificar antes de aplicar:** agregá `--dry-run` para ver el resumen sin tocar
  nada.

---

## Troubleshooting

- **`curl` muestra cert autofirmado / `nginx -t` falla:** el Paso 3 no corrió o
  falló. Revisá que existan los tres `.pem`:

  ```bash
  ls -l ./nginx/certbot/conf/live/merida.odoo-rideco.mx/
  docker compose exec nginx nginx -t
  docker compose exec nginx nginx -s reload
  ```

- **El script avisa que el cert no cubre el subdominio:** confirmá el SAN
  (Paso 3.1). Si no es wildcard `*.odoo-rideco.mx`, no sirve para este subdominio.

- **`No encontré un vhost que use live/merida.odoo-rideco.mx/`:** falta el Paso 2.
  Verificá la línea en `projects-registry.conf` y corré `--apply` de nuevo.

- **502 / Bad Gateway:** el contenedor de Odoo aún no terminó de arrancar.
  Esperá y revisá `./scripts/ops.sh logs odoo14_merida_prod 120`.

- **`odoo: error: no such option: --admin-passwd` (crash loop):** el bloque del
  servicio quedó con la sintaxis vieja. Odoo 14 no acepta `--admin-passwd` por
  CLI: lo inyecta el wrapper `odoo-entrypoint.sh`. Asegurate de que el servicio
  en `docker-compose.yml` tenga el wrapper y el command sin ese flag:

  ```yaml
      entrypoint: ["/bin/sh", "/odoo-entrypoint.sh"]
      volumes:
        - ./scripts/odoo-entrypoint.sh:/odoo-entrypoint.sh:ro
        # ... (resto de volumes)
      command: ["odoo", "--config=/etc/odoo/odoo.conf"]
  ```

  Luego recreá el contenedor:

  ```bash
  docker compose up -d --force-recreate odoo14_merida_prod
  ```

---

## Resumen de comandos

```bash
cd /opt/odoo-infra

# 1. Registrar (la línea de merida ya viene en projects-registry.conf;
#    verificá que esté presente)
grep -q '^merida:14:prod:' projects-registry.conf \
  || echo 'merida:14:prod:merida.odoo-rideco.mx:14010' >> projects-registry.conf

# 2. Aplicar + levantar
./scripts/sync-projects.sh --apply --start

# 3. Instalar SSL wildcard (copia de producción)
mkdir -p /tmp/wildcard-rideco
cat /opt/certificados/odoo-rideco.mx.cer /opt/certificados/odoo-rideco.mx_ca.cer > /tmp/wildcard-rideco/fullchain.pem
cp  /opt/certificados/odoo-rideco.mx.key /tmp/wildcard-rideco/privkey.pem
cp  /opt/certificados/odoo-rideco.mx_ca.cer /tmp/wildcard-rideco/chain.pem
./scripts/wildcard-ssl.sh merida.odoo-rideco.mx --from /tmp/wildcard-rideco
rm -rf /tmp/wildcard-rideco

# 4. Verificar
./scripts/sync-projects.sh --validate
curl -I https://merida.odoo-rideco.mx
```
