#!/usr/bin/env bash
# ============================================================
#  OPSI Server — Instalador Automático para Linux
#  Versão: 1.2  |  Hepta Tecnologia e Informática Ltda.
#
#  Sistemas suportados:
#    Ubuntu 20.04, 22.04, 24.04, 26.04
#    Debian 11 (Bullseye), 12 (Bookworm)
#
#  USO:
#    curl -fsSL https://raw.githubusercontent.com/ncaratti/insight-manager/main/instalar-opsi-standalone.sh -o /tmp/instalar-opsi.sh
#    sudo bash /tmp/instalar-opsi.sh
#
#  Changelog v1.2:
#    - Imagem corrigida: uibmz/opsi-server:4.3 (oficial uib GmbH)
#    - MariaDB 10.11 no lugar de MySQL 8.0 (conforme compose oficial OPSI)
#    - REDIS_PASSWORD adicionado ao Redis e ao OPSI
#    - OPSI_DOMAIN com fallback para "local" quando vazio
#    - Porta 445 (Samba) removida — usa WebDAV como protocolo depot
#    - Verificação de portas sem interação — continua automaticamente
#    - Compatibilidade com aarch64 (Ubuntu em ARM/Apple Silicon)
#    - gerar_senha reescrita sem dependência de tr+urandom+pipe
#    - version: obsoleto removido do docker-compose
# ============================================================

set -eo pipefail

# ──────────────────────────────────────────────
#  Constantes
# ──────────────────────────────────────────────
VERSAO_SCRIPT="1.2"
VERSAO_OPSI="4.3"
DIR_INSTALACAO="/opt/opsi-server"
LOG="/var/log/opsi-install.log"
PORTA_HTTPS="4447"
PORTA_TFTP="69"
REDIS_PASS="opsiRedis$(date +%Y)"

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
titulo(){ echo -e "\n${C_BOLD}${C_CYAN}══════════════════════════════════════${C_NC}" | tee -a "$LOG"
          echo -e "${C_BOLD}${C_CYAN}  $*${C_NC}" | tee -a "$LOG"
          echo -e "${C_BOLD}${C_CYAN}══════════════════════════════════════${C_NC}" | tee -a "$LOG"; }

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
  ║  • OPSI ${VERSAO_OPSI} (uibmz/opsi-server)               ║
  ║  • MariaDB 10.11 + Redis 7 + Grafana              ║
  ║  • Serviço systemd + helper CLI                   ║
  ╚═══════════════════════════════════════════════════╝

BANNER
}

# ──────────────────────────────────────────────
#  Utilitários
# ──────────────────────────────────────────────
gerar_senha() {
  local senha=""
  local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  local len=${#chars}
  for i in $(seq 1 20); do
    local idx=$(( RANDOM % len ))
    senha="${senha}${chars:$idx:1}"
  done
  echo "$senha"
}

porta_em_uso() {
  ss -tlnup 2>/dev/null | grep -q ":${1} " && return 0 || return 1
}

detectar_ip_local() {
  local ip=""
  ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}') || true
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  fi
  if [ -z "$ip" ]; then
    ip="127.0.0.1"
  fi
  echo "$ip"
}

aguardar_opsi() {
  local url="https://localhost:${PORTA_HTTPS}/admin"
  local tentativas=0
  local max=36
  log "Aguardando OPSI inicializar (até 3 minutos)..."
  while ! curl -sk --max-time 4 "$url" &>/dev/null; do
    tentativas=$((tentativas + 1))
    [ $tentativas -ge $max ] && erro "OPSI não ficou pronto. Verifique: docker compose -f ${DIR_INSTALACAO}/docker-compose.yml logs opsiconfd"
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
  log "Script v${VERSAO_SCRIPT} iniciado. Log em: ${LOG}"
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERRO: Execute como root: sudo bash $0"
    exit 1
  fi
}

# ──────────────────────────────────────────────
#  ETAPA 1 — Detectar SO
# ──────────────────────────────────────────────
detectar_so() {
  titulo "Etapa 1/9 — Detectando sistema operacional"

  source /etc/os-release || true
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-0}"
  ARCH=$(uname -m)

  log "Sistema: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
  log "Arquitetura: ${ARCH}"

  case "$OS_ID" in
    ubuntu)
      case "$OS_VERSION" in
        20.04|22.04|24.04|26.04) ok "Ubuntu ${OS_VERSION} — suportado." ;;
        *) warn "Ubuntu ${OS_VERSION} não testado. Prosseguindo..." ;;
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
      warn "Sistema '${OS_ID}' não reconhecido. Tentando prosseguir..."
      PKG_MANAGER="apt-get"
      ;;
  esac

  [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ] && \
    warn "Arquitetura ${ARCH} — suporte experimental."
}

# ──────────────────────────────────────────────
#  ETAPA 2 — Verificar hardware
# ──────────────────────────────────────────────
verificar_hardware() {
  titulo "Etapa 2/9 — Verificando recursos do servidor"

  local ram_mb disk_gb cpu_count
  ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo) || ram_mb=0
  disk_gb=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}') || disk_gb=0
  cpu_count=$(nproc) || cpu_count=1

  log "RAM:   ${ram_mb} MB"
  log "Disco: ${disk_gb} GB livres"
  log "CPUs:  ${cpu_count}"

  [ "$ram_mb" -lt 2048 ] && erro "RAM insuficiente: ${ram_mb} MB. Mínimo: 2048 MB."
  [ "$disk_gb" -lt 15 ]  && erro "Disco insuficiente: ${disk_gb} GB. Mínimo: 15 GB."
  [ "$ram_mb" -lt 4096 ] && warn "RAM abaixo do recomendado (${ram_mb} MB < 4096 MB)."
  [ "$disk_gb" -lt 50 ]  && warn "Disco abaixo do ideal (${disk_gb} GB < 50 GB)."

  ok "Hardware verificado."
}

# ──────────────────────────────────────────────
#  ETAPA 3 — Verificar portas
# ──────────────────────────────────────────────
verificar_portas() {
  titulo "Etapa 3/9 — Verificando portas de rede"

  if porta_em_uso "$PORTA_HTTPS"; then
    warn "Porta TCP ${PORTA_HTTPS} já em uso. O OPSI pode não funcionar."
  else
    ok "Porta TCP ${PORTA_HTTPS} — livre."
  fi

  if porta_em_uso "$PORTA_TFTP"; then
    warn "Porta UDP ${PORTA_TFTP} (TFTP) já em uso. Netboot pode não funcionar."
  else
    ok "Porta UDP ${PORTA_TFTP} (TFTP) — livre."
  fi

  # Porta 445 não é mais usada (WebDAV como protocolo depot)
  warn "Porta 445 (Samba) não é utilizada — OPSI usa WebDAV como protocolo depot."
  ok "Verificação de portas concluída."
}

# ──────────────────────────────────────────────
#  ETAPA 4 — Instalar Docker
# ──────────────────────────────────────────────
instalar_docker() {
  titulo "Etapa 4/9 — Instalando Docker"

  if command -v docker &>/dev/null; then
    local ver
    ver=$(docker --version | grep -oP '[\d.]+' | head -1) || ver="desconhecida"
    ok "Docker já instalado: v${ver}"
  else
    log "Instalando Docker via script oficial..."
    export DEBIAN_FRONTEND=noninteractive
    $PKG_MANAGER update -qq >> "$LOG" 2>&1 || true
    $PKG_MANAGER install -y -qq curl ca-certificates >> "$LOG" 2>&1 || true
    curl -fsSL https://get.docker.com | bash >> "$LOG" 2>&1
    systemctl enable --now docker >> "$LOG" 2>&1 || true
    ok "Docker instalado."
  fi

  if docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose v2 — disponível."
  elif command -v docker-compose &>/dev/null; then
    ok "Docker Compose standalone — disponível."
  else
    log "Instalando Docker Compose plugin..."
    $PKG_MANAGER install -y -qq docker-compose-plugin >> "$LOG" 2>&1 || true
    ok "Docker Compose instalado."
  fi

  docker run --rm hello-world >> "$LOG" 2>&1 && ok "Docker funcionando corretamente." || \
    warn "Teste do Docker retornou aviso — prosseguindo."
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
  SERVER_HOSTNAME=$(hostname -s 2>/dev/null || echo "opsi-server")
  SERVER_DOMAIN=$(hostname -d 2>/dev/null || echo "local")
  [ -z "$SERVER_DOMAIN" ] && SERVER_DOMAIN="local"

  log "IP:       ${SERVER_IP}"
  log "Hostname: ${SERVER_HOSTNAME}.${SERVER_DOMAIN}"

  cat > "${DIR_INSTALACAO}/.credentials" << CREDS
# ============================================================
#  OPSI Server — Credenciais de Acesso
#  Gerado em: $(date)
#  ATENÇÃO: Guarde este arquivo em local seguro!
# ============================================================

OPSI_URL=https://${SERVER_IP}:${PORTA_HTTPS}
OPSI_USUARIO=adminuser
OPSI_SENHA=${OPSI_ADMIN_PASS}

MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
MYSQL_PASSWORD=${MYSQL_OPSI_PASS}

REDIS_PASSWORD=${REDIS_PASS}

GRAFANA_URL=https://${SERVER_IP}:${PORTA_HTTPS}/grafana
GRAFANA_USUARIO=admin
GRAFANA_SENHA=${GRAFANA_PASS}

SERVER_IP=${SERVER_IP}
SERVER_HOSTNAME=${SERVER_HOSTNAME}
SERVER_DOMAIN=${SERVER_DOMAIN}
CREDS
  chmod 600 "${DIR_INSTALACAO}/.credentials"
  ok "Credenciais geradas em ${DIR_INSTALACAO}/.credentials"
}

# ──────────────────────────────────────────────
#  ETAPA 6 — Criar docker-compose.yml
# ──────────────────────────────────────────────
criar_compose() {
  titulo "Etapa 6/9 — Criando configuração Docker Compose"

  # .env
  cat > "${DIR_INSTALACAO}/.env" << ENV
OPSI_HOSTNAME=${SERVER_HOSTNAME}
OPSI_DOMAIN=${SERVER_DOMAIN}
OPSI_ADMIN_PASSWORD=${OPSI_ADMIN_PASS}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
MYSQL_PASSWORD=${MYSQL_OPSI_PASS}
MYSQL_DATABASE=opsi
MYSQL_USER=opsi
REDIS_PASSWORD=${REDIS_PASS}
GRAFANA_PASSWORD=${GRAFANA_PASS}
ENV
  chmod 600 "${DIR_INSTALACAO}/.env"

  # docker-compose.yml
  cat > "${DIR_INSTALACAO}/docker-compose.yml" << COMPOSE
# OPSI Server ${VERSAO_OPSI} — Hepta Tecnologia
# Gerado em: $(date)

x-restart: &sempre
  restart: unless-stopped

services:

  # ── Banco de dados (MariaDB — conforme compose oficial OPSI) ──
  mysql:
    image: mariadb:10.11
    <<: *sempre
    command: --max_connections=1000 --max_allowed_packet=256M --sort_buffer_size=4M
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - mysql-data:/var/lib/mysql
    networks: [opsi-net]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s

  # ── Cache com senha obrigatória ───────────────────────────────
  redis:
    image: redis:7-alpine
    <<: *sempre
    command: redis-server --appendonly yes --requirepass \${REDIS_PASSWORD}
    volumes:
      - redis-data:/data
    networks: [opsi-net]
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 10s

  # ── Dashboards ────────────────────────────────────────────────
  grafana:
    image: grafana/grafana:latest
    <<: *sempre
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: \${GRAFANA_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana-data:/var/lib/grafana
    networks: [opsi-net]

  # ── OPSI Config Server (imagem oficial uib GmbH) ─────────────
  opsiconfd:
    image: uibmz/opsi-server:4.3
    <<: *sempre
    hostname: \${OPSI_HOSTNAME}
    domainname: \${OPSI_DOMAIN}
    environment:
      OPSI_HOST_ROLE: configserver
      OPSI_HOSTNAME: \${OPSI_HOSTNAME}
      OPSI_DOMAIN: \${OPSI_DOMAIN}
      OPSI_ADMIN_PASSWORD: \${OPSI_ADMIN_PASSWORD}
      MYSQL_HOST: mysql
      MYSQL_PORT: 3306
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
      REDIS_HOST: redis
      REDIS_PASSWORD: \${REDIS_PASSWORD}
      GRAFANA_HOST: grafana
      GF_SECURITY_ADMIN_PASSWORD: \${GRAFANA_PASSWORD}
      OPSI_TFTPBOOT: "true"
    ports:
      - "${PORTA_HTTPS}:4447"
      - "${PORTA_TFTP}:69/udp"
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

  ok "docker-compose.yml criado em ${DIR_INSTALACAO}/"
}

# ──────────────────────────────────────────────
#  ETAPA 7 — Subir containers
# ──────────────────────────────────────────────
subir_containers() {
  titulo "Etapa 7/9 — Baixando imagens e iniciando OPSI"

  cd "${DIR_INSTALACAO}"

  log "Baixando imagens Docker..."
  docker compose pull 2>&1 | tee -a "$LOG" | grep -E "Pulling|Downloaded|already" || true

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
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${DIR_INSTALACAO}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload >> "$LOG" 2>&1 || true
  systemctl enable opsi-server.service >> "$LOG" 2>&1 || true
  ok "Serviço 'opsi-server' habilitado."
}

# ──────────────────────────────────────────────
#  ETAPA 9 — Instalar helper CLI
# ──────────────────────────────────────────────
instalar_helper() {
  titulo "Etapa 9/9 — Instalando helper de linha de comando"

  cat > /usr/local/bin/opsi-server << 'HELPER'
#!/usr/bin/env bash
DIR="/opt/opsi-server"
CREDS="${DIR}/.credentials"
COMPOSE="docker compose -f ${DIR}/docker-compose.yml"

_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
_erro() { echo -e "\033[0;31m[ERRO]\033[0m  $*"; exit 1; }

case "${1:-ajuda}" in
  status)
    echo ""
    echo "  ── Containers ──────────────────────────────"
    $COMPOSE ps
    echo ""
    ;;
  logs)
    shift
    $COMPOSE logs -f --tail=100 "${@:-opsiconfd}"
    ;;
  start)   $COMPOSE up -d && _ok "OPSI iniciado." ;;
  stop)    $COMPOSE stop && _ok "OPSI parado." ;;
  restart) $COMPOSE restart opsiconfd && _ok "OPSI reiniciado." ;;
  update)  $COMPOSE pull && $COMPOSE up -d && _ok "OPSI atualizado." ;;
  backup)
    DEST="/var/backups/opsi"
    TS=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$DEST"
    source "${DIR}/.env" 2>/dev/null || true
    _info "Fazendo backup..."
    $COMPOSE exec -T mysql mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" \
      --all-databases --single-transaction > "${DEST}/opsi-db-${TS}.sql" \
      && _ok "Backup: ${DEST}/opsi-db-${TS}.sql" \
      || _warn "Falha no backup."
    ;;
  credenciais)
    echo ""
    echo "  ── Credenciais do OPSI ──────────────────────"
    grep -v "^#" "$CREDS" | grep -v "^$" | while IFS='=' read -r chave valor; do
      printf "  %-25s %s\n" "${chave}:" "${valor}"
    done
    echo ""
    ;;
  testar-api)
    source "${CREDS}" 2>/dev/null || _erro "Credenciais não encontradas."
    _info "Testando API JSON-RPC..."
    curl -sk -u "adminuser:${OPSI_SENHA}" \
      -X POST "https://localhost:4447/rpc" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"backend_info","params":[]}' \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print('  Versão OPSI:', d['result'].get('opsiVersion','?'))" \
      && _ok "API respondendo." || _warn "Verifique os logs: opsi-server logs"
    ;;
  listar-clientes)
    source "${CREDS}" 2>/dev/null || true
    curl -sk -u "adminuser:${OPSI_SENHA}" \
      -X POST "https://localhost:4447/rpc" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"host_getObjects","params":[["id","lastSeen"],{"type":"OpsiClient"}]}' \
      | python3 -c "
import sys,json
data=json.load(sys.stdin)
clientes=data.get('result',[])
print(f'\n  Total: {len(clientes)} clientes\n')
for c in clientes[:20]: print(f'  {c.get(\"id\",\"?\")} — último acesso: {c.get(\"lastSeen\",\"nunca\")}')
" 2>/dev/null || echo "  Nenhum cliente registrado."
    ;;
  *)
    cat << USO
  Uso: opsi-server <comando>
  Comandos:
    status           Ver containers
    logs [serviço]   Logs em tempo real
    start            Iniciar
    stop             Parar
    restart          Reiniciar
    update           Atualizar imagens
    backup           Backup do banco
    credenciais      Ver usuário e senha
    testar-api       Testar API JSON-RPC
    listar-clientes  Ver endpoints registrados
USO
    ;;
esac
HELPER

  chmod +x /usr/local/bin/opsi-server
  ok "Helper 'opsi-server' instalado."
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
  echo -e "  Usuário:  adminuser"
  echo -e "  Senha:    ${OPSI_ADMIN_PASS}"
  echo ""
  echo -e "  ${C_BOLD}Credenciais completas:${C_NC} ${DIR_INSTALACAO}/.credentials"
  echo -e "  ${C_BOLD}Log da instalação:${C_NC}    ${LOG}"
  echo ""
  echo -e "  ${C_BOLD}Comandos úteis:${C_NC}"
  echo -e "  opsi-server status        — ver containers"
  echo -e "  opsi-server credenciais   — ver usuário e senha"
  echo -e "  opsi-server testar-api    — testar API JSON-RPC"
  echo -e "  opsi-server logs          — logs em tempo real"
  echo ""
}

# ──────────────────────────────────────────────
#  MAIN
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
