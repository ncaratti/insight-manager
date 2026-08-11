#!/usr/bin/env bash
# ============================================================
#  OPSI Server 4.3 — Instalador Nativo (sem Docker)
#  Versão: 1.0  |  Insight Manager
#
#  Compatível com:
#    Ubuntu 20.04, 22.04, 24.04, 26.04 (amd64 e aarch64)
#    Debian 11 (Bullseye), 12 (Bookworm)
#
#  USO:
#    curl -fsSL https://raw.githubusercontent.com/ncaratti/insight-manager/main/instalar-opsi-nativo.sh -o /tmp/instalar-opsi-nativo.sh
#    sudo bash /tmp/instalar-opsi-nativo.sh
# ============================================================

set -eo pipefail

# ──────────────────────────────────────────────
#  Constantes
# ──────────────────────────────────────────────
VERSAO_SCRIPT="1.0"
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
  ║  Compatível com amd64 e aarch64                   ║
  ║                                                   ║
  ║  O que será instalado:                            ║
  ║  • MariaDB (banco de dados)                       ║
  ║  • Redis (cache)                                  ║
  ║  • opsiconfd (servidor OPSI)                      ║
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
  titulo "Etapa 1/7 — Detectando sistema operacional"

  source /etc/os-release || true
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-0}"
  ARCH=$(uname -m)

  log "Sistema: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
  log "Arquitetura: ${ARCH}"

  # Mapear versão do Ubuntu/Debian para o ID do repositório OPSI
  case "$OS_ID" in
    ubuntu)
      case "$OS_VERSION" in
        20.04) REPO_OS="xUbuntu_20.04" ;;
        22.04) REPO_OS="xUbuntu_22.04" ;;
        24.04) REPO_OS="xUbuntu_24.04" ;;
        26.04) REPO_OS="xUbuntu_24.04" ;; # usar repo 24.04 para 26.04
        *)     REPO_OS="xUbuntu_24.04" ; warn "Versão Ubuntu ${OS_VERSION} — usando repo 24.04" ;;
      esac
      PKG_MANAGER="apt-get"
      ;;
    debian)
      case "$OS_VERSION" in
        11) REPO_OS="Debian_11" ;;
        12) REPO_OS="Debian_12" ;;
        *)  REPO_OS="Debian_12" ; warn "Versão Debian ${OS_VERSION} — usando repo 12" ;;
      esac
      PKG_MANAGER="apt-get"
      ;;
    *)
      warn "Sistema '${OS_ID}' não reconhecido. Tentando com repo Ubuntu 24.04..."
      REPO_OS="xUbuntu_24.04"
      PKG_MANAGER="apt-get"
      ;;
  esac

  REPO_URL="${REPO_BASE}/${REPO_OS}"
  log "Repositório OPSI: ${REPO_URL}"
  ok "SO detectado: ${OS_ID} ${OS_VERSION} (${ARCH})"
}

# ──────────────────────────────────────────────
#  ETAPA 2 — Instalar dependências
# ──────────────────────────────────────────────
instalar_dependencias() {
  titulo "Etapa 2/7 — Instalando dependências"

  export DEBIAN_FRONTEND=noninteractive
  log "Atualizando lista de pacotes..."
  $PKG_MANAGER update -qq >> "$LOG" 2>&1

  log "Instalando pacotes base..."
  $PKG_MANAGER install -y -qq \
    curl wget gnupg2 apt-transport-https \
    ca-certificates lsb-release \
    mariadb-server redis-server \
    >> "$LOG" 2>&1

  ok "Dependências instaladas."

  # Iniciar e habilitar MariaDB e Redis
  systemctl enable --now mariadb >> "$LOG" 2>&1 || true
  systemctl enable --now redis-server >> "$LOG" 2>&1 || \
    systemctl enable --now redis >> "$LOG" 2>&1 || true

  ok "MariaDB e Redis iniciados."
}

# ──────────────────────────────────────────────
#  ETAPA 3 — Configurar MariaDB
# ──────────────────────────────────────────────
configurar_mariadb() {
  titulo "Etapa 3/7 — Configurando banco de dados"

  MYSQL_ROOT_PASS=$(gerar_senha)
  MYSQL_OPSI_PASS=$(gerar_senha)

  log "Criando banco de dados e usuário OPSI..."

  mysql -u root << SQL >> "$LOG" 2>&1
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
CREATE DATABASE IF NOT EXISTS opsi CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER IF NOT EXISTS 'opsi'@'localhost' IDENTIFIED BY '${MYSQL_OPSI_PASS}';
GRANT ALL PRIVILEGES ON opsi.* TO 'opsi'@'localhost';
FLUSH PRIVILEGES;
SQL

  # Salvar credenciais MySQL
  cat > /root/.my.cnf << CNF
[client]
user=root
password=${MYSQL_ROOT_PASS}
CNF
  chmod 600 /root/.my.cnf

  ok "Banco de dados configurado."
}

# ──────────────────────────────────────────────
#  ETAPA 4 — Adicionar repositório OPSI
# ──────────────────────────────────────────────
adicionar_repositorio() {
  titulo "Etapa 4/7 — Adicionando repositório OPSI"

  log "Baixando chave GPG do repositório OPSI..."
  mkdir -p "$(dirname "$REPO_KEY")"
  curl -fsSL "${REPO_URL}/Release.key" | gpg --dearmor | tee "$REPO_KEY" > /dev/null
  ok "Chave GPG importada."

  log "Adicionando repositório: ${REPO_URL}"
  echo "deb [signed-by=${REPO_KEY}] ${REPO_URL}/ /" | \
    tee /etc/apt/sources.list.d/opsi.list > /dev/null

  $PKG_MANAGER update -qq >> "$LOG" 2>&1
  ok "Repositório OPSI adicionado."
}

# ──────────────────────────────────────────────
#  ETAPA 5 — Instalar OPSI
# ──────────────────────────────────────────────
instalar_opsi() {
  titulo "Etapa 5/7 — Instalando OPSI"

  log "Instalando opsiconfd e pacotes OPSI..."
  $PKG_MANAGER install -y -qq \
    opsiconfd \
    opsi-utils \
    opsi-tftpd-hpa \
    >> "$LOG" 2>&1

  ok "Pacotes OPSI instalados."
}

# ──────────────────────────────────────────────
#  ETAPA 6 — Configurar OPSI
# ──────────────────────────────────────────────
configurar_opsi() {
  titulo "Etapa 6/7 — Configurando OPSI"

  SERVER_IP=$(detectar_ip)
  SERVER_HOSTNAME=$(hostname -s 2>/dev/null || echo "opsi-server")
  SERVER_DOMAIN=$(hostname -d 2>/dev/null || echo "local")
  [ -z "$SERVER_DOMAIN" ] && SERVER_DOMAIN="local"
  OPSI_ADMIN_PASS=$(gerar_senha)

  log "Hostname: ${SERVER_HOSTNAME}.${SERVER_DOMAIN}"
  log "IP: ${SERVER_IP}"

  # Configurar opsiconfd
  cat > /etc/opsi/opsiconfd.conf << CONF
# OPSI Config Server — Insight Manager
# Gerado em: $(date)

[global]
hostname = ${SERVER_HOSTNAME}.${SERVER_DOMAIN}
admin-networks = 0.0.0.0/0

[mysql]
host = localhost
database = opsi
username = opsi
password = ${MYSQL_OPSI_PASS}

[redis]
host = localhost

[ssl]
server-cert = /etc/opsi/ssl/opsiconfd.pem
server-key  = /etc/opsi/ssl/opsiconfd.pem
CONF

  # Rodar setup inicial do OPSI
  log "Executando opsiconfd setup..."
  opsiconfd setup --configure-mysql \
    --mysql-host=localhost \
    --mysql-database=opsi \
    --mysql-username=opsi \
    --mysql-password="${MYSQL_OPSI_PASS}" \
    >> "$LOG" 2>&1 || true

  # Criar usuário administrador
  log "Criando usuário adminuser..."
  opsiconfd setup --set-adminuser-password "${OPSI_ADMIN_PASS}" >> "$LOG" 2>&1 || \
    opsi-admin -d task setPcpatchPassword "${OPSI_ADMIN_PASS}" >> "$LOG" 2>&1 || true

  # Habilitar e iniciar opsiconfd
  systemctl enable --now opsiconfd >> "$LOG" 2>&1 || true

  ok "OPSI configurado e iniciado."

  # Salvar credenciais
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
#  ETAPA 7 — Instalar helper CLI
# ──────────────────────────────────────────────
instalar_helper() {
  titulo "Etapa 7/7 — Instalando helper de linha de comando"

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
    systemctl status opsiconfd --no-pager -l | grep -E "Active|Main PID"
    systemctl status mariadb   --no-pager -l | grep -E "Active|Main PID"
    systemctl status redis-server --no-pager -l 2>/dev/null | grep -E "Active|Main PID" || \
    systemctl status redis --no-pager -l 2>/dev/null | grep -E "Active|Main PID" || true
    echo ""
    ;;
  logs)
    journalctl -u opsiconfd -f --no-pager
    ;;
  start)
    systemctl start opsiconfd mariadb redis-server 2>/dev/null || \
    systemctl start opsiconfd mariadb redis 2>/dev/null || true
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
    grep -v "^#" "$CREDS" | grep -v "^$" | while IFS='=' read -r chave valor; do
      printf "  %-25s %s\n" "${chave}:" "${valor}"
    done
    echo ""
    ;;
  testar-api)
    source "${CREDS}" 2>/dev/null
    _info "Testando API JSON-RPC..."
    curl -sk -u "adminuser:${OPSI_SENHA}" \
      -X POST "https://localhost:4447/rpc" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"backend_info","params":[]}' \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print('  Versão OPSI:', d['result'].get('opsiVersion','?'))" \
      && _ok "API respondendo." || _warn "Verifique: opsi-server logs"
    ;;
  listar-clientes)
    source "${CREDS}" 2>/dev/null
    curl -sk -u "adminuser:${OPSI_SENHA}" \
      -X POST "https://localhost:4447/rpc" \
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
}

# ──────────────────────────────────────────────
#  MAIN
# ──────────────────────────────────────────────
main() {
  init
  detectar_so
  instalar_dependencias
  configurar_mariadb
  adicionar_repositorio
  instalar_opsi
  configurar_opsi
  instalar_helper
  mostrar_resumo
}

main "$@"
