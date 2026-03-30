#!/bin/bash
# ============================================================
#  TP MQTT — Script d'installation & configuration
#  Mosquitto broker : Auth + TLS + ACL + Docker Compose
# ============================================================

set -euo pipefail

# ── Couleurs ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
ok()    { echo -e "  ${GREEN}✔ $1${RESET}"; }
warn()  { echo -e "  ${YELLOW}⚠ $1${RESET}"; }
fail()  { echo -e "  ${RED}✘ $1${RESET}"; exit 1; }
info()  { echo -e "  ${BOLD}→ $1${RESET}"; }

WORKDIR="/opt/mqtt-tp"
CERT_DIR="/etc/mosquitto/certs"
PASSWD_FILE="/etc/mosquitto/passwd"
ACL_FILE="/etc/mosquitto/acl"
CONF_FILE="/etc/mosquitto/mosquitto.conf"
MQTT_USER="user1"
MQTT_PASS="mqtt_password_tp"
SENSOR_USER="sensor_node_1"
SENSOR_PASS="sensor_password_tp"
DASHBOARD_USER="dashboard"
DASHBOARD_PASS="dashboard_password_tp"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║    TP MQTT — Installation & Sécurisation         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"

# ── Vérification root ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "Ce script doit être exécuté en root : sudo bash install_mqtt.sh"
fi

# ────────────────────────────────────────────────────────────
# ÉTAPE 1 — Prérequis système
# ────────────────────────────────────────────────────────────
step "ÉTAPE 1 — Mise à jour système & dépendances"

apt-get update -qq && apt-get upgrade -y -qq
ok "Système mis à jour"

apt-get install -y -qq \
    curl gnupg2 ca-certificates software-properties-common \
    lsb-release docker.io docker-compose \
    mosquitto mosquitto-clients \
    net-tools openssl
ok "Paquets installés (Docker, Mosquitto, OpenSSL, net-tools)"

# ── PPA Mosquitto officiel ──────────────────────────────────
info "Ajout du dépôt officiel Mosquitto..."
add-apt-repository -y ppa:mosquitto-dev/mosquitto-ppa > /dev/null 2>&1 || warn "PPA déjà présent ou non disponible, on continue"
apt-get update -qq
apt-get install -y -qq mosquitto mosquitto-clients
ok "Mosquitto installé depuis le dépôt officiel"

# ── Docker ─────────────────────────────────────────────────
systemctl enable --now docker
CURRENT_USER="${SUDO_USER:-$USER}"
if [[ "$CURRENT_USER" != "root" ]]; then
    usermod -aG docker "$CURRENT_USER"
    warn "Utilisateur $CURRENT_USER ajouté au groupe docker. Reconnexion requise pour effet."
fi
ok "Docker activé"

# ────────────────────────────────────────────────────────────
# ÉTAPE 2 — Arrêt Mosquitto pour reconfiguration
# ────────────────────────────────────────────────────────────
step "ÉTAPE 2 — Arrêt temporaire de Mosquitto"
systemctl stop mosquitto 2>/dev/null || true
ok "Service Mosquitto arrêté"

# ────────────────────────────────────────────────────────────
# ÉTAPE 3 — Génération des certificats TLS auto-signés
# ────────────────────────────────────────────────────────────
step "ÉTAPE 3 — Génération des certificats TLS (auto-signés)"

mkdir -p "$CERT_DIR"

info "Génération de l'autorité de certification (CA)..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${CERT_DIR}/ca.key" \
    -out    "${CERT_DIR}/ca.crt" \
    -subj   "/CN=MQTT-CA-TP" 2>/dev/null
ok "CA générée : ${CERT_DIR}/ca.crt"

info "Génération de la clé & CSR serveur..."
openssl req -new -nodes -newkey rsa:2048 \
    -keyout "${CERT_DIR}/server.key" \
    -out    "${CERT_DIR}/server.csr" \
    -subj   "/CN=localhost" 2>/dev/null

info "Signature du certificat serveur par la CA..."
openssl x509 -req -days 365 \
    -in   "${CERT_DIR}/server.csr" \
    -CA   "${CERT_DIR}/ca.crt" \
    -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial \
    -out  "${CERT_DIR}/server.crt" 2>/dev/null
ok "Certificat serveur signé : ${CERT_DIR}/server.crt"

# Permissions sécurisées
chmod 640 "${CERT_DIR}/server.key" "${CERT_DIR}/ca.key"
chown -R mosquitto:mosquitto "${CERT_DIR}"
ok "Permissions certificats configurées"

# ────────────────────────────────────────────────────────────
# ÉTAPE 4 — Création des utilisateurs (passwords)
# ────────────────────────────────────────────────────────────
step "ÉTAPE 4 — Création des utilisateurs MQTT"

# Supprimer ancien fichier si présent
rm -f "$PASSWD_FILE"

# Créer les utilisateurs (option -c = create, -b = batch non-interactif)
mosquitto_passwd -c -b "$PASSWD_FILE" "$MQTT_USER"       "$MQTT_PASS"
mosquitto_passwd    -b "$PASSWD_FILE" "$SENSOR_USER"     "$SENSOR_PASS"
mosquitto_passwd    -b "$PASSWD_FILE" "$DASHBOARD_USER"  "$DASHBOARD_PASS"

chown mosquitto:mosquitto "$PASSWD_FILE"
chmod 640 "$PASSWD_FILE"

ok "Utilisateurs créés :"
info "  $MQTT_USER       → mot de passe : $MQTT_PASS"
info "  $SENSOR_USER  → mot de passe : $SENSOR_PASS"
info "  $DASHBOARD_USER   → mot de passe : $DASHBOARD_PASS"

# ────────────────────────────────────────────────────────────
# ÉTAPE 5 — Fichier ACL
# ────────────────────────────────────────────────────────────
step "ÉTAPE 5 — Configuration des ACL (contrôle d'accès par topic)"

cat > "$ACL_FILE" << 'EOF'
# ── ACL Mosquitto ─────────────────────────────────────────
# user1 : lecture/écriture sur test/#
user user1
topic readwrite test/#
topic read maison/temperature

# sensor_node_1 : lecture/écriture sur son topic uniquement
user sensor_node_1
topic readwrite home/sensor1/#

# dashboard : lecture seule sur tous les topics home/
user dashboard
topic read home/#

# Interdire l'accès aux topics $SYS pour les clients non-admin
user user1
topic deny $SYS/#

user sensor_node_1
topic deny $SYS/#

user dashboard
topic deny $SYS/#
EOF

chown mosquitto:mosquitto "$ACL_FILE"
chmod 640 "$ACL_FILE"
ok "Fichier ACL créé : $ACL_FILE"

# ────────────────────────────────────────────────────────────
# ÉTAPE 6 — Configuration Mosquitto complète
# ────────────────────────────────────────────────────────────
step "ÉTAPE 6 — Écriture de la configuration Mosquitto"

# Backup config existante
[[ -f "$CONF_FILE" ]] && cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"

cat > "$CONF_FILE" << EOF
# ── Mosquitto Configuration — TP Sécurisation MQTT ────────

# ─ Port 1883 désactivé (non sécurisé) ─────────────────────
# listener 1883   # commenté : on force TLS uniquement

# ─ Authentification ────────────────────────────────────────
allow_anonymous false
password_file $PASSWD_FILE

# ─ ACL ─────────────────────────────────────────────────────
acl_file $ACL_FILE

# ─ TLS sur port 8883 ───────────────────────────────────────
listener 8883
cafile   ${CERT_DIR}/ca.crt
certfile ${CERT_DIR}/server.crt
keyfile  ${CERT_DIR}/server.key
require_certificate false

# ─ Port non-TLS local (tests seulement, loopback) ─────────
listener 1883 127.0.0.1

# ─ Logs ────────────────────────────────────────────────────
log_type all
log_dest syslog
EOF

ok "Configuration écrite : $CONF_FILE"

# ────────────────────────────────────────────────────────────
# ÉTAPE 7 — Démarrage Mosquitto & vérification port
# ────────────────────────────────────────────────────────────
step "ÉTAPE 7 — Démarrage de Mosquitto"

systemctl daemon-reload
systemctl enable --now mosquitto
sleep 2

if systemctl is-active --quiet mosquitto; then
    ok "Mosquitto démarré"
else
    warn "Mosquitto en erreur — vérification des logs..."
    journalctl -u mosquitto -n 20 --no-pager
    fail "Échec démarrage Mosquitto"
fi

# Vérification ports
if ss -tulnp | grep -q ':1883'; then
    ok "Port 1883 (local) ouvert"
else
    warn "Port 1883 non détecté"
fi

if ss -tulnp | grep -q ':8883'; then
    ok "Port 8883 (TLS) ouvert"
else
    warn "Port 8883 TLS non détecté — vérifiez les certificats"
fi

# ────────────────────────────────────────────────────────────
# ÉTAPE 8 — Firewall UFW
# ────────────────────────────────────────────────────────────
step "ÉTAPE 8 — Configuration Firewall (UFW)"

if command -v ufw &>/dev/null; then
    ufw allow 8883/tcp comment "MQTT TLS" > /dev/null 2>&1 || true
    ok "Règle UFW ajoutée : port 8883/tcp"
    info "Port 1883 non exposé (loopback only)"
else
    warn "UFW non disponible, règle firewall non ajoutée"
fi

# ────────────────────────────────────────────────────────────
# ÉTAPE 9 — Déploiement Docker Compose
# ────────────────────────────────────────────────────────────
step "ÉTAPE 9 — Préparation du déploiement Docker Compose"

mkdir -p "$WORKDIR"

# Config Mosquitto pour Docker (port 1883 + 9001 WebSocket)
cat > "${WORKDIR}/mosquitto.conf" << 'DOCKERCONF'
# ── Mosquitto Docker ───────────────────────────────────────
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd

listener 9001
protocol websockets
allow_anonymous false
password_file /mosquitto/config/passwd

log_type all
log_dest stdout
DOCKERCONF

# Copier le fichier passwd pour Docker
cp "$PASSWD_FILE" "${WORKDIR}/passwd"

# docker-compose.yml
cat > "${WORKDIR}/docker-compose.yml" << 'COMPOSE'
version: '3.8'

services:
  mqtt-broker:
    image: eclipse-mosquitto:2.0
    container_name: mosquitto-tp
    restart: unless-stopped
    ports:
      - "11883:1883"    # port mappé sur 11883 (évite conflit avec Mosquitto natif)
      - "9001:9001"     # WebSocket
    volumes:
      - ./mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - ./passwd:/mosquitto/config/passwd:ro
      - mosquitto_data:/mosquitto/data
      - mosquitto_logs:/mosquitto/log
    healthcheck:
      test: ["CMD", "mosquitto_pub", "-h", "localhost", "-t", "healthcheck", "-m", "ping", "-u", "user1", "-P", "mqtt_password_tp"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  mosquitto_data:
  mosquitto_logs:
COMPOSE

ok "Fichiers Docker Compose créés dans $WORKDIR"
info "  ${WORKDIR}/docker-compose.yml"
info "  ${WORKDIR}/mosquitto.conf"

info "Démarrage du container Docker..."
cd "$WORKDIR"
docker-compose up -d 2>&1 | tail -5
sleep 3

if docker ps | grep -q mosquitto-tp; then
    ok "Container Docker 'mosquitto-tp' démarré (port 11883)"
else
    warn "Container Docker non démarré — vérifiez : docker-compose logs"
fi

# ────────────────────────────────────────────────────────────
# RÉSUMÉ FINAL
# ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║              INSTALLATION TERMINÉE              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Services :${RESET}"
echo -e "  Mosquitto natif  → port ${GREEN}1883${RESET} (loopback) / ${GREEN}8883${RESET} (TLS)"
echo -e "  Docker Mosquitto → port ${GREEN}11883${RESET} (externe) / ${GREEN}9001${RESET} (WS)"
echo ""
echo -e "${BOLD}Utilisateurs :${RESET}"
printf "  %-20s %s\n" "$MQTT_USER"       "$MQTT_PASS"
printf "  %-20s %s\n" "$SENSOR_USER"     "$SENSOR_PASS"
printf "  %-20s %s\n" "$DASHBOARD_USER"  "$DASHBOARD_PASS"
echo ""
echo -e "${BOLD}Certificats TLS :${RESET}"
echo -e "  ${CERT_DIR}/ca.crt"
echo -e "  ${CERT_DIR}/server.crt"
echo ""
echo -e "${BOLD}Fichiers de config :${RESET}"
echo -e "  $CONF_FILE"
echo -e "  $ACL_FILE"
echo -e "  $PASSWD_FILE"
echo ""
echo -e "${BOLD}Logs :${RESET}"
echo -e "  journalctl -u mosquitto -f"
echo -e "  docker-compose -f ${WORKDIR}/docker-compose.yml logs -f"
echo ""
echo -e "  ${CYAN}Lancez maintenant : sudo bash test_mqtt.sh${RESET}"
echo ""
