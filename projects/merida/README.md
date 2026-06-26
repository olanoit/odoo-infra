# Proyecto: MERIDA

**Versión Odoo:** 14.0  
**Entorno:** prod  
**Contenedor:** `odoo14_merida_prod`  
**DB prefix:** `merida_prod_*`  

## Addons personalizados

Colocar los módulos en:
```
projects/merida/odoo14/prod/addons/
```

## Comandos rápidos

```bash
# Ver logs
./scripts/ops.sh logs odoo14_merida_prod 200

# Actualizar un módulo
./scripts/ops.sh module odoo14_merida_prod merida_prod_principal mi_modulo update

# Backup (DB + filestore → ./backups/merida/)
./scripts/ops.sh backup merida odoo14_merida_prod merida_prod_principal

# Listar backups disponibles
./scripts/ops.sh list-backups merida

# Restaurar (auto-detecta filestore por timestamp)
./scripts/ops.sh restore odoo14_merida_prod merida_prod_copia \
  merida/db/<TIMESTAMP>_merida_prod_principal.sql.gz

# Reiniciar
docker compose restart odoo14_merida_prod
```
