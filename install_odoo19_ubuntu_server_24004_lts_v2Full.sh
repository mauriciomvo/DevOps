#!/bin/bash

# --- CONFIGURAÇÕES ---
DOMAIN="odoo.lumiartecnologia.com.br"
EMAIL="suporte@lumiartecnologia.com.br"
ADMIN_PASS="SuaSenhaMestraSegura" # Senha para criar/gerenciar bancos

echo "--- Iniciando Instalação do Odoo 19 (Ubuntu 24.04 LTS) ---"

# 1. Atualização e Dependências
apt update && apt upgrade -y
apt install -y git python3-pip python3-dev python3-venv \
    libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev \
    libldap2-dev build-essential libssl-dev libffi-dev \
    libjpeg-dev libpq-dev liblcms2-dev libwebp-dev \
    node-less npm xfonts-75dpi xfonts-base postgresql nginx certbot python3-certbot-nginx

# 2. Configuração de Usuário e Pastas
useradd -m -d /opt/odoo -U -r -s /bin/bash odoo
mkdir -p /var/log/odoo
mkdir -p /opt/odoo/backups
chown odoo:odoo /var/log/odoo /opt/odoo/backups

# 3. Banco de Dados
sudo -u postgres createuser -s odoo

# 4. Clonar Odoo 19 e Configurar VENV (Correção de Permissões inclusa)
git clone https://www.github.com/odoo/odoo --depth 1 --branch 19.0 /opt/odoo/odoo-server
chown -R odoo:odoo /opt/odoo

# Instalação Python dentro do VENV como usuário odoo para evitar conflitos
sudo -u odoo bash << EOF
python3 -m venv /opt/odoo/odoo-venv
source /opt/odoo/odoo-venv/bin/activate
pip install --upgrade pip
pip install -r /opt/odoo/odoo-server/requirements.txt
EOF

# 5. Configuração do Odoo (/etc/odoo.conf)
cat <<EOF > /etc/odoo.conf
[options]
admin_passwd = $ADMIN_PASS
db_host = False
db_port = False
db_user = odoo
db_password = False
addons_path = /opt/odoo/odoo-server/addons
logfile = /var/log/odoo/odoo.log
proxy_mode = True
EOF
chown odoo:odoo /etc/odoo.conf

# 6. Criação do Serviço Systemd
cat <<EOF > /etc/systemd/system/odoo.service
[Unit]
Description=Odoo19
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=odoo
User=odoo
Group=odoo
ExecStart=/opt/odoo/odoo-venv/bin/python3 /opt/odoo/odoo-server/odoo-bin -c /etc/odoo.conf

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now odoo

# 7. Nginx Proxy Reverso
cat <<EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    location / {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8069;
    }
}
EOF

ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# 8. SSL Automático (Necessário DNS estar apontado)
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "--- INSTALAÇÃO FINALIZADA ---"
echo "Acesse: https://$DOMAIN"
