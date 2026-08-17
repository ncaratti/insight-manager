# ============================================================
#  InvGate Insight Manager — Instalador OPSI para Windows
#  Versão: 1.0
#
#  O que este script faz:
#    1. Verifica se está rodando como Administrador
#    2. Configura o Windows para aceitar compartilhamentos SMB
#    3. Acessa o depot OPSI no servidor AWS
#    4. Configura o install.conf com as credenciais
#    5. Executa o instalador silencioso do agente OPSI
#    6. Verifica se o serviço opsiclientd foi instalado
#
#  USO (PowerShell como Administrador):
#    Set-ExecutionPolicy Bypass -Scope Process -Force
#    .\instalar-agente-windows.ps1
#
#  OU via one-liner:
#    powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ncaratti/insight-manager/main/instalar-agente-windows.ps1 | iex"
# ============================================================

# ── Configuração do servidor OPSI ────────────────────────────
$OPSI_SERVER_IP   = "18.231.139.108"
$OPSI_PORT        = "4447"
$OPSI_USER        = "adminuser"
$OPSI_PASSWORD    = "LjqvGdHR7cZUpokOkAUt"
$OPSI_SERVICE_URL = "https://${OPSI_SERVER_IP}:${OPSI_PORT}"
$OPSI_DEPOT_PATH  = "\\${OPSI_SERVER_IP}\opsi_depot\opsi-client-agent"
$TEMP_DIR         = "C:\opsi-install-temp"

# ── Cores para output ────────────────────────────────────────
function Write-Info    { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "[ OK ]  $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "[AVISO] $msg" -ForegroundColor Yellow }
function Write-Err     { param($msg) Write-Host "[ERRO]  $msg" -ForegroundColor Red; exit 1 }

# ── Banner ───────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Blue
Write-Host "  ║   InvGate Insight Manager                       ║" -ForegroundColor Blue
Write-Host "  ║   Instalador OPSI para Windows v1.0             ║" -ForegroundColor Blue
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Blue
Write-Host ""

# ── Etapa 1: Verificar Administrador ─────────────────────────
Write-Info "Verificando permissões de administrador..."
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "Execute este script como Administrador. Clique com botão direito → Executar como administrador."
}
Write-Success "Rodando como Administrador."

# ── Etapa 2: Habilitar SMB e ajustar firewall ────────────────
Write-Info "Habilitando suporte a compartilhamentos SMB..."
try {
    # Aumentar timeout do serviço
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" `
        -Name "ServicesPipeTimeout" -Value 180000 -Type DWord -ErrorAction SilentlyContinue

    # Habilitar SMB
    Set-SmbClientConfiguration -RequireSecuritySignature $false -Force -ErrorAction SilentlyContinue

    # Desabilitar firewall temporariamente para instalação
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction SilentlyContinue

    # Adicionar Windows Defender exclusion
    Add-MpPreference -ExclusionPath "C:\Program Files (x86)\opsi.org" -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess "opsiclientd.exe" -ErrorAction SilentlyContinue

    Write-Success "SMB e firewall configurados."
} catch {
    Write-Warn "Não foi possível configurar SMB/firewall. Continuando..."
}

# ── Etapa 3: Testar conectividade com o servidor ─────────────
Write-Info "Testando conectividade com ${OPSI_SERVER_IP}..."
$ping = Test-Connection -ComputerName $OPSI_SERVER_IP -Count 2 -Quiet -ErrorAction SilentlyContinue
if (-not $ping) {
    Write-Warn "Servidor não responde ao ping. Tentando continuar mesmo assim..."
} else {
    Write-Success "Servidor ${OPSI_SERVER_IP} acessível."
}

# ── Etapa 4: Mapear o depot OPSI ─────────────────────────────
Write-Info "Acessando depot OPSI em ${OPSI_DEPOT_PATH}..."

# Remover mapeamento anterior se existir
net use "\\${OPSI_SERVER_IP}\opsi_depot" /delete /y 2>$null | Out-Null

# Mapear com credenciais
$netUseResult = net use "\\${OPSI_SERVER_IP}\opsi_depot" /user:$OPSI_USER $OPSI_PASSWORD 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Não foi possível mapear via net use. Tentando acesso direto..."
}

# Verificar se o depot está acessível
if (-not (Test-Path $OPSI_DEPOT_PATH)) {
    Write-Err "Depot OPSI não acessível em ${OPSI_DEPOT_PATH}. Verifique se o servidor está online e a porta 445 está liberada."
}
Write-Success "Depot OPSI acessível."

# ── Etapa 5: Criar diretório temporário ──────────────────────
Write-Info "Copiando arquivos do instalador..."
if (Test-Path $TEMP_DIR) {
    Remove-Item -Path $TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null

# Copiar arquivos do depot para o diretório temporário
try {
    Copy-Item -Path "${OPSI_DEPOT_PATH}\*" -Destination $TEMP_DIR -Recurse -Force
    Write-Success "Arquivos copiados para ${TEMP_DIR}."
} catch {
    Write-Err "Falha ao copiar arquivos do depot: $_"
}

# ── Etapa 6: Configurar install.conf ─────────────────────────
Write-Info "Configurando credenciais do servidor OPSI..."
$installConf = @"
client_id =
service_address = $OPSI_SERVICE_URL
service_username = $OPSI_USER
service_password = $OPSI_PASSWORD
interactive = false
"@
$installConf | Set-Content -Path "${TEMP_DIR}\install.conf" -Encoding UTF8
Write-Success "install.conf configurado."

# ── Etapa 7: Adicionar hosts do servidor ─────────────────────
Write-Info "Configurando resolução de nomes..."
$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$hostsEntry = "${OPSI_SERVER_IP}    ip-172-31-27-0.sa-east-1.compute.internal ip-172-31-27-0"
$hostsContent = Get-Content $hostsFile -ErrorAction SilentlyContinue
if ($hostsContent -notcontains $hostsEntry) {
    Add-Content -Path $hostsFile -Value $hostsEntry -ErrorAction SilentlyContinue
}
Write-Success "Hosts configurado."

# ── Etapa 8: Executar instalador ─────────────────────────────
Write-Info "Instalando agente OPSI..."

# Verificar qual instalador está disponível
$installer = $null
if (Test-Path "${TEMP_DIR}\oca-installation-helper.exe") {
    $installer = "${TEMP_DIR}\oca-installation-helper.exe"
    Write-Info "Usando: oca-installation-helper.exe"
} elseif (Test-Path "${TEMP_DIR}\silent_setup.cmd") {
    $installer = "${TEMP_DIR}\silent_setup.cmd"
    Write-Info "Usando: silent_setup.cmd"
} else {
    Write-Err "Instalador não encontrado em ${TEMP_DIR}. Verifique o depot."
}

# Executar instalador
try {
    if ($installer -like "*.exe") {
        $proc = Start-Process -FilePath $installer `
            -ArgumentList "--service-url=$OPSI_SERVICE_URL --username=$OPSI_USER --password=$OPSI_PASSWORD" `
            -Wait -PassThru -ErrorAction SilentlyContinue
        if ($proc.ExitCode -ne 0) {
            # Tentar sem argumentos (usa install.conf)
            $proc = Start-Process -FilePath $installer -Wait -PassThru
        }
    } else {
        $proc = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c `"$installer`"" `
            -WorkingDirectory $TEMP_DIR `
            -Wait -PassThru
    }
    Write-Success "Instalador executado (código: $($proc.ExitCode))."
} catch {
    Write-Warn "Instalador retornou erro: $_. Verificando se o serviço foi instalado mesmo assim..."
}

# ── Etapa 9: Verificar instalação ────────────────────────────
Write-Info "Verificando instalação do agente OPSI..."
Start-Sleep -Seconds 10

$service = Get-Service -Name "opsiclientd" -ErrorAction SilentlyContinue
if ($service) {
    Write-Success "Serviço opsiclientd instalado: $($service.Status)"
    if ($service.Status -ne "Running") {
        Write-Info "Iniciando serviço opsiclientd..."
        Start-Service -Name "opsiclientd" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 30
        $service.Refresh()
        if ($service.Status -eq "Running") {
            Write-Success "Serviço opsiclientd iniciado com sucesso!"
        } else {
            Write-Warn "Serviço instalado mas não iniciou. Reinicie o Windows para completar."
        }
    }
} else {
    Write-Warn "Serviço opsiclientd não encontrado. A instalação pode ter falhado."
    Write-Info "Tente executar manualmente: ${TEMP_DIR}\oca-installation-helper.exe"
}

# ── Etapa 10: Limpar e finalizar ─────────────────────────────
Write-Info "Finalizando..."

# Desconectar mapeamento de rede
net use "\\${OPSI_SERVER_IP}\opsi_depot" /delete /y 2>$null | Out-Null

# Reabilitar firewall
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║   Instalação concluída!                         ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Servidor OPSI:  $OPSI_SERVICE_URL" -ForegroundColor Cyan
Write-Host "  Arquivos temp:  $TEMP_DIR" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Se o serviço não iniciou, reinicie o Windows." -ForegroundColor Yellow
Write-Host "  O agente OPSI inicia automaticamente com o Windows." -ForegroundColor Yellow
Write-Host ""
