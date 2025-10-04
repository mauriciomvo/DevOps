#!/bin/bash

# ==============================================================================
# SCRIPT DE INSTALAÇÃO DO ODOO 18 (Source Install) NO ALMALINUX 9
# Autor: MAURICIO VALERINI
# Data: Outubro 2025
# ==============================================================================

# Variáveis de Configuração
ODOO_USER="odoo18"
ODOO_HOME="/opt/$ODOO_USER"
ODOO_CONF="/etc/$ODOO_USER.conf"
ODOO_PORT="8069"
ODOO_LONGPOLLING_PORT="8072"
ODOO_LOG_DIR="/var/log/$ODOO_USER"
PYTHON_VERSION="python3.11" # Requerido pelo Odoo 18 (mínimo 3.10)
WKHTMLTOX_VERSION="0.12.6.1-2"
WKHTMLTOX_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/wkhtmltox-${WKHTMLTOX_VERSION}.almalinux9.x86_64.rpm"

# Pedir Senha Mestra do Odoo
read -sp "Defina a Senha Mestra do Banco de Dados Odoo: " ADMIN_PASSWD
echo
if [ -z "$ADMIN_PASSWD" ]; then
    echo "Erro: A Senha Mestra não pode estar vazia."
    exit 1
fi

echo "--- 1. Atualizando o Sistema e Instalando Dependências Essenciais ---"
sudo dnf update -y
# Instala EPEL, Python 3.11 e dependências de compilação (incluindo PostgreSQL devel para psycopg2)
sudo dnf install -y epel-release
sudo dnf install -y git wget python3-pip python3-devel gcc bzip2-devel openldap-devel libxslt-devel \
    libjpeg-devel redhat-rpm-config xorg-x11-fonts-75dpi xorg-x11-fonts-Type1 \
    postgresql-devel $PYTHON_VERSION ${PYTHON_VERSION}-devel

echo "--- 2. Instalando o WKHTMLTOPDF ---"
WKHTMLTOX_RPM="wkhtmltox.rpm"
wget "$WKHTMLTOX_URL" -O "$WKHTMLTOX_RPM"
# O DNF resolve as dependências do pacote RPM localmente
sudo dnf install -y "./$WKHTMLTOX_RPM"
rm -f "$WKHTMLTOX_RPM"

echo "--- 3. Configurando o PostgreSQL ---"
sudo systemctl status postgresql &>/dev/null || {
    echo "Inicializando o banco de dados..."
    sudo postgresql-setup --initdb
}
sudo systemctl enable postgresql
sudo systemctl start postgresql

echo "Criando usuário de banco de dados '$ODOO_USER'..."
# -s concede privilégios de superusuário DB (necessário para Odoo criar bancos)
sudo su - postgres -c "createuser -s $ODOO_USER"

echo "--- 4. Configurando Usuário e Ambiente Odoo ---"
# Cria usuário de sistema e diretórios
sudo useradd -m -d $ODOO_HOME -U -r -s /bin/bash $ODOO_USER
sudo mkdir -p $ODOO_LOG_DIR
sudo chown $ODOO_USER:$ODOO_USER $ODOO_LOG_DIR

# Troca para o usuário Odoo para baixar e configurar
sudo su - $ODOO_USER <<EOF
    echo "Baixando código-fonte do Odoo 18..."
    git clone https://www.github.com/odoo/odoo --depth 1 --branch master $ODOO_HOME/odoo

    echo "Criando e ativando ambiente virtual com $PYTHON_VERSION..."
    $PYTHON_VERSION -m venv $ODOO_HOME/${ODOO_USER}-venv
    source $ODOO_HOME/${ODOO_USER}-venv/bin/activate
    
    echo "Atualizando PIP..."
    pip install --upgrade pip

    echo "Instalando dependências do Python..."
    # 'wheel' é bom, 'requirements.txt' instala o psycopg2 e todas as outras libs
    pip install wheel
    pip install -r $ODOO_HOME/odoo/requirements.txt
    
    echo "Criando diretório para custom addons..."
    mkdir $ODOO_HOME/custom-addons
    
    echo "Saindo do ambiente virtual e do usuário $ODOO_USER..."
    deactivate
EOF

echo "--- 5. Criando Arquivo de Configuração do Odoo ($ODOO_CONF) ---"
sudo tee $ODOO_CONF > /dev/null <<EOL
[options]
; Senha Mestra para gerenciar bancos (MUITO IMPORTANTE!)
admin_passwd = $ADMIN_PASSWD
db_host = False
db_port = False
db_user = $ODOO_USER
db_password = False
addons_path = $ODOO_HOME/odoo/addons,$ODOO_HOME/custom-addons
proxy_mode = True
xmlrpc_port = $ODOO_PORT
longpolling_port = $ODOO_LONGPOLLING_PORT
log_handler = ['[:INFO]']
logrotate = True
logfile = $ODOO_LOG_DIR/$ODOO_USER.log
EOL

# Define permissões seguras para o arquivo de configuração
sudo chown $ODOO_USER:$ODOO_USER $ODOO_CONF
sudo chmod 640 $ODOO_CONF

echo "--- 6. Criando Serviço Systemd ---"
sudo tee /etc/systemd/system/$ODOO_USER.service > /dev/null <<EOL
[Unit]
Description=Odoo18 Service
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=$ODOO_USER
PermissionsStartOnly=true
User=$ODOO_USER
Group=$ODOO_USER
ExecStart=$ODOO_HOME/${ODOO_USER}-venv/bin/python3 $ODOO_HOME/odoo/odoo-bin -c $ODOO_CONF
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOL

echo "Recarregando e iniciando o serviço $ODOO_USER..."
sudo systemctl daemon-reload
sudo systemctl enable --now $ODOO_USER

echo "--- 7. Configurando Firewall (Firewalld e SELinux) ---"
# Instala o semanage (se necessário) para configurar o SELinux
sudo dnf install -y policycoreutils-python-utils

# Permite que o Nginx (httpd) se conecte à rede
sudo setsebool -P httpd_can_network_connect 1

# Adiciona as portas 8069 e 8072 ao contexto do SELinux
sudo semanage port -a -t http_port_t -p tcp $ODOO_PORT 2>/dev/null
sudo semanage port -a -t http_port_t -p tcp $ODOO_LONGPOLLING_PORT 2>/dev/null

# Configura as portas HTTP/HTTPS para o Nginx
sudo firewall-cmd --add-service={http,https} --permanent
# Remove a porta direta do Odoo (segurança)
sudo firewall-cmd --remove-port=${ODOO_PORT}/tcp --permanent 2>/dev/null
sudo firewall-cmd --reload

echo "--- 8. Verificação Final ---"
sudo systemctl status $ODOO_USER | grep Active

echo "=========================================================="
echo "INSTALAÇÃO DO ODOO 18 CONCLUÍDA!"
echo "Acesse http://SEU_IP_OU_DOMINIO na porta 80 após configurar o Nginx."
echo "=========================================================="
