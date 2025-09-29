#!/bin/bash

# --- Variáveis de Configuração ---
GLPI_VERSION="10.0.16" # Verifique a versão mais recente em https://github.com/glpi-project/glpi/releases
GLPI_DIR="/var/www/html/glpi"
TEMP_DIR="/tmp/glpi_install"
DB_NAME="glpi_db"
DB_USER="glpi_user"
# A senha do banco de dados será solicitada para maior segurança, ou defina aqui.

# --- Funções de Ajuda ---
echo_info() {
    echo -e "\n\e[1;34m[INFO]\e[0m $1"
}

echo_success() {
    echo -e "\n\e[1;32m[SUCESSO]\e[0m $1"
}

echo_error() {
    echo -e "\n\e[1;31m[ERRO]\e[0m $1"
    exit 1
}

# --- Solicitar Informações ao Usuário ---
read -p "Digite o NOME DO DOMÍNIO principal para o GLPI (ex: glpi.seusite.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    echo_error "O nome do domínio não pode ser vazio."
fi

read -p "Digite o ENDEREÇO DE E-MAIL para o Certbot (Let's Encrypt): " CERTBOT_EMAIL
if [ -z "$CERTBOT_EMAIL" ]; then
    echo_error "O e-mail não pode ser vazio."
fi

# Solicitar a senha do banco de dados de forma segura
read -s -p "Digite a SENHA do usuário root do MariaDB/MySQL (deixe vazio se não houver): " DB_ROOT_PASS
echo
read -s -p "Digite a SENHA para o novo usuário GLPI no banco de dados: " DB_PASS
echo
if [ -z "$DB_PASS" ]; then
    echo_error "A senha do banco de dados do GLPI não pode ser vazia."
fi

# --- 1. Preparação e Instalação de Pacotes ---

echo_info "Atualizando o sistema e instalando pacotes essenciais..."
sudo dnf update -y
sudo dnf install -y epel-release wget unzip policycoreutils-python-utils

echo_info "Instalando repositório Remi para PHP 8.2 (recomendado para GLPI 10)..."
sudo dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
sudo dnf module reset php -y
sudo dnf module enable php:remi-8.2 -y

echo_info "Instalando Nginx, MariaDB e PHP com extensões para GLPI..."
sudo dnf install -y nginx mariadb-server php-cli php-fpm php-mysqlnd php-json php-gmp php-mbstring php-curl php-gd php-intl php-xml php-ldap php-apcu php-zip

# --- 2. Configuração do MariaDB ---

echo_info "Iniciando e habilitando o MariaDB..."
sudo systemctl enable mariadb
sudo systemctl start mariadb

echo_info "Configurando o MariaDB e criando o banco de dados/usuário para o GLPI..."

# Script SQL para criação do banco e usuário
if [ -z "$DB_ROOT_PASS" ]; then
    MYSQL_CMD="sudo mysql"
else
    MYSQL_CMD="mysql -u root -p$DB_ROOT_PASS"
fi

$MYSQL_CMD <<EOF || echo_error "Falha ao executar comandos SQL. Verifique a senha root do MariaDB."
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echo_success "Banco de dados e usuário criados. DB: $DB_NAME, User: $DB_USER."

# --- 3. Instalação do GLPI ---

echo_info "Baixando e extraindo o GLPI $GLPI_VERSION..."
mkdir -p "$TEMP_DIR"
wget -O "$TEMP_DIR/glpi.tgz" "https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz" || echo_error "Falha ao baixar o GLPI."
sudo mkdir -p "$GLPI_DIR"
sudo tar -xzf "$TEMP_DIR/glpi.tgz" -C /var/www/html/
sudo mv /var/www/html/glpi-$GLPI_VERSION/* "$GLPI_DIR"/
sudo rmdir /var/www/html/glpi-$GLPI_VERSION

echo_info "Configurando permissões para o GLPI..."
# O usuário padrão do Nginx/PHP-FPM no Rocky/CentOS é 'nginx'
sudo chown -R nginx:nginx "$GLPI_DIR"
sudo chmod -R 755 "$GLPI_DIR"

# --- 4. Configuração do PHP-FPM ---

echo_info "Configurando o PHP-FPM..."
# Ajusta o usuário e grupo do PHP-FPM para 'nginx'
sudo sed -i 's/user = apache/user = nginx/' /etc/php-fpm.d/www.conf
sudo sed -i 's/group = apache/group = nginx/' /etc/php-fpm.d/www.conf
sudo sed -i 's/;listen.owner = nobody/listen.owner = nginx/' /etc/php-fpm.d/www.conf
sudo sed -i 's/;listen.group = nobody/listen.group = nginx/' /etc/php-fpm.d/www.conf

echo_info "Reiniciando e habilitando o PHP-FPM..."
sudo systemctl enable php-fpm
sudo systemctl restart php-fpm

# --- 5. Configuração do Nginx (Proxy Reverso) ---

echo_info "Criando arquivo de configuração do Nginx (Proxy Reverso)..."
NGINX_CONF="/etc/nginx/conf.d/$DOMAIN_NAME.conf"

# Configuração Nginx para GLPI (HTTP - será modificado pelo Certbot para HTTPS)
sudo tee "$NGINX_CONF" > /dev/null <<EOL
server {
    listen 80;
    server_name $DOMAIN_NAME;
    root $GLPI_DIR/public; # GLPI 10 usa o diretório 'public' como raiz

    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/www.sock; # Socket padrão do PHP-FPM no Rocky/CentOS
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout 300; # Aumenta o timeout para instalações longas
    }

    # Bloqueia acesso a arquivos e diretórios sensíveis
    location ~ /\. {
        deny all;
    }
}
EOL

echo_info "Testando e iniciando o Nginx..."
sudo nginx -t || echo_error "Erro na sintaxe da configuração do Nginx."
sudo systemctl enable nginx
sudo systemctl restart nginx

# --- 6. Configuração do Firewall (Firewalld) ---

echo_info "Configurando o Firewalld para permitir HTTP e HTTPS..."
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload

# --- 7. Instalação e Configuração do Certbot (SSL) ---

echo_info "Instalando Certbot e plugin Nginx..."
sudo dnf install -y certbot python3-certbot-nginx

echo_info "Executando o Certbot para obter o certificado SSL e configurar o Nginx para HTTPS. Isso é interativo."
echo "Certifique-se de que o DNS para $DOMAIN_NAME está apontando para este servidor."
echo "O Certbot solicitará que você concorde com os termos e, em seguida, obterá e instalará o certificado."
echo "Você deve ser solicitado a 'selecionar o domínio' ($DOMAIN_NAME) e 'redirecionar' o tráfego HTTP para HTTPS."
sleep 5 # Dá tempo para o usuário ler as instruções

# Executa o Certbot de forma interativa
sudo certbot --nginx -d "$DOMAIN_NAME" --agree-tos --redirect -m "$CERTBOT_EMAIL" --hsts --uir || echo_error "Falha ao obter/configurar o certificado SSL com o Certbot. Verifique o DNS e a configuração do Nginx."

echo_info "Verificando e configurando a renovação automática do Certbot..."
# O Certbot geralmente cria um timer para renovação.
sudo systemctl enable --now certbot-renew.timer

echo_success "Certificado SSL (Let's Encrypt) instalado e configurado!"

# --- 8. Configuração de Segurança (SELinux) ---

echo_info "Configurando o SELinux para permitir o funcionamento do Nginx e GLPI..."
# Permite ao httpd (Nginx) conectar-se à rede (essencial para proxy reverso ou conexões externas)
sudo setsebool -P httpd_can_network_connect on
# Define o contexto de segurança correto para os arquivos do GLPI
sudo chcon -R -t httpd_sys_rw_content_t "$GLPI_DIR/files"
sudo chcon -R -t httpd_sys_rw_content_t "$GLPI_DIR/config"
sudo chcon -R -t httpd_sys_rw_content_t "$GLPI_DIR/marketplace"
sudo chcon -R -t httpd_sys_rw_content_t "$GLPI_DIR/plugins"

echo_success "Instalação e configuração básica concluídas!"
echo "--------------------------------------------------------"
echo "PRÓXIMAS ETAPAS:"
echo "1. Abra seu navegador e acesse: https://$DOMAIN_NAME"
echo "2. Siga o assistente de instalação do GLPI."
echo "   - Para a etapa do banco de dados, use:"
echo "     - Servidor: localhost"
echo "     - Usuário: $DB_USER"
echo "     - Senha: $DB_PASS"
echo "     - Nome do BD: $DB_NAME"
echo "3. Depois de concluir a instalação, é altamente recomendável apagar o diretório 'install' por segurança:"
echo "   sudo rm -rf $GLPI_DIR/install"
echo "4. O usuário padrão de login é 'glpi' e a senha é 'glpi'."
echo "   MUDE IMEDIATAMENTE AS SENHAS PADRÃO!"
echo "--------------------------------------------------------"
