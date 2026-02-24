#!/bin/bash

# --- CONFIGURAÇÕES ---
BACKUP_DIR="/opt/odoo/backups"
ODOO_DATA_DIR="/opt/odoo/.local/share/Odoo/filestore"
DB_NAME="odoo_lumiar" # Ajuste para o nome do banco criado na web
DATE=$(date +%Y-%m-%d_%H%M%S)
TEMP_DIR="/tmp/odoo_backup_$DATE"

FINAL_ZIP="$BACKUP_DIR/full_backup_${DB_NAME}_$DATE.tar.gz"

echo "--- Iniciando Backup Completo ---"

# 1. Estrutura temporária
mkdir -p $TEMP_DIR/db
mkdir -p $TEMP_DIR/filestore

# 2. Exportar Banco
sudo -u postgres pg_dump $DB_NAME > $TEMP_DIR/db/dump.sql

# 3. Copiar Filestore (Anexos e Fotos)
if [ -d "$ODOO_DATA_DIR" ]; then
    cp -r $ODOO_DATA_DIR $TEMP_DIR/filestore/
fi

# 4. Compactar tudo
tar -czf $FINAL_ZIP -C $TEMP_DIR .

# 5. Limpeza e Permissões
rm -rf $TEMP_DIR
chown odoo:odoo $FINAL_ZIP

# 6. Retenção (Remove arquivos com mais de 15 dias)
find $BACKUP_DIR -type f -mtime +15 -name "full_backup_*.tar.gz" -exec rm {} \;

echo "Backup finalizado: $FINAL_ZIP"
