# Proyecto: MICLIENTE

**Versión Odoo:** 14.0  
**Entorno:** prod  
**Contenedor:** `odoo14_micliente_prod`  
**DB prefix:** `micliente_prod_*`  

## Addons personalizados

Colocar los módulos en:
```
projects/micliente/odoo14/prod/addons/
```

## Comandos rápidos

```bash
# Ver logs
./scripts/ops.sh logs odoo14_micliente_prod 200

# Actualizar un módulo
./scripts/ops.sh module odoo14_micliente_prod micliente_prod_principal mi_modulo update

# Backup (DB + filestore → ./backups/micliente/)
./scripts/ops.sh backup micliente odoo14_micliente_prod micliente_prod_principal

# Listar backups disponibles
./scripts/ops.sh list-backups micliente

# Restaurar (auto-detecta filestore por timestamp)
./scripts/ops.sh restore odoo14_micliente_prod micliente_prod_copia \
  micliente/db/<TIMESTAMP>_micliente_prod_principal.sql.gz

# Reiniciar
docker compose restart odoo14_micliente_prod
```
