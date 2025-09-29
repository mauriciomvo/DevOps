```python
#!/usr/bin/env python3
import subprocess
import os
import getpass
import sys
from datetime import datetime

LOG_DIR = "/var/log/odoo19"
LOG_FILE = f"{LOG_DIR}/install.log"

def log(msg):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    linha = f"[{timestamp}] {msg}\n"
    print(linha.strip())
    with open(LOG_FILE, "a") as f:
        f.write(linha)

def run_cmd(cmd, shell=True, ignore_error=False):
    log(f"[EXECUTANDO] {cmd}")
    try:
        with open(LOG_FILE, "a") as f:
            subprocess.run(cmd, shell=shell, check=True,
                           stdout=f, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError:
        log(f"❌ ERRO ao executar: {cmd}")
        if not ignore_error:
            sys.exit(1)

def criar_arquivo(path, conteudo):
    log(f"[CRIANDO ARQUIVO] {path}")
    with open(path, "w") as f:
        f.write(conteudo)

def main():
    print("=== Instalação do Odoo 19 no AlmaLinux 9 ===")

    os.makedirs(LOG_DIR, exist_ok=True)
    with open(LOG_FILE, "w") as f:
        f.write("=== LOG DE INSTALAÇÃO DO ODOO 19 ===\n")

    # 1. Atualização do sistema
    run_cmd("sudo dnf update -y && sudo dnf upgrade -y")

    # 2. Dependências
    run_cmd("sudo dnf config-manager --set-enabled crb")
    run_cmd("sudo dnf install -y python3-pip git gcc redhat-rpm-config libxslt-devel "
            "bzip2-devel openldap-devel libjpeg-devel freetype-devel curl unzip "
            "openssl-devel wget yum-utils make libffi-devel zlib-devel tar libpq-devel")

    # 3. Node.js e LESS
    run_cmd("sudo dnf module install -y nodejs")
    run_cmd("sudo npm install -g less less-plugin-clean-css")

    # 4. PostgreSQL 17
    run_cmd("sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm")
    run_cmd("sudo dnf install -y postgresql17-server postgresql17 postgresql17-contrib")
    run_cmd("sudo /usr/pgsql-17/bin/postgresql-setup initdb", ignore_error=True)
    run_cmd("sudo systemctl enable postgresql-17")
    run_cmd("sudo systemctl start postgresql-17")

    # 5. Usuário Odoo
    run_cmd("sudo useradd -m -d /opt/odoo19 -U -r -s /bin/bash odoo19 || true", ignore_error=True)
    run_cmd('sudo su - postgres -c "createuser -s odoo19" || true', ignore_error=True)

    # 6. Clonar Odoo
    run_cmd("sudo -u odoo19 git clone https://www.github.com/odoo/odoo --depth 1 --branch 19.0 /opt/odoo19/odoo")

    # 7. Virtualenv
    run_cmd("sudo -u odoo19 python3 -m venv /opt/odoo19/odoo19-venv")
    run_cmd("sudo -u odoo19 /opt/odoo19/odoo19-venv/bin/pip3 install wheel")
    run_cmd("sudo -u odoo19 /opt/odoo19/odoo19-venv/bin/pip3 install -r /opt/odoo19/odoo/requirements.txt")

    # 8. wkhtmltopdf
    run_cmd("sudo dnf install -y https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/"
            "wkhtmltox-0.12.6.1-2.almalinux9.x86_64.rpm")

    # 9. Logs
    run_cmd("sudo chown odoo19: /var/log/odoo19/")

    # 10. Configuração do Odoo
    senha_admin = getpass.getpass("Digite a senha mestre do Odoo: ")
    conf_odoo = f"""[options]
admin_passwd = {senha_admin}
db_host = False
db_port = False
db_user = odoo19
db_password = False
addons_path = /opt/odoo19/odoo/addons
xmlrpc_port = 8069
log_level = info
logfile = /var/log/odoo19/odoo.log
"""
    criar_arquivo("/tmp/odoo19.conf", conf_odoo)
    run_cmd("sudo mv /tmp/odoo19.conf /etc/odoo19.conf")

    # 11. Systemd
    service_file = """[Unit]
Description=Odoo v19.0
Requires=postgresql-17.service
After=network.target postgresql-17.service

[Service]
Type=simple
SyslogIdentifier=odoo19
PermissionsStartOnly=true
User=odoo19
Group=odoo19
ExecStart=/opt/odoo19/odoo19-venv/bin/python3 /opt/odoo19/odoo/odoo-bin -c /etc/odoo19.conf
StandardOutput=journal
StandardError=journal
TimeoutStartSec=300
Restart=always

[Install]
WantedBy=multi-user.target
"""
    criar_arquivo("/tmp/odoo19.service", service_file)
    run_cmd("sudo mv /tmp/odoo19.service /etc/systemd/system/odoo19.service")

    # 12. Ativar Odoo
    run_cmd("sudo systemctl daemon-reload")
    run_cmd("sudo systemctl enable odoo19.service")
    run_cmd("sudo systemctl start odoo19.service")

    # 13. Firewall
    run_cmd("sudo firewall-cmd --permanent --add-port=8069/tcp")
    run_cmd("sudo firewall-cmd --permanent --add-service=http")
    run_cmd("sudo firewall-cmd --permanent --add-service=https")
    run_cmd("sudo firewall-cmd --reload")

    # 14. Testes básicos
    run_cmd("systemctl is-active odoo19 || true", ignore_error=True)
    run_cmd("sudo ss -tulnp | grep 8069 || true", ignore_error=True)
    run_cmd("curl -I http://localhost:8069 || true", ignore_error=True)

    # 15. Proxy reverso + SSL
    dominio = input("Digite o domínio para configurar o proxy reverso (ex: odoo.seudominio.com): ").strip()
    if dominio:
        email_ssl = input("Digite o e-mail para receber notificações do Let's Encrypt: ").strip()
        run_cmd("sudo dnf install -y nginx certbot python3-certbot-nginx")
        nginx_conf = f"""
server {{
    listen 80;
    server_name {dominio};

    location / {{
        proxy_pass http://127.0.0.1:8069;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}

    location /longpolling {{
        proxy_pass http://127.0.0.1:8069/longpolling;
    }}

    access_log /var/log/nginx/odoo19_access.log;
    error_log /var/log/nginx/odoo19_error.log;
}}
"""
        criar_arquivo("/tmp/odoo19_nginx.conf", nginx_conf)
        run_cmd("sudo mv /tmp/odoo19_nginx.conf /etc/nginx/conf.d/odoo19.conf")
        run_cmd("sudo nginx -t")
        run_cmd("sudo systemctl enable nginx")
        run_cmd("sudo systemctl restart nginx")

        log(f"🌐 Proxy reverso configurado para http://{dominio}")

        # SSL automático
        log("🔒 Gerando certificado SSL com Let's Encrypt...")
        run_cmd(f"sudo certbot --nginx -d {dominio} --non-interactive --agree-tos -m {email_ssl} --redirect")

        # Ativar renovação automática
        run_cmd("sudo systemctl enable certbot-renew.timer")
        run_cmd("sudo systemctl start certbot-renew.timer")

        log("🔄 Renovação automática de certificados ativada (systemd timer).")
        log(f"✅ SSL instalado! Acesse: https://{dominio}")

    log("=== Instalação concluída! ===")

if __name__ == "__main__":
    main()
```

