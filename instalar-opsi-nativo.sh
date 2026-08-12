#!/usr/bin/env bash
# ============================================================
#  OPSI Server 4.3 — Instalador Nativo (sem Docker)
#  Versão: 1.3  |  Insight Manager
#
#  Compatível com:
#    Ubuntu 22.04, 24.04 (amd64)
#    Debian 11, 12
#
#  USO:
#    curl -fsSL https://raw.githubusercontent.com/ncaratti/insight-manager/main/instalar-opsi-nativo.sh -o /tmp/instalar-opsi-nativo.sh
#    sudo bash /tmp/instalar-opsi-nativo.sh
#
#  Changelog v1.3:
#    - Redis 7.4 instalado do repositório oficial (redis.io)
#    - Override systemd para Redis (Type=forking)
#    - mysql.conf com formato Python correto ('address' em vez de 'host')
#    - Usuário adminuser criado no grupo opsiadmin
#    - Senha do adminuser definida via chpasswd
#    - RDB do Redis apagado antes de iniciar
#    - Ordem correta de inicialização: MariaDB → Redis → opsiconfd
# ============================================================

set -eo pipefail

# ──────────────────────────────────────────────
#  Constantes
# ──────────────────────────────────────────────
VERSAO_SCRIPT="1.3"
VERSAO_OPSI="4.3"
LOG="/var/log/opsi-install-nativo.log"
REPO_BASE="https://download.opensuse.org/repositories/home:/uibmz:/opsi:/4.3:/stable"
REPO_KEY="/usr/local/share/keyrings/opsi-obs.gpg"

# ──────────────────────────────────────────────
#  Cores
# ──────────────────────────────────────────────
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_NC='\033[0m'

_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()   { echo -e "$(_ts) ${C_BLUE}[INFO]${C_NC}  $*" | tee -a "$LOG"; }
ok()    { echo -e "$(_ts) ${C_GREEN}[  OK]${C_NC}  $*" | tee -a "$LOG"; }
warn()  { echo -e "$(_ts) ${C_YELLOW}[WARN]${C_NC}  $*" | tee -a "$LOG"; }
erro()  { echo -e "$(_ts) ${C_RED}[ERRO]${C_NC}  $*" | tee -a "$LOG"; exit 1; }
titulo(){ echo -e "\n${C_BOLD}${C_CYAN}══════════════════════════════════════${C_NC}" | tee -a "$LOG"
          echo -e "${C_BOLD}${C_CYAN}  $*${C_NC}" | tee -a "$LOG"
          echo -e "${C_BOLD}${C_CYAN}══════════════════════════════════════${C_NC}" | tee -a "$LOG"; }

gerar_senha() {
  local senha="" chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  local len=${#chars}
  for i in $(seq 1 20); do
    senha="${senha}${chars:$(( RANDOM % len )):1}"
  done
  echo "$senha"
}

detectar_ip() {
  local ip=""
  ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}') || true
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  [ -z "$ip" ] && ip="127.0.0.1"
  echo "$ip"
}

# ──────────────────────────────────────────────
#  Banner
# ──────────────────────────────────────────────
mostrar_banner() {
cat << BANNER

  ╔═══════════════════════════════════════════════════╗
  ║                                                   ║
  ║   OPSI Server ${VERSAO_OPSI} — Instalação Nativa         ║
  ║   Versão do script: ${VERSAO_SCRIPT}                      ║
  ║   Insight Manager                                 ║
  ║                                                   ║
  ╠═══════════════════════════════════════════════════╣
  ║  Modo: instalação nativa via apt (sem Docker)     ║
  ║  Compatível com Ubuntu 22.04/24.04 amd64          ║
  ║                                                   ║
  ║  O que será instalado:                            ║
  ║  • MariaDB (banco de dados)                       ║
  ║  • Redis 7.4 + RedisTimeSeries (cache)            ║
  ║  • opsiconfd 4.3 (servidor OPSI)                  ║
  ║  • opsi-utils + opsi-tftpd                        ║
  ╚═══════════════════════════════════════════════════╝

BANNER
}

# ──────────────────────────────────────────────
#  ETAPA 0 — Init
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
  titulo "Etapa 1/8 — Detectando sistema operacional"

  source /etc/os-release || true
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-0}"
  ARCH=$(uname -m)

  log "Sistema: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
  log "Arquitetura: ${ARCH}"

  [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ] && \
    warn "Arquitetura ${ARCH} — OPSI requer x86_64. A instalação pode falhar."

  case "$OS_ID" in
    ubuntu)
      case "$OS_VERSION" in
        22.04) REPO_OS="xUbuntu_22.04" ; CODENAME="jammy" ;;
        24.04) REPO_OS="xUbuntu_24.04" ; CODENAME="noble" ;;
        *)     REPO_OS="xUbuntu_24.04" ; CODENAME="noble"
               warn "Ubuntu ${OS_VERSION} — usando repo 24.04" ;;
      esac
      PKG_MANAGER="apt-get"
      ;;
    debian)
      case "$OS_VERSION" in
        11) REPO_OS="Debian_11" ; CODENAME="bullseye" ;;
        12) REPO_OS="Debian_12" ; CODENAME="bookworm" ;;
        *)  REPO_OS="Debian_12" ; CODENAME="bookworm"
            warn "Debian ${OS_VERSION} — usando repo 12" ;;
      esac
      PKG_MANAGER="apt-get"
      ;;
    *)
      REPO_OS="xUbuntu_24.04" ; CODENAME="noble" ; PKG_MANAGER="apt-get"
      warn "Sistema não reconhecido — tentando com Ubuntu 24.04"
      ;;
  esac

  REPO_URL="${REPO_BASE}/${REPO_OS}"
  log "Repositório OPSI: ${REPO_URL}"
  ok "SO: ${OS_ID} ${OS_VERSION} (${ARCH})"
}

# ──────────────────────────────────────────────
#  ETAPA 2 — Instalar dependências base
# ──────────────────────────────────────────────
instalar_dependencias() {
  titulo "Etapa 2/8 — Instalando dependências"

  export DEBIAN_FRONTEND=noninteractive
  $PKG_MANAGER update -qq >> "$LOG" 2>&1
  $PKG_MANAGER install -y -qq \
    curl wget gnupg2 apt-transport-https \
    ca-certificates lsb-release \
    mariadb-server \
    >> "$LOG" 2>&1

  systemctl enable --now mariadb >> "$LOG" 2>&1 || true
  ok "MariaDB instalado e iniciado."
}

# ──────────────────────────────────────────────
#  ETAPA 3 — Instalar Redis 7.4
# ──────────────────────────────────────────────
instalar_redis() {
  titulo "Etapa 3/8 — Instalando Redis 7.4"

  # Adicionar repositório oficial Redis
  log "Adicionando repositório Redis oficial..."
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${CODENAME} main" | \
    tee /etc/apt/sources.list.d/redis.list > /dev/null
  $PKG_MANAGER update -qq >> "$LOG" 2>&1

  # Instalar Redis 7.4 (compatível com redistimeseries 1.6.x)
  log "Instalando Redis 7.4..."
  $PKG_MANAGER install -y -qq \
    --allow-downgrades \
    redis-server=6:7.4.10-1rl1~${CODENAME}1 \
    redis-tools=6:7.4.10-1rl1~${CODENAME}1 \
    >> "$LOG" 2>&1 || \
  $PKG_MANAGER install -y -qq redis-server >> "$LOG" 2>&1

  redis-server --version | tee -a "$LOG"

  # Override systemd para Type=forking (Redis 7 com daemonize yes)
  mkdir -p /etc/systemd/system/redis-server.service.d
  cat > /etc/systemd/system/redis-server.service.d/override.conf << EOF
[Service]
Type=forking
ExecStart=
ExecStart=/usr/bin/redis-server /etc/redis/redis.conf
EOF

  # Configurar daemonize yes no redis.conf
  grep -q "^daemonize yes" /etc/redis/redis.conf || \
    sed -i 's/^daemonize no/daemonize yes/' /etc/redis/redis.conf

  systemctl daemon-reload >> "$LOG" 2>&1 || true
  ok "Redis 7.4 configurado."
}

# ──────────────────────────────────────────────
#  ETAPA 4 — Configurar MariaDB
# ──────────────────────────────────────────────
configurar_mariadb() {
  titulo "Etapa 4/8 — Configurando banco de dados"

  MYSQL_ROOT_PASS=$(gerar_senha)
  MYSQL_OPSI_PASS=$(gerar_senha)

  log "Criando banco e usuário OPSI..."
  mysql -u root << SQL >> "$LOG" 2>&1
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
CREATE DATABASE IF NOT EXISTS opsi CHARACTER SET utf8 COLLATE utf8_general_ci;
DROP USER IF EXISTS 'opsi'@'localhost';
CREATE USER 'opsi'@'localhost' IDENTIFIED BY '${MYSQL_OPSI_PASS}';
GRANT ALL PRIVILEGES ON opsi.* TO 'opsi'@'localhost';
FLUSH PRIVILEGES;
SQL

  cat > /root/.my.cnf << CNF
[client]
user=root
password=${MYSQL_ROOT_PASS}
CNF
  chmod 600 /root/.my.cnf
  ok "Banco de dados configurado."
}

# ──────────────────────────────────────────────
#  ETAPA 5 — Adicionar repositório OPSI
# ──────────────────────────────────────────────
adicionar_repositorio_opsi() {
  titulo "Etapa 5/8 — Adicionando repositório OPSI"

  mkdir -p "$(dirname "$REPO_KEY")"
  curl -fsSL "${REPO_URL}/Release.key" | gpg --dearmor | tee "$REPO_KEY" > /dev/null
  echo "deb [signed-by=${REPO_KEY}] ${REPO_URL}/ /" | \
    tee /etc/apt/sources.list.d/opsi.list > /dev/null
  $PKG_MANAGER update -qq >> "$LOG" 2>&1
  ok "Repositório OPSI adicionado."
}

# ──────────────────────────────────────────────
#  ETAPA 6 — Instalar OPSI + RedisTimeSeries
# ──────────────────────────────────────────────
instalar_opsi() {
  titulo "Etapa 6/8 — Instalando OPSI e RedisTimeSeries"

  $PKG_MANAGER install -y -qq \
    opsiconfd \
    opsi-utils \
    opsi-tftpd-hpa \
    redis-timeseries \
    >> "$LOG" 2>&1

  ok "Pacotes OPSI instalados."

  # Adicionar RedisTimeSeries ao Redis
  grep -q "redistimeseries" /etc/redis/redis.conf || \
    echo "loadmodule /usr/lib/redis/modules/redistimeseries.so" >> /etc/redis/redis.conf

  # Apagar RDB antigo para evitar conflitos de módulo
  rm -f /var/lib/redis/dump.rdb

  # Iniciar Redis com o módulo
  systemctl reset-failed redis-server 2>/dev/null || true
  systemctl start redis-server >> "$LOG" 2>&1
  sleep 5

  if redis-cli ping | grep -q PONG; then
    ok "Redis iniciado com RedisTimeSeries."
  else
    warn "Redis não respondeu — verificando logs..."
    tail -5 /var/log/redis/redis-server.log | tee -a "$LOG"
  fi
}

# ──────────────────────────────────────────────
#  ETAPA 7 — Configurar OPSI
# ──────────────────────────────────────────────
configurar_opsi() {
  titulo "Etapa 7/8 — Configurando OPSI"

  SERVER_IP=$(detectar_ip)
  SERVER_HOSTNAME=$(hostname -s 2>/dev/null || echo "opsi-server")
  SERVER_DOMAIN=$(hostname -d 2>/dev/null || echo "local")
  [ -z "$SERVER_DOMAIN" ] && SERVER_DOMAIN="local"
  OPSI_ADMIN_PASS=$(gerar_senha)

  log "Hostname: ${SERVER_HOSTNAME}.${SERVER_DOMAIN}"
  log "IP: ${SERVER_IP}"

  # mysql.conf com formato Python correto
  mkdir -p /etc/opsi/backends
  cat > /etc/opsi/backends/mysql.conf << EOF
# -*- coding: utf-8 -*-
config = {
    'address': 'localhost',
    'database': 'opsi',
    'username': 'opsi',
    'password': '${MYSQL_OPSI_PASS}',
}
EOF

  # opsiconfd.conf mínimo
  cat > /etc/opsi/opsiconfd.conf << EOF
log-mode=local
redis-internal-url=redis://127.0.0.1:6379
EOF

  # Setup inicial do OPSI
  log "Executando opsiconfd setup..."
  opsiconfd setup --configure-mysql >> "$LOG" 2>&1 || true

  # Criar usuário adminuser no grupo opsiadmin
  log "Criando usuário adminuser..."
  useradd -m -s /bin/bash adminuser >> "$LOG" 2>&1 || true
  usermod -aG opsiadmin adminuser >> "$LOG" 2>&1 || true
  echo "adminuser:${OPSI_ADMIN_PASS}" | chpasswd >> "$LOG" 2>&1

  # Definir senha do depot user pcpatch
  opsiconfd setup --set-depot-user-password "${OPSI_ADMIN_PASS}" >> "$LOG" 2>&1 || true

  # Iniciar opsiconfd
  systemctl enable --now opsiconfd >> "$LOG" 2>&1 || true
  sleep 15

  # Verificar se a porta 4447 está escutando
  if ss -tlnp | grep -q ":4447"; then
    ok "OPSI disponível em https://${SERVER_IP}:4447"
  else
    warn "Porta 4447 não detectada — verifique: journalctl -u opsiconfd"
  fi

  # Salvar credenciais
  mkdir -p /etc/opsi
  cat > /etc/opsi/.credentials << CREDS
# ============================================================
#  OPSI Server — Credenciais de Acesso
#  Gerado em: $(date)
#  ATENÇÃO: Guarde este arquivo em local seguro!
# ============================================================

OPSI_URL=https://${SERVER_IP}:4447
OPSI_USUARIO=adminuser
OPSI_SENHA=${OPSI_ADMIN_PASS}

MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
MYSQL_OPSI_PASSWORD=${MYSQL_OPSI_PASS}

SERVER_IP=${SERVER_IP}
SERVER_HOSTNAME=${SERVER_HOSTNAME}
SERVER_DOMAIN=${SERVER_DOMAIN}
CREDS
  chmod 600 /etc/opsi/.credentials
  ok "Credenciais salvas em /etc/opsi/.credentials"
}

# ──────────────────────────────────────────────
#  ETAPA 8 — Instalar helper CLI
# ──────────────────────────────────────────────
instalar_helper() {
  titulo "Etapa 8/8 — Instalando helper de linha de comando"

  cat > /usr/local/bin/opsi-server << 'HELPER'
#!/usr/bin/env bash
CREDS="/etc/opsi/.credentials"

_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

case "${1:-ajuda}" in
  status)
    echo ""
    echo "  ── Serviços OPSI ───────────────────────────"
    systemctl status opsiconfd  --no-pager -l 2>/dev/null | grep -E "Active|Main PID"
    systemctl status mariadb    --no-pager -l 2>/dev/null | grep -E "Active|Main PID"
    systemctl status redis-server --no-pager -l 2>/dev/null | grep -E "Active|Main PID"
    echo ""
    ;;
  logs)
    journalctl -u opsiconfd -f --no-pager
    ;;
  start)
    systemctl start mariadb redis-server opsiconfd
    _ok "Serviços iniciados."
    ;;
  stop)
    systemctl stop opsiconfd
    _ok "OPSI parado."
    ;;
  restart)
    systemctl restart opsiconfd
    _ok "OPSI reiniciado."
    ;;
  credenciais)
    echo ""
    echo "  ── Credenciais do OPSI ──────────────────────"
    sudo grep -v "^#" "$CREDS" | grep -v "^$" | while IFS='=' read -r chave valor; do
      printf "  %-25s %s\n" "${chave}:" "${valor}"
    done
    echo ""
    ;;
  testar-api)
    source <(sudo grep -E "OPSI_SENHA|OPSI_URL" "$CREDS" 2>/dev/null) || true
    _info "Testando API JSON-RPC em ${OPSI_URL}..."
    RESP=$(curl -sk -u "adminuser:${OPSI_SENHA}" \
      -X POST "${OPSI_URL}/rpc" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"backend_info","params":[]}')
    VERSION=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('opsiVersion','?'))" 2>/dev/null)
    if [ -n "$VERSION" ] && [ "$VERSION" != "?" ]; then
      _ok "API respondendo — OPSI versão: ${VERSION}"
    else
      _warn "API não respondeu corretamente. Resposta: ${RESP}"
    fi
    ;;
  listar-clientes)
    source <(sudo grep -E "OPSI_SENHA|OPSI_URL" "$CREDS" 2>/dev/null) || true
    curl -sk -u "adminuser:${OPSI_SENHA}" \
      -X POST "${OPSI_URL}/rpc" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"host_getObjects","params":[["id","lastSeen"],{"type":"OpsiClient"}]}' \
      | python3 -c "
import sys,json
data=json.load(sys.stdin)
clientes=data.get('result',[])
print(f'\n  Total: {len(clientes)} clientes\n')
for c in clientes[:20]: print(f'  {c.get(\"id\",\"?\")} — {c.get(\"lastSeen\",\"nunca\")}')
" 2>/dev/null || echo "  Nenhum cliente ainda."
    ;;
  *)
    cat << USO
  Uso: opsi-server <comando>
  Comandos:
    status           Ver serviços
    logs             Logs em tempo real
    start            Iniciar serviços
    stop             Parar OPSI
    restart          Reiniciar OPSI
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
  echo -e "${C_GREEN}║    Instalação nativa concluída com sucesso!  ✓       ║${C_NC}"
  echo -e "${C_GREEN}╚══════════════════════════════════════════════════════╝${C_NC}"
  echo ""
  echo -e "  ${C_BOLD}Acesso ao OPSI${C_NC}"
  echo -e "  WebGUI:   ${C_BLUE}https://$(detectar_ip):4447${C_NC}"
  echo -e "  Usuário:  adminuser"
  echo -e "  Senha:    ${OPSI_ADMIN_PASS}"
  echo ""
  echo -e "  ${C_BOLD}Credenciais:${C_NC} /etc/opsi/.credentials"
  echo -e "  ${C_BOLD}Log:${C_NC}         ${LOG}"
  echo ""
  echo -e "  ${C_BOLD}Comandos úteis:${C_NC}"
  echo -e "  opsi-server status        — ver serviços"
  echo -e "  opsi-server credenciais   — ver usuário e senha"
  echo -e "  opsi-server testar-api    — testar API JSON-RPC"
  echo -e "  opsi-server logs          — logs em tempo real"
  echo ""
  echo -e "  ${C_BOLD}Configurar no Insight Manager:${C_NC}"
  echo -e "  Configurações → Conexão OPSI"
  echo -e "  URL:      https://$(detectar_ip):4447"
  echo -e "  Usuário:  adminuser"
  echo -e "  Senha:    ${OPSI_ADMIN_PASS}"
  echo ""
}

# ──────────────────────────────────────────────
#  MAIN
# ──────────────────────────────────────────────
main() {
  init
  detectar_so
  instalar_dependencias
  instalar_redis
  configurar_mariadb
  adicionar_repositorio_opsi
  instalar_opsi
  configurar_opsi
  instalar_helper
  mostrar_resumo
}

main "$@"
