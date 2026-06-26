# 03 — Módulos Personalizados (Addons)

> **Objetivo:** Entender la arquitectura de addons de la plataforma:  
> dónde vive cada tipo de módulo, cómo montarlos y cómo instalarlos en Odoo.

---

## Arquitectura de addons

Cada contenedor Odoo carga módulos desde **cuatro fuentes**, en orden de prioridad
(los módulos más a la derecha sobreescriben a los de la izquierda si coincide el nombre):

```
core community  →  enterprise  →  shared-addons  →  extra-addons (proyecto)
    (menor)                                              (mayor prioridad)
```

| Mount en contenedor   | Fuente en host                                         | Propósito                                       |
|-----------------------|--------------------------------------------------------|-------------------------------------------------|
| `/mnt/enterprise`     | `enterprise/odoo{VERSION}/`                            | Addons de Odoo Enterprise (por versión)         |
| `/mnt/shared-addons`  | `shared-addons/{VERSION}/`                             | Módulos compartidos entre proyectos (por versión) |
| `/mnt/extra-addons`   | `projects/{proyecto}/odoo{ver}/{entorno}/addons/`      | Módulos exclusivos del proyecto/entorno         |

Configurado en `odoo.conf` de cada proyecto:

```ini
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons,/mnt/extra-addons
```

---

## `shared-addons/{VERSION}/` — Módulos compartidos entre proyectos (por versión)

Para módulos que usan **varios proyectos** (localización peruana, MercadoLibre,
conectores de biometría, etc.). La carpeta se separa por versión de Odoo porque
los módulos suelen ser incompatibles entre versiones (cambios en la API, ORM, etc.).

Cada contenedor monta **solo su versión** en `/mnt/shared-addons`:

```
shared-addons/
└── 14/                     ← shared-addons para Odoo 14
    ├── al_l10n_pe_edi/
    ├── EXTENDRIX_extra_addons/
    └── mercadolibre/
```

> Si un proyecto Odoo 14 mira `/mnt/shared-addons/`, ve **solo** los addons
> que están en `shared-addons/14/`.

### Agregar un módulo compartido (a una versión específica)

```bash
cd /opt/odoo-infra/shared-addons/14      # según la versión

# Clonar el módulo en la rama correspondiente a la versión de Odoo
git clone -b 14.0 https://github.com/Extendrix/al_l10n_pe_edi.git

# El módulo ya está disponible en todos los contenedores Odoo 14 (sin reiniciar)
# Actualizar lista de aplicaciones en Odoo:
# Menú → Aplicaciones → Actualizar lista de aplicaciones
```

### Compartir el mismo módulo entre versiones

Si el módulo es compatible con varias versiones, copialo (o symlink):

```bash
# Opción A: clonar la rama en su versión
git clone -b 14.0 https://github.com/Extendrix/al_l10n_pe_edi.git shared-addons/14/al_l10n_pe_edi

# Opción B: módulo idéntico para varias versiones — symlink relativo
cd shared-addons/14
ln -s ../14/al_l10n_pe_edi .
```

### Actualizar un módulo compartido

```bash
cd /opt/odoo-infra/shared-addons/14/al_l10n_pe_edi
git pull origin 14.0

# Luego actualizar el módulo en cada DB Odoo 14 que lo use:
./scripts/ops.sh module odoo14_merida_sta merida_sta_principal al_l10n_pe_edi update
```

### Migración desde el esquema flat (legacy)

Si venís de un `shared-addons/` plano (sin subdirs por versión), seguí estos
tres pasos en orden:

**1) Crear los subdirs y duplicar los addons existentes:**

```bash
cd /opt/odoo-infra
mkdir -p shared-addons/14      # ajusta según tus versiones

# Duplicar cada addon top-level a las versiones que lo van a usar
for d in shared-addons/*/; do
    name=$(basename "$d")
    [[ "$name" =~ ^[0-9]+$ ]] && continue       # saltar los dirs que ya son versiones
    cp -r "$d" shared-addons/14/
done
```

**2) Actualizar el bind-mount de cada servicio en `docker-compose.yml`:**

```bash
# Reemplaza `./shared-addons:` por `./shared-addons/<VERSION>:` en cada
# bloque de servicio Odoo, deduciendo la versión del nombre del contenedor
# (odoo14_*, etc.). Crea un backup .bak antes.

python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path("docker-compose.yml")
p.with_suffix(".yml.bak").write_text(p.read_text())
txt = p.read_text()

def replace_block(m):
    block = m.group(0)
    svc = re.search(r"^  (odoo(\d+))_[a-z0-9_]+:", block, flags=re.M)
    if not svc:
        return block
    version = svc.group(2)
    return re.sub(
        r"- \./shared-addons:/mnt/shared-addons:ro",
        f"- ./shared-addons/{version}:/mnt/shared-addons:ro",
        block,
    )

txt = re.sub(
    r"(?ms)^  odoo\d+_[a-z0-9_]+:\s*\n(?:    .+\n)+",
    replace_block, txt,
)
p.write_text(txt)
print("docker-compose.yml actualizado (.bak guardado)")
PYEOF
```

**3) Recrear los contenedores para tomar el nuevo bind-mount:**

```bash
docker compose up -d --force-recreate
./scripts/ops.sh health
```

> El paso 2 NO tiene rollback automático más allá del `.bak`. Si algo sale mal:
> `mv docker-compose.yml.bak docker-compose.yml && docker compose up -d`.

---

## `enterprise/odoo{VERSION}/` — Addons de Odoo Enterprise

Si el cliente tiene licencia Enterprise, coloca los addons aquí, organizados por versión:

```
enterprise/
└── odoo14/                 ← addons enterprise para Odoo 14
    ├── account_accountant/
    ├── sale_subscription/
    └── ...
```

> Si en el futuro un servidor agregara Odoo 16, se crearía un `enterprise/odoo16/`
> paralelo. Este orquestador hoy solo apunta a Odoo 14 staging.

### Configurar enterprise para una versión

```bash
# Clonar el repositorio enterprise de Odoo (requiere acceso con licencia)
cd /opt/odoo-infra/enterprise
git clone https://github.com/odoo/enterprise.git odoo14 --branch 14.0 --depth 1

# Verificar que el contenedor lo ve
docker exec odoo14_merida_sta ls /mnt/enterprise | head -10
```

> Si el proyecto no usa Enterprise, el directorio `enterprise/odoo14/` existe pero vacío —
> no genera errores.

---

## `projects/{proyecto}/addons/` — Módulos exclusivos del proyecto

Para módulos específicos de un cliente que **no se comparten** con otros proyectos:

```
projects/
└── merida/
    └── odoo14/
        └── sta/
            └── addons/
                ├── account/
                └── merida_customizations/
```

### Agregar un módulo de proyecto

```bash
cd /opt/odoo-infra/projects/merida/odoo14/sta/addons/

# Opción A: clonar directamente
git clone https://github.com/Extendrix/mi_modulo_cliente.git

# Opción B: copiar desde otra ubicación
cp -r ~/desarrollo/mi_modulo_cliente .
```

---

## Seleccionar subdirectorios de un repositorio compartido

Si `shared-addons` tiene la estructura:

```
shared-addons/
└── EXTENDRIX_extra_addons/
    ├── account/               ← módulos de facturación (México, Perú, Chile)
    │   ├── EXTENDRIX_l10n_mx_qr/
    │   └── l10n_mx_edi_EXTENDRIX_complemento/
    └── tools/                 ← utilidades generales
        └── EXTENDRIX_licencia_perpetua/
```

Cada proyecto necesita solo ciertos subdirectorios. Como `odoo.conf` está en git y no debe
modificarse por servidor, la solución es `docker-compose.override.yml` (gitignored):

```bash
# En el servidor, crear el archivo de override (NUNCA commitear)
nano /opt/odoo-infra/docker-compose.override.yml
```

```yaml
# docker-compose.override.yml — específico del servidor, NO al repositorio
services:
  odoo14_merida_sta:
    command: >
      odoo --config=/etc/odoo/odoo.conf
      --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/EXTENDRIX_extra_addons/tools,/mnt/extra-addons

  odoo14_merida_dev:
    command: >
      odoo --config=/etc/odoo/odoo.conf
      --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/EXTENDRIX_extra_addons/account,/mnt/extra-addons

  odoo14_merida_prod:
    command: >
      odoo --config=/etc/odoo/odoo.conf
      --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/EXTENDRIX_extra_addons/account,/mnt/shared-addons/EXTENDRIX_extra_addons/tools,/mnt/extra-addons
```

Docker Compose fusiona automáticamente `docker-compose.override.yml` con `docker-compose.yml`.
El `--addons-path` en CLI sobreescribe el del `odoo.conf`, así `git pull` funciona limpiamente.

Aplicar después de crear o modificar el override:

```bash
docker compose up -d --force-recreate odoo14_merida_sta
```

---

## Verificar que los módulos están disponibles en el contenedor

```bash
# Listar módulos en cada path
docker exec odoo14_merida_sta ls /mnt/extra-addons/
docker exec odoo14_merida_sta ls /mnt/shared-addons/
docker exec odoo14_merida_sta ls /mnt/enterprise/

# Verificar que odoo reconoce el módulo
docker exec odoo14_merida_sta python3 -c "
import odoo
odoo.tools.config['addons_path'] = '/mnt/enterprise,/mnt/shared-addons,/mnt/extra-addons'
from odoo.modules.module import get_modules
print([m for m in get_modules() if 'mi_modulo' in m])
"
```

---

## Instalar o actualizar módulos

### Desde la interfaz Odoo

1. **Menú → Aplicaciones → Actualizar lista de aplicaciones** (si el módulo es nuevo)
2. Quitar el filtro "Aplicaciones" para ver todos los módulos
3. Buscar el nombre del módulo → **Instalar**

### Desde terminal (sin detener Odoo)

```bash
# Instalar
./scripts/ops.sh module odoo14_merida_sta merida_sta_principal mi_modulo install

# Actualizar
./scripts/ops.sh module odoo14_merida_sta merida_sta_principal mi_modulo update
```

Ver la guía completa de actualización en **[04-actualizar-modulo.md](04-actualizar-modulo.md)**.

---

## Estructura recomendada de un módulo personalizado

```
mi_modulo/
├── __manifest__.py          ← nombre, versión, dependencias
├── __init__.py
├── models/
│   ├── __init__.py
│   └── mi_modelo.py
├── views/
│   └── mi_vista.xml
├── security/
│   ├── ir.model.access.csv
│   └── security.xml
├── data/
│   └── datos_iniciales.xml
├── static/
│   └── src/
└── README.md
```

---

## Control de versiones de addons

Recomendación por tipo de módulo:

| Tipo               | Estrategia de versiones                                         |
|--------------------|----------------------------------------------------------------|
| `shared-addons/`   | Cada módulo es un repo Git independiente; clonar con `git clone` |
| `enterprise/`      | Clonar el repo oficial Odoo Enterprise con la rama de versión  |
| `extra-addons/`    | Cada módulo es un repo Git; o incluir en el repo del proyecto  |

`.gitignore` recomendado:

```gitignore
.env
nginx/certbot/conf/
# Volumen central de backups (DB + filestore)
backups/
# Legacy: backups antiguos por proyecto
projects/*/backups/
projects/*/odoo*/*/addons/**/__pycache__/
projects/*/odoo*/*/addons/**/*.pyc
shared-addons/**/__pycache__/
shared-addons/**/*.pyc
enterprise/
```

> Los directorios `enterprise/` y los contenidos de `shared-addons/` y `extra-addons/`
> se gestionan con sus propios repositorios Git. Solo commitear el `.gitkeep` de cada directorio.
