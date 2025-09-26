# Nome do arquivo de relatório
$RelatorioPath = ".\Relatorio_Desinstalacao.txt"

# Lista de servidores para se conectar (adicione mais nomes, se necessário)
$Servidores = "SERVIDOR1", "SERVIDOR2", "SERVIDOR3"

# Credenciais para autenticação (digite seu nome de usuário e senha)
$Credenciais = Get-Credential

# Apaga o arquivo de relatório antigo, se existir
Remove-Item $RelatorioPath -ErrorAction SilentlyContinue

# Inicia o processo
Add-Content -Path $RelatorioPath -Value "--- Relatório de Desinstalação do Google Chrome ---"
Add-Content -Path $RelatorioPath -Value "Data: $(Get-Date)"
Add-Content -Path $RelatorioPath -Value "---------------------------------------------------"

# Loop para iterar sobre cada servidor
foreach ($Servidor in $Servidores) {
    Write-Host "Conectando ao servidor: $Servidor" -ForegroundColor Yellow

    # Bloco para tratar erros, caso a conexão ou a desinstalação falhem
    try {
        # Tenta a conexão com o servidor usando PSSession
        $Sessao = New-PSSession -ComputerName $Servidor -Credential $Credenciais -Authentication Kerberos -ErrorAction Stop

        # Encontra o aplicativo 'Google Chrome' para desinstalação (32 e 64 bits)
        $Aplicativos = Invoke-Command -Session $Sessao -ScriptBlock {
            $App32 = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object { $_.DisplayName -eq "Google Chrome" }
            $App64 = Get-ItemProperty HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object { $_.DisplayName -eq "Google Chrome" }
            $App32, $App64
        } -ErrorAction Stop

        # Se o Google Chrome for encontrado, tenta desinstalá-lo
        if ($null -ne $Aplicativos) {
            Write-Host "Google Chrome encontrado no servidor $Servidor. Tentando desinstalar..." -ForegroundColor Green
            foreach ($App in $Aplicativos) {
                Invoke-Command -Session $Sessao -ScriptBlock {
                    param($App)
                    # Desinstala o aplicativo de forma silenciosa
                    Start-Process -FilePath msiexec.exe -ArgumentList "/X $($App.PSChildName) /qn" -Wait
                } -ArgumentList $App
            }
            # Adiciona o resultado ao relatório
            Add-Content -Path $RelatorioPath -Value "Servidor: $Servidor - Resultado: OK"
            Write-Host "Google Chrome desinstalado com sucesso em $Servidor." -ForegroundColor Green
        }
        else {
            # Se o aplicativo não for encontrado
            Add-Content -Path $RelatorioPath -Value "Servidor: $Servidor - Resultado: NOK (Google Chrome não encontrado)"
            Write-Host "Google Chrome não encontrado em $Servidor." -ForegroundColor Red
        }

        # Remove a sessão quando o processo termina
        Remove-PSSession -Session $Sessao
    }
    catch {
        # Em caso de erro, registra a falha no relatório
        $MensagemErro = $_.Exception.Message
        Add-Content -Path $RelatorioPath -Value "Servidor: $Servidor - Resultado: NOK (Erro ao conectar: $MensagemErro)"
        Write-Host "Erro ao conectar ou executar no servidor $Servidor: $MensagemErro" -ForegroundColor Red
    }
}

Write-Host "Processo concluído. O relatório foi salvo em $RelatorioPath." -ForegroundColor Cyan
Invoke-Item $RelatorioPath