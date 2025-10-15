#!/bin/bash

# ===============================================
# Alma Linux 9 Hardening Script (Fases 1, 2 e 3)
# AVISO: Execute este script com cautela e em ambiente de testes.
# Ele faz alterações críticas no sistema.
# ===============================================

# --- Variáveis ---
LOG_FILE="/var/log/hardening_almalinux9.log"
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_BACKUP="/etc/ssh/sshd_config.bak_$(date +%F)"
NEW_SSH_PORT=2222 # <--- ALVO: Mude para a porta desejada

# Função para registrar ações
log_action() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# 1. Atualização e Gerenciamento de Pacotes
h_update_packages() {
    log_action "PASSO 1: Atualização e Gerenciamento de Pacotes..."
    
    # Atualiza o sistema completamente
    log_action "Atualizando todos os pacotes..."
    sudo dnf update -y >> $LOG_FILE 2>&1
    
    # Remove pacotes desnecessários comuns
    log_action "Removendo pacotes desnecessários (telnet, rsh)..."
    sudo dnf remove -y telnet rsh talk >> $LOG_FILE 2>&1
    
    # Limpa o cache de pacotes
    sudo dnf clean all >> $LOG_FILE 2>&1
    log_action "Passo 1 concluído."
}

# 2. Controle de Acesso e Autenticação (Hardening do SSH)
h_ssh_hardening() {
    log_action "PASSO 2: Hardening do SSH..."

    # Backup da configuração original
    cp "$SSH_CONFIG" "$SSH_BACKUP"
    log_action "Backup do SSH feito em $SSH_BACKUP"

    # 1. Altera a porta SSH
    sed -i 's/^#Port 22/Port '$NEW_SSH_PORT'/' "$SSH_CONFIG"
    
    # 2. Desativa o login de root e autenticação por senha
    log_action "Desativando PermitRootLogin e PasswordAuthentication..."
    sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$SSH_CONFIG"
    
    # Adiciona/Garante as linhas se não existirem
    if ! grep -q "^PermitRootLogin" "$SSH_CONFIG"; then
        echo "PermitRootLogin no" >> "$SSH_CONFIG"
    fi
    if ! grep -q "^PasswordAuthentication" "$SSH_CONFIG"; then
        echo "PasswordAuthentication no" >> "$SSH_CONFIG"
    fi
    if ! grep -q "^PubkeyAuthentication" "$SSH_CONFIG"; then
        echo "PubkeyAuthentication yes" >> "$SSH_CONFIG"
    fi

    # Reinicia o serviço SSH
    sudo systemctl reload sshd
    log_action "Hardening do SSH concluído. Nova porta: $NEW_SSH_PORT."
    log_action "AVISO CRÍTICO: Certifique-se de que a autenticação por chave SSH está FUNCIONANDO!"
    log_action "Passo 2 concluído."
}

# 3. Segurança de Rede e Firewall (Firewalld)
h_firewall_hardening() {
    log_action "PASSO 3: Configuração do Firewalld..."
    
    # Habilita e inicia o firewalld
    sudo systemctl enable --now firewalld >> $LOG_FILE 2>&1
    
    # Define a zona padrão mais restritiva (DROP)
    log_action "Definindo a zona padrão como 'drop'..."
    sudo firewall-cmd --set-default-zone=drop --permanent >> $LOG_FILE 2>&1

    # Permite acesso SSH na nova porta
    log_action "Liberando a nova porta SSH ($NEW_SSH_PORT) na zona 'drop'..."
    sudo firewall-cmd --zone=drop --add-port=$NEW_SSH_PORT/tcp --permanent >> $LOG_FILE 2>&1

    # Permite outros serviços essenciais, se houver
    # Exemplo: HTTP e HTTPS
    # sudo firewall-cmd --zone=drop --add-service=http --permanent >> $LOG_FILE 2>&1
    # sudo firewall-cmd --zone=drop --add-service=https --permanent >> $LOG_FILE 2>&1

    # Aplica as mudanças
    sudo firewall-cmd --reload >> $LOG_FILE 2>&1
    
    log_action "Firewalld configurado. Apenas a porta SSH ($NEW_SSH_PORT) e outros serviços definidos estão liberados."
    log_action "Passo 3 concluído."
}

# --- Execução Principal ---
log_action "--- INÍCIO DO HARDENING ALMA LINUX 9 (FASES 1, 2 e 3) ---"

h_update_packages
h_ssh_hardening
h_firewall_hardening

log_action "--- Hardening Básico CONCLUÍDO! ---"
echo "Verifique o log detalhado em $LOG_FILE."
echo "Tente acessar o servidor usando SSH na porta $NEW_SSH_PORT e autenticação por chave."
