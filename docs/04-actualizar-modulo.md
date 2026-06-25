# 04 — Actualizar Módulos y Cambios en Modelos por Terminal

> **Objetivo:** Aplicar cambios en código Python/XML de Odoo sin perder datos,  
> entender cuándo se necesita `--update` vs reiniciar vs scaffolding.

---

## Cuándo necesitas qué acción

| Tipo de cambio | Qué hacer |
|---|---|
| Solo vistas XML (sin campos nuevos) | Actualizar módulo vía UI o `--update` |
| Nuevo campo en modelo Python | `--update` del módulo (agrega columna en DB) |
| Campo modificado (tipo, required) | `--update` + posible migración manual |
| Campo eliminado de Python | Columna queda en DB (huérfana, no se borra automáticamente) |
| Nuevo módulo | Instalar vía UI o `--init` |
| Cambio en `security/ir.model.access.csv` | `--update` del módulo |
| Cambio en datos de `data/` XML | `--update` del módulo |
| Cambio en JS/OWL frontend | Reiniciar Odoo (o Ctrl+F5 en navegador) |
| Cambio en `__manifest__.py` (dependencias) | Reinstalar módulo |

---

## Método A — Actualizar módulo por terminal (RECOMENDADO)

El script `ops.sh` incluye el comando `module` para hacer todo en un solo paso:

```bash
# SINTAXIS:
./scripts/ops.sh module <contenedor> <base_de_datos> <modulo> <accion>

# ACCIONES DISPONIBLES: update | install | uninstall

# ─── Actualizar un módulo ──────────────────────────────────────────────────
./scripts/ops.sh module \
  odoo19_farmaniacos_sta \
  farmaniacos_sta_principal \
  account \
  update

# ─── Instalar un módulo nuevo ─────────────────────────────────────────────
./scripts/ops.sh module \
  odoo19_ml19_sta \
  ml19_sta_principal \
  OLANOIT_mi_modulo \
  install

# ─── Actualizar múltiples módulos a la vez ────────────────────────────────
./scripts/ops.sh module \
  odoo19_farmaniacos_sta \
  farmaniacos_sta_principal \
  "account,stock" \
  update

# ─── Actualizar TODOS los módulos instalados (usar con cuidado) ───────────
./scripts/ops.sh module \
  odoo19_farmaniacos_sta \
  farmaniacos_sta_principal \
  all \
  update
```

---

## Método B — Comando Docker directo

Si prefieres ejecutarlo manualmente sin el script:

```bash
# Formato del comando:
docker exec -it <contenedor> odoo \
  --config=/etc/odoo/odoo.conf \
  --database=<base_de_datos> \
  --update=<modulo> \
  --stop-after-init

# Ejemplo real:
docker exec -it odoo19_farmaniacos_sta odoo \
  --config=/etc/odoo/odoo.conf \
  --database=farmaniacos_sta_principal \
  --update=account \
  --stop-after-init
```

> ⚠️ **`--stop-after-init`** es crucial: le dice a Odoo que ejecute el update  
> y luego se detenga. Sin este flag, Odoo no sabe que es un comando de admin.

---

## Método C — Vía interfaz web de Odoo

1. Ir a **Menú → Ajustes → Aplicaciones**  
   (en modo debug: **Menú → Ajustes → Técnico → Módulos**)
2. Buscar el módulo por nombre
3. Clic en el módulo → botón **"Actualizar"**

Útil para cambios simples en vistas sin campos nuevos.

---

## Flujo completo: cambio en un modelo (nuevo campo)

**Escenario:** Agregaste `mi_campo = fields.Char(...)` a un modelo existente.

```bash
# 1. Editar el archivo Python en tu máquina de desarrollo
nano projects/farmaniacos/odoo19/sta/addons/account/models/mi_modelo.py

# 2. El contenedor ya ve el cambio porque el volumen es live.
#    No necesitas copiar nada.

# 3. Aplicar el cambio (agrega la columna en PostgreSQL)
./scripts/ops.sh module \
  odoo19_farmaniacos_sta \
  farmaniacos_sta_principal \
  account \
  update

# 4. Verificar que la columna fue creada en la DB
./scripts/ops.sh db-query \
  odoo19_farmaniacos_sta \
  farmaniacos_sta_principal \
  "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mi_tabla' ORDER BY ordinal_position;"
```

---

## Flujo completo: nuevo módulo desde cero

```bash
# 1. Crear la carpeta del módulo
mkdir -p projects/farmaniacos/odoo19/sta/addons/OLANOIT_nuevo_modulo

# 2. Crear __manifest__.py y __init__.py mínimos
cat > projects/farmaniacos/odoo19/sta/addons/OLANOIT_nuevo_modulo/__manifest__.py << 'EOF'
{
    'name': 'OLANOIT - Nuevo Módulo',
    'version': '19.0.1.0.0',
    'category': 'Customizations',
    'depends': ['base'],
    'installable': True,
    'auto_install': False,
}
EOF

cat > projects/farmaniacos/odoo19/sta/addons/OLANOIT_nuevo_modulo/__init__.py << 'EOF'
# -*- coding: utf-8 -*-
EOF

# 3. Actualizar lista de módulos disponibles en Odoo
#    (esto no instala, solo refresca la lista)
docker exec -it odoo19_farmaniacos_sta odoo \
  --config=/etc/odoo/odoo.conf \
  --database=farmaniacos_sta_principal \
  --update=base \
  --stop-after-init

# 4. Instalar el nuevo módulo
./scripts/ops.sh module \
  odoo19_farmaniacos_sta \
  farmaniacos_sta_principal \
  OLANOIT_nuevo_modulo \
  install
```

---

## Cómo reiniciar un contenedor Odoo

```bash
# Reiniciar sin borrar datos (el más común)
docker compose restart odoo19_farmaniacos_sta

# Detener y volver a levantar (más "limpio")
docker compose stop odoo19_farmaniacos_sta
docker compose start odoo19_farmaniacos_sta

# Ver si levantó bien
docker compose ps odoo19_farmaniacos_sta
./scripts/ops.sh logs odoo19_farmaniacos_sta 30
```

---

## Ver logs en tiempo real mientras aplicas cambios

```bash
# En una terminal: aplicar el update
./scripts/ops.sh module odoo19_farmaniacos_sta farmaniacos_sta_principal mi_modulo update

# En otra terminal: ver los logs en tiempo real
./scripts/ops.sh logs odoo19_farmaniacos_sta 0
# (0 = sin límite de líneas, solo lo nuevo)

# Filtrar solo los errores:
docker logs -f odoo19_farmaniacos_sta 2>&1 | grep -E "ERROR|WARNING|Traceback"
```

---

## Limpiar caché de assets (JS/CSS no actualiza)

Cuando los cambios en JS/OWL no se reflejan en el navegador:

```bash
# Opción 1 — desde la interfaz (modo debug)
# Ajustes → Técnico → Interfaz de Usuario → Assets → Limpiar caché

# Opción 2 — vía URL (modo debug activo)
# https://farmaniacos-sta.OLANOIT.work/web?debug=1
# Luego: Ajustes → Menú debug → "Regenerar activos del navegador"

# Opción 3 — borrar assets de la DB directamente
./scripts/ops.sh db-query \
  odoo19_farmaniacos_sta \
  farmaniacos_sta_principal \
  "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';"

# Después reiniciar Odoo
docker compose restart odoo19_farmaniacos_sta
```

---

## Errores comunes al actualizar módulos

**`Module not found: OLANOIT_mi_modulo`**
```bash
# El módulo no está en el addons_path
# Verificar que la carpeta existe y tiene __manifest__.py
ls projects/farmaniacos/odoo19/sta/addons/
docker exec odoo19_farmaniacos_sta ls /mnt/extra-addons/
```

**`Cannot install module: depends on X which is not installed`**
```bash
# Instalar primero la dependencia
./scripts/ops.sh module odoo19_farmaniacos_sta farmaniacos_sta_principal modulo_dependencia install
# Luego tu módulo
./scripts/ops.sh module odoo19_farmaniacos_sta farmaniacos_sta_principal mi_modulo install
```

**`column "mi_campo" of relation "mi_tabla" already exists`**
```bash
# PostgreSQL ya tiene esa columna pero Odoo no sabe (estado inconsistente).
# Opciones:
# 1. Borrar la columna manualmente y re-aplicar el update
./scripts/ops.sh db-query odoo19_farmaniacos_sta farmaniacos_sta_principal \
  "ALTER TABLE mi_tabla DROP COLUMN IF EXISTS mi_campo;"
# 2. Hacer el campo nullable si el tipo cambió
```

**`TransactionRollbackError` o `deadlock detected`**
```bash
# Hay una transacción abierta en la DB. Cerrar conexiones activas:
./scripts/ops.sh db-query odoo19_farmaniacos_sta farmaniacos_sta_principal \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='farmaniacos_sta_principal' AND pid <> pg_backend_pid();"
# Luego reintentar el update
```
