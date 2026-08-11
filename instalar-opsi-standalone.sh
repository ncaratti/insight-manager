#!/usr/bin/env bash
# ============================================================
#  OPSI Server — Instalador Automático para Linux
#  Versão: 1.0  |  Hepta Tecnologia e Informática Ltda.
#
#  Sistemas suportados:
#    Ubuntu 20.04, 22.04, 24.04
#    Debian 11 (Bullseye), 12 (Bookworm)
#
#  USO:
#    curl -fsSL https://raw.githubusercontent.com/ncaratti/insight-manager/main/instalar-opsi-standalone.sh | sudo bash
#
#    OU baixe e execute localmente:
#    chmod +x instalar-opsi-standalone.sh
#    sudo ./instalar-opsi-standalone.sh
#
#  O que este script instala:
#    - Docker Engine + Docker Compose
#    - OPSI Server 4.3 (config server completo)
#    - MySQL 8.0 (backend de dados)
#    - Redis 7 (cache e filas)
#    - Grafana (dashboards)
#    - Serviço systemd para inicialização automática
#    - Helper CLI: opsi-server {status|logs|start|stop|restart|backup}
# ============================================================

set -eo pipefail

# ──────────────────────────────────────────────
#  Constantes
# ──────────────────────────────────────────────
VERSAO_SCRIPT="1.0"
VERSAO_OPSI="4.3"
DIR_INSTALACAO="/opt/opsi-server"
LOG="/var/log/opsi-install.log"
PORTA_HTTPS="4447"
PORTA_TFTP="69"
PORTA_SMB="445"

# ──────────────────────────────────────────────
#  Cores
# ──────────────────────────────────────────────
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_NC='\033[0m'

# ──────────────────────────────────────────────
#  Funções de log
# ──────────────────────────────────────────────
_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()   { echo -e "$(_ts) ${C_BLUE}[INFO]${C_NC}  $*" | tee -a "$LOG"; }
ok()    { echo -e "$(_ts) ${C_GREEN}[  OK]${C_NC}  $*" | tee -a "$LOG"; }
warn()  { echo -e "$(_ts) ${C_YELLOW}[WARN]${C_NC}  $*" | tee -a "$LOG"; }
erro()  { echo -e "$(_ts) ${C_RED}[ERRO]${C_NC}  $*" | tee -a "$LOG"; exit 1; }
titulo(){ echo -e "\n${C_BOLD}${C_CYAN}══════════════════════════════════════${C_NC}"; \
          echo -e "${C_BOLD}${C_CYAN}  $*${C_NC}"; \
          echo -e "${C_BOLD}${C_CYAN}══════════════════════════════════════${C_NC}"; }

# ──────────────────────────────────────────────
#  Banner
# ──────────────────────────────────────────────
mostrar_banner() {
cat << BANNER

  ╔═══════════════════════════════════════════════════╗
  ║                                                   ║
  ║   OPSI Server ${VERSAO_OPSI} — Instalador Linux          ║
  ║   Versão do script: ${VERSAO_SCRIPT}                      ║
  ║   Hepta Tecnologia e Informática Ltda.            ║
  ║                                                   ║
  ╠═══════════════════════════════════════════════════╣
  ║  O que será instalado:                            ║
  ║  • Docker Engine + Docker Compose                 ║
  ║  • OPSI ${VERSAO_OPSI} (config server)                   ║
  ║  • MySQL 8.0 + Redis 7 + Grafana                  ║
  ║  • Serviço systemd + helper CLI                   ║
  ╚═══════════════════════════════════════════════════╝

BANNER
}

# ──────────────────────────────────────────────
#  Utilitários
# ──────────────────────────────────────────────
gerar_senha() {
  # 20 caracteres: letras + números + símbolos seguros
  tr -dc 'A-Za-z0-9@#%^&*' </dev/urandom 2>/dev/null | head -c 20
}

porta_em_uso() {
  ss -tlnup 2>/dev/null | grep -q ":${1} " && return 0 || return 1
}

detectar_ip_local() {
  ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || echo "127.0.0.1"
}

aguardar_opsi() {
  local url="https://localhost:${PORTA_HTTPS}/admin"
  local tentativas=0
  local max=36  # 3 minutos (36 × 5s)
  log "Aguardando OPSI inicializar (até 3 minutos)..."
  while ! curl -sk --max-time 4 "$url" &>/dev/null; do
    tentativas=$((tentativas + 1))
    [[ $tentativas -ge $max ]] && erro "OPSI não ficou pronto. Verifique: docker compose -f ${DIR_INSTALACAO}/docker-compose.yml logs opsiconfd"
    printf "."
    sleep 5
  done
  echo ""
}

# ──────────────────────────────────────────────
#  ETAPA 0 — Inicialização
# ──────────────────────────────────────────────
init() {
  mkdir -p "$(dirname "$LOG")" || true
  touch "$LOG" || true
  mostrar_banner | tee -a "$LOG" || true
  log "Script iniciado. Log em: ${LOG}"

  if [ "$(id -u)" -ne 0 ]; then echo "ERRO: Execute como root: sudo $0"; exit 1; fi
}

# ──────────────────────────────────────────────
#  ETAPA 1 — Detectar sistema operacional
# ──────────────────────────────────────────────
detectar_so() {
  titulo "Etapa 1/9 — Detectando sistema operacional"

  if [[ ! -f /etc/os-release ]]; then
    erro "/etc/os-release não encontrado. SO não suportado."
  fi

  # shellcheck disable=SC1091
  source /etc/os-release || true
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-0}"
  OS_CODENAME="${VERSION_CODENAME:-sem-codename}"
  ARCH=$(uname -m)

  log "Sistema: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
  log "Arquitetura: ${ARCH}"

  case "$OS_ID" in
    ubuntu)
      case "$OS_VERSION" in
        20.04|22.04|24.04|26.04) ok "Ubuntu ${OS_VERSION} — suportado." ;;
        *) warn "Ubuntu ${OS_VERSION} não testado oficialmente. Prosseguindo..." ;;
      esac
      PKG_MANAGER="apt-get"
      ;;
    debian)
      case "$OS_VERSION" in
        11|12) ok "Debian ${OS_VERSION} — suportado." ;;
        *) warn "Debian ${OS_VERSION} não testado. Prosseguindo..." ;;
      esac
      PKG_MANAGER="apt-get"
      ;;
    *)
      warn "Sistema não reconhecido oficialmente. Tentando prosseguir..."; PKG_MANAGER="apt-get"
      ;;
  esac

  [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]] && \
    warn "Arquitetura ${ARCH} — suporte experimental. Recomendado: x86_64."
}

# ──────────────────────────────────────────────
#  ETAPA 2 — Verificar hardware
# ──────────────────────────────────────────────
verificar_hardware() {
  titulo "Etapa 2/9 — Verificando recursos do servidor"

  local ram_mb disk_gb cpu_count
  ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  disk_gb=$(df -BG "${DIR_INSTALACAO%/*}" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || \
            df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
  cpu_count=$(nproc)

  log "RAM:   ${ram_mb} MB"
  log "Disco: ${disk_gb} GB livres"
  log "CPUs:  ${cpu_count}"

  # Mínimos absolutos
  [[ $ram_mb -lt 2048 ]] && erro "RAM insuficiente: ${ram_mb} MB. Mínimo: 2048 MB (recomendado: 4096 MB)."
  [[ $disk_gb -lt 15 ]]  && erro "Disco insuficiente: ${disk_gb} GB. Mínimo: 15 GB."

  # Avisos (não bloqueiam)
  [[ $ram_mb -lt 4096 ]] && warn "RAM abaixo do recomendado (${ram_mb} MB < 4096 MB). OPSI pode ficar lento."
  [[ $disk_gb -lt 50 ]]  && warn "Disco abaixo do ideal (${disk_gb} GB). Para muitos clientes/patches, recomenda-se 100 GB+."
  [[ $cpu_count -lt 2 ]] && warn "Apenas ${cpu_count} CPU detectada. Recomendado: 2+."

  ok "Hardware verificado."
}

# ──────────────────────────────────────────────
#  ETAPA 3 — Verificar portas
# ──────────────────────────────────────────────
verificar_portas() {
  titulo "Etapa 3/9 — Verificando portas de rede"

  local conflito=false

  for porta in "$PORTA_HTTPS" "$PORTA_SMB"; do
    if porta_em_uso "$porta"; then
      warn "Porta TCP ${porta} já está em uso por outro processo."
      conflito=true
    else
      ok "Porta TCP ${porta} — livre."
    fi
  done

  if porta_em_uso "$PORTA_TFTP"; then
    warn "Porta UDP ${PORTA_TFTP} (TFTP) já em uso. Netboot de clientes pode não funcionar."
  else
    ok "Porta UDP ${PORTA_TFTP} (TFTP) — livre."
  fi

  if $conflito; then
    echo ""
    warn "Há conflitos de porta. O OPSI pode não funcionar corretamente."
    read -rp "  Deseja continuar mesmo assim? [s/N]: " resp
    [[ "${resp,,}" != "s" ]] && erro "Instalação cancelada pelo usuário."
  fi
}

# ──────────────────────────────────────────────
#  ETAPA 4 — Instalar Docker
# ──────────────────────────────────────────────
instalar_docker() {
  titulo "Etapa 4/9 — Instalando Docker"

  if command -v docker &>/dev/null; then
    local ver
    ver=$(docker --version | grep -oP '[\d.]+' | head -1)
    ok "Docker já instalado: v${ver}"
  else
    log "Baixando e executando instalador oficial do Docker..."
    export DEBIAN_FRONTEND=noninteractive
    $PKG_MANAGER update -qq >> "$LOG" 2>&1
    $PKG_MANAGER install -y -qq curl ca-certificates gnupg >> "$LOG" 2>&1
    curl -fsSL https://get.docker.com | bash >> "$LOG" 2>&1
    systemctl enable --now docker >> "$LOG" 2>&1
    ok "Docker instalado e iniciado."
  fi

  # Docker Compose
  if docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose v2 — disponível."
  elif command -v docker-compose &>/dev/null; then
    ok "Docker Compose standalone — disponível."
  else
    log "Instalando Docker Compose plugin..."
    $PKG_MANAGER install -y -qq docker-compose-plugin >> "$LOG" 2>&1 || {
      local compose_bin="/usr/local/bin/docker-compose"
      local compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
      curl -SL "$compose_url" -o "$compose_bin" >> "$LOG" 2>&1
      chmod +x "$compose_bin"
    }
    ok "Docker Compose instalado."
  fi

  # Testar Docker
  docker run --rm hello-world >> "$LOG" 2>&1 && ok "Docker funcionando corretamente." || \
    warn "Teste do Docker retornou erro — verifique o log."
}

# ──────────────────────────────────────────────
#  ETAPA 5 — Gerar credenciais
# ──────────────────────────────────────────────
gerar_credenciais() {
  titulo "Etapa 5/9 — Gerando credenciais"

  mkdir -p "${DIR_INSTALACAO}"

  OPSI_ADMIN_PASS=$(gerar_senha)
  MYSQL_ROOT_PASS=$(gerar_senha)
  MYSQL_OPSI_PASS=$(gerar_senha)
  GRAFANA_PASS=$(gerar_senha)
  SERVER_IP=$(detectar_ip_local)
  SERVER_HOSTNAME=$(hostname -s)
  SERVER_DOMAIN=$(hostname -d 2>/dev/null || dnsdomainname 2>/dev/null || echo "local")

  log "IP detectado:   ${SERVER_IP}"
  log "Hostname:       ${SERVER_HOSTNAME}"
  log "Domínio:        ${SERVER_DOMAIN}"
  log "Dir instalação: ${DIR_INSTALACAO}"

  # Salvar credenciais em arquivo protegido
  cat > "${DIR_INSTALACAO}/.credentials" << CREDS
# ============================================================
#  OPSI Server — Credenciais de Acesso
#  Gerado em: $(date)
#  ATENÇÃO: Guarde este arquivo em local seguro!
# ============================================================

# Acesso à WebGUI e API do OPSI
OPSI_URL=https://${SERVER_IP}:${PORTA_HTTPS}
OPSI_USUARIO=adminuser
OPSI_SENHA=${OPSI_ADMIN_PASS}

# Banco de dados MySQL
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
MYSQL_PASSWORD=${MYSQL_OPSI_PASS}

# Grafana (dashboards)
GRAFANA_URL=https://${SERVER_IP}:${PORTA_HTTPS}/grafana
GRAFANA_USUARIO=admin
GRAFANA_SENHA=${GRAFANA_PASS}

# Servidor
SERVER_IP=${SERVER_IP}
SERVER_HOSTNAME=${SERVER_HOSTNAME}
SERVER_DOMAIN=${SERVER_DOMAIN}
CREDS
  chmod 600 "${DIR_INSTALACAO}/.credentials"
  ok "Credenciais geradas e salvas em ${DIR_INSTALACAO}/.credentials"
}

# ──────────────────────────────────────────────
#  ETAPA 6 — Criar docker-compose.yml
# ──────────────────────────────────────────────
criar_compose() {
  titulo "Etapa 6/9 — Criando configuração Docker Compose"

  cat > "${DIR_INSTALACAO}/docker-compose.yml" << COMPOSE
version: "3.8"

# ============================================================
#  OPSI Server ${VERSAO_OPSI} — Hepta Tecnologia
#  Gerado em: $(date)
# ============================================================

x-restart: &sempre
  restart: unless-stopped

services:

  # ── Banco de dados ────────────────────────────────────────
  mysql:
    image: mysql:8.0
    <<: *sempre
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: opsi
      MYSQL_USER: opsi
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - mysql-data:/var/lib/mysql
    networks: [opsi-net]
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-p\${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s

  # ── Cache e filas ─────────────────────────────────────────
  redis:
    image: redis:7-alpine
    <<: *sempre
    command: redis-server --appendonly yes
    volumes:
      - redis-data:/data
    networks: [opsi-net]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

  # ── Dashboards ────────────────────────────────────────────
  grafana:
    image: grafana/grafana:latest
    <<: *sempre
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: \${GRAFANA_PASSWORD}
      GF_SERVER_ROOT_URL: https://\${OPSI_HOSTNAME}.\${OPSI_DOMAIN}:4447/grafana
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana-data:/var/lib/grafana
    networks: [opsi-net]

  # ── OPSI Config Server ────────────────────────────────────
  opsiconfd:
    image: opsiproducts/opsi-server:latest
    <<: *sempre
    hostname: \${OPSI_HOSTNAME}
    domainname: \${OPSI_DOMAIN}
    environment:
      OPSI_HOST_ROLE: configserver
      OPSI_HOSTNAME: \${OPSI_HOSTNAME}
      OPSI_DOMAIN: \${OPSI_DOMAIN}
      OPSI_ADMIN_PASSWORD: \${OPSI_ADMIN_PASSWORD}
      OPSI_MYSQL_HOST: mysql
      OPSI_MYSQL_USER: opsi
      OPSI_MYSQL_PASSWORD: \${MYSQL_PASSWORD}
      OPSI_MYSQL_DATABASE: opsi
      OPSI_REDIS_HOST: redis
      OPSI_GRAFANA_INTERNAL_URL: http://grafana:3000
      OPSI_TFTPBOOT: "true"
    ports:
      - "${PORTA_HTTPS}:4447"
      - "${PORTA_TFTP}:69/udp"
      - "${PORTA_SMB}:445"
    volumes:
      - opsi-data:/var/lib/opsi
      - opsi-config:/etc/opsi
      - opsi-logs:/var/log/opsi
    networks: [opsi-net]
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  mysql-data:
  redis-data:
  grafana-data:
  opsi-data:
  opsi-config:
  opsi-logs:

networks:
  opsi-net:
    driver: bridge
COMPOSE

  # Arquivo .env com variáveis
  cat > "${DIR_INSTALACAO}/.env" << ENV
OPSI_HOSTNAME=${SERVER_HOSTNAME}
OPSI_DOMAIN=${SERVER_DOMAIN}
OPSI_ADMIN_PASSWORD=${OPSI_ADMIN_PASS}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
MYSQL_PASSWORD=${MYSQL_OPSI_PASS}
GRAFANA_PASSWORD=${GRAFANA_PASS}
ENV
  chmod 600 "${DIR_INSTALACAO}/.env"

  ok "docker-compose.yml e .env criados em ${DIR_INSTALACAO}/"
}

# ──────────────────────────────────────────────
#  ETAPA 7 — Subir containers
# ──────────────────────────────────────────────
subir_containers() {
  titulo "Etapa 7/9 — Baixando imagens e iniciando OPSI"

  cd "${DIR_INSTALACAO}"

  log "Baixando imagens Docker (pode levar alguns minutos)..."
  docker compose pull 2>&1 | tee -a "$LOG" | grep -E "Pulling|Downloaded|already exists" || true

  log "Iniciando containers..."
  docker compose up -d 2>&1 | tee -a "$LOG"

  ok "Containers iniciados."
  docker compose ps 2>&1 | tee -a "$LOG"

  aguardar_opsi
  ok "OPSI disponível em https://${SERVER_IP}:${PORTA_HTTPS}"
}

# ──────────────────────────────────────────────
#  ETAPA 8 — Configurar systemd
# ──────────────────────────────────────────────
configurar_systemd() {
  titulo "Etapa 8/9 — Configurando inicialização automática"

  cat > /etc/systemd/system/opsi-server.service << SERVICE
[Unit]
Description=OPSI Server (Docker Compose)
Documentation=https://docs.opsi.org
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${DIR_INSTALACAO}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose stop
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable opsi-server.service >> "$LOG" 2>&1
  ok "Serviço 'opsi-server' habilitado para iniciar com o sistema."
}

# ──────────────────────────────────────────────
#  ETAPA 9 — Instalar helper CLI
# ──────────────────────────────────────────────
instalar_helper() {
  titulo "Etapa 9/9 — Instalando helper de linha de comando"

  cat > /usr/local/bin/opsi-server << 'HELPER'
#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  opsi-server — Helper CLI do OPSI
#  Hepta Tecnologia e Informática Ltda.
# ─────────────────────────────────────────────
DIR="/opt/opsi-server"
CREDS="${DIR}/.credentials"
COMPOSE="docker compose -f ${DIR}/docker-compose.yml"

_info()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
_ok()    { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
_warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
_erro()  { echo -e "\033[0;31m[ERRO]\033[0m  $*"; exit 1; }

case "${1:-ajuda}" in

  status)
    echo ""
    echo "  ── Containers ──────────────────────────────"
    $COMPOSE ps
    echo ""
    echo "  ── Uso de recursos ─────────────────────────"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" \
      $(docker compose -f ${DIR}/docker-compose.yml ps -q) 2>/dev/null || true
    echo ""
    ;;

  logs)
    shift
    $COMPOSE logs -f --tail=100 "${@:-opsiconfd}"
    ;;

  start)
    _info "Iniciando OPSI..."
    $COMPOSE up -d
    _ok "OPSI iniciado."
    ;;

  stop)
    _info "Parando OPSI..."
    $COMPOSE stop
    _ok "OPSI parado."
    ;;

  restart)
    _info "Reiniciando OPSI..."
    $COMPOSE restart opsiconfd
    _ok "OPSI reiniciado."
    ;;

  update)
    _info "Atualizando imagens OPSI..."
    $COMPOSE pull
    $COMPOSE up -d --remove-orphans
    _ok "OPSI atualizado."
    ;;

  backup)
    DEST="/var/backups/opsi"
    TS=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$DEST"
    _info "Fazendo backup do banco de dados..."
    source "${DIR}/.env" 2>/dev/null
    $COMPOSE exec -T mysql \
      mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" --all-databases --single-transaction \
      > "${DEST}/opsi-db-${TS}.sql" \
      && _ok "Backup salvo: ${DEST}/opsi-db-${TS}.sql" \
      || _warn "Falha no backup. Verifique se o container mysql está rodando."
    ;;

  restaurar)
    [[ -z "${2:-}" ]] && _erro "Informe o arquivo de backup: opsi-server restaurar /caminho/arquivo.sql"
    [[ ! -f "$2" ]]   && _erro "Arquivo não encontrado: $2"
    source "${DIR}/.env" 2>/dev/null
    _info "Restaurando backup: $2"
    $COMPOSE exec -T mysql \
      mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
      < "$2" \
      && _ok "Backup restaurado com sucesso." \
      || _erro "Falha ao restaurar backup."
    ;;

  credenciais)
    if [[ -f "$CREDS" ]]; then
      echo ""
      echo "  ── Credenciais do OPSI ──────────────────────"
      grep -v "^#" "$CREDS" | grep -v "^$" | while IFS='=' read -r chave valor; do
        printf "  %-25s %s\n" "${chave}:" "${valor}"
      done
      echo ""
    else
      _warn "Arquivo de credenciais não encontrado: ${CREDS}"
    fi
    ;;

  testar-api)
    source "${CREDS}" 2>/dev/null || { _warn "Credenciais não encontradas."; exit 1; }
    _info "Testando API JSON-RPC do OPSI..."
    RESP=$(curl -sk \
      -u "adminuser:${OPSI_SENHA}" \
      -X POST "https://localhost:4447/rpc" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"backend_info","params":[]}')
    if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('  Versão OPSI:', d['result'].get('opsiVersion','?'))" 2>/dev/null; then
      _ok "API OPSI respondendo corretamente."
    else
      _warn "Resposta inesperada da API:"
      echo "$RESP"
    fi
    ;;

  listar-clientes)
    source "${CREDS}" 2>/dev/null
    _info "Consultando clientes registrados no OPSI..."
    curl -sk \
      -u "adminuser:${OPSI_SENHA}" \
      -X POST "https://localhost:4447/rpc" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"host_getObjects","params":[["id","description","lastSeen"],{"type":"OpsiClient"}]}' \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
clientes = data.get('result', [])
print(f'\n  Total de clientes: {len(clientes)}\n')
for c in clientes[:20]:
    print(f'  {c.get(\"id\",\"?\")} — último acesso: {c.get(\"lastSeen\",\"nunca\")}')
if len(clientes) > 20:
    print(f'  ... e mais {len(clientes)-20} clientes.')
" 2>/dev/null || echo "  Nenhum cliente registrado ainda."
    ;;

  ajuda|--help|-h|*)
    cat << 'USO'

  Uso: opsi-server <comando>

  Comandos disponíveis:
    status           Ver estado dos containers e uso de recursos
    logs [serviço]   Logs em tempo real (padrão: opsiconfd)
    start            Iniciar todos os containers
    stop             Parar todos os containers
    restart          Reiniciar o OPSI (mantém MySQL e Redis)
    update           Atualizar para a versão mais recente
    backup           Fazer backup do banco de dados
    restaurar <arq>  Restaurar um backup SQL
    credenciais      Exibir usuário e senha do OPSI
    testar-api       Testar a API JSON-RPC do OPSI
    listar-clientes  Listar endpoints registrados no OPSI

  Exemplos:
    opsi-server status
    opsi-server logs mysql
    opsi-server backup
    opsi-server credenciais

USO
    ;;
esac
HELPER

  chmod +x /usr/local/bin/opsi-server
  ok "Helper 'opsi-server' instalado. Use: opsi-server <comando>"
}

# ──────────────────────────────────────────────
#  RESUMO FINAL
# ──────────────────────────────────────────────
mostrar_resumo() {
  echo ""
  echo -e "${C_GREEN}╔══════════════════════════════════════════════════════╗${C_NC}"
  echo -e "${C_GREEN}║       Instalação concluída com sucesso!  ✓           ║${C_NC}"
  echo -e "${C_GREEN}╚══════════════════════════════════════════════════════╝${C_NC}"
  echo ""
  echo -e "  ${C_BOLD}Acesso ao OPSI${C_NC}"
  echo -e "  WebGUI:   ${C_BLUE}https://${SERVER_IP}:${PORTA_HTTPS}${C_NC}"
  echo -e "  Usuário:  ${C_BOLD}adminuser${C_NC}"
  echo -e "  Senha:    ${C_BOLD}${OPSI_ADMIN_PASS}${C_NC}"
  echo ""
  echo -e "  ${C_BOLD}Credenciais completas salvas em:${C_NC}"
  echo -e "  ${DIR_INSTALACAO}/.credentials"
  echo ""
  echo -e "  ${C_BOLD}Comandos úteis:${C_NC}"
  echo -e "  opsi-server status        — ver containers"
  echo -e "  opsi-server logs          — logs em tempo real"
  echo -e "  opsi-server credenciais   — ver usuário e senha"
  echo -e "  opsi-server testar-api    — testar API JSON-RPC"
  echo -e "  opsi-server listar-clientes — ver endpoints"
  echo ""
  echo -e "  ${C_BOLD}Próximos passos:${C_NC}"
  echo -e "  1. Acesse a WebGUI e valide o login"
  echo -e "  2. Instale o agente OPSI nos endpoints Windows/Linux"
  echo -e "  3. Configure a conexão no InvGate Insight Manager"
  echo ""
  echo -e "  Documentação: ${C_BLUE}https://docs.opsi.org${C_NC}"
  echo ""

  # Registrar no log
  cat >> "$LOG" << RESUMO

══════════════════════════════════════
INSTALAÇÃO CONCLUÍDA
Data:     $(date)
Servidor: ${SERVER_HOSTNAME}.${SERVER_DOMAIN} (${SERVER_IP})
OPSI URL: https://${SERVER_IP}:${PORTA_HTTPS}
Usuário:  adminuser
Versão:   OPSI ${VERSAO_OPSI}
Status:   SUCESSO
══════════════════════════════════════
RESUMO
}

# ──────────────────────────────────────────────
#  MAIN — Execução principal
# ──────────────────────────────────────────────
main() {
  init
  detectar_so
  verificar_hardware
  verificar_portas
  instalar_docker
  gerar_credenciais
  criar_compose
  subir_containers
  configurar_systemd
  instalar_helper
  mostrar_resumo
}

main "$@"
