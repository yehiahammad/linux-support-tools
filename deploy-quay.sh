#!/bin/bash

set -euo pipefail

ANSWERS_FILE="answers.txt"

#############################################
# Logging
#############################################

log() {
    echo
    echo "====================================="
    echo "$1"
    echo "====================================="
}

#############################################
# Read Answers Helper
#############################################

get_answer() {

    KEY=$1
    PROMPT=$2
    SECRET=${3:-false}

    VALUE=""

    if [[ -f "$ANSWERS_FILE" ]]; then
        VALUE=$(grep "^$KEY=" "$ANSWERS_FILE" | tail -1 | cut -d= -f2- || true)
    fi

    if [[ -n "$VALUE" ]]; then
        printf -v "$KEY" "%s" "$VALUE"
        echo "$KEY loaded from answers.txt"
        return
    fi

    if [[ "$SECRET" == "true" ]]; then
        read -s -p "$PROMPT: " VALUE
        echo
    else
        read -p "$PROMPT: " VALUE
    fi

    printf -v "$KEY" "%s" "$VALUE"
}

#############################################
# Install Dependencies
#############################################

install_dependencies() {

    log "Installing required packages"

    dnf install -y \
        podman \
        httpd \
        httpd-tools \
        wget \
        jq \
        iproute
}

#############################################
# Detect Network Interfaces
#############################################

detect_network() {

    log "Detecting network interfaces"

    mapfile -t IPS < <(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)

    COUNT=${#IPS[@]}

    if [[ $COUNT -eq 0 ]]; then
        echo "No active interfaces detected"
        exit 1
    fi

    if [[ $COUNT -eq 1 ]]; then

        QUAY_IP="${IPS[0]}"

        read -p "Detected IP $QUAY_IP — use this? (y/n): " CONFIRM

        [[ "$CONFIRM" != "y" ]] && exit 1

    else

        echo "Multiple interfaces detected"

        for i in "${!IPS[@]}"; do
            echo "$((i+1))) ${IPS[$i]}"
        done

        read -p "Select interface number: " INDEX

        QUAY_IP="${IPS[$((INDEX-1))]}"
    fi
}

#############################################
# Configure FQDN
#############################################

configure_fqdn() {

    get_answer QUAY_FQDN "Enter FQDN for Quay registry"

    if grep -q "$QUAY_FQDN" /etc/hosts; then

        EXISTING_IP=$(grep "$QUAY_FQDN" /etc/hosts | awk '{print $1}')

        if [[ "$EXISTING_IP" == "$QUAY_IP" ]]; then
            echo "/etc/hosts entry already correct"
            return
        else
            echo "FQDN exists with different IP"
            exit 1
        fi
    fi

    echo "$QUAY_IP    $QUAY_FQDN" >> /etc/hosts
}

#############################################
# Gather Inputs
#############################################

gather_inputs() {

    log "Collecting configuration"

    get_answer QUAY_DIR "Enter base directory for Quay"

    CONFIG_DIR="$QUAY_DIR/config"
    STORAGE_DIR="$QUAY_DIR/storage"
    POSTGRES_DIR="$QUAY_DIR/postgres-quay"
    REDIS_DIR="$QUAY_DIR/redis"

    get_answer POSTGRES_USER "PostgreSQL username"
    get_answer POSTGRES_PASS "PostgreSQL password" true
    get_answer POSTGRES_ADMIN_PASS "PostgreSQL admin password" true

    get_answer REDIS_PASSWORD "Redis password" true

    get_answer POSTGRES_IMAGE "PostgreSQL container image"
    get_answer REDIS_IMAGE "Redis container image"
    get_answer QUAY_IMAGE "Quay container image"
}

#############################################
# Registry Login
#############################################

login_registry() {

    log "Checking login to registry.redhat.io"

    if podman login --get-login registry.redhat.io &>/dev/null; then
        echo "Already logged in"
        return
    fi

    get_answer RH_USER "Red Hat registry username"
    get_answer RH_PASS "Red Hat registry password" true

    echo "$RH_PASS" | podman login registry.redhat.io \
        --username "$RH_USER" \
        --password-stdin
}

#############################################
# Configure Firewall
#############################################

configure_firewall() {

    log "Checking firewalld"

    if ! systemctl list-unit-files | grep -q firewalld.service; then
        echo "firewalld not installed"
        return
    fi

    if [[ "$(systemctl is-active firewalld)" == "active" ]]; then

        firewall-cmd --add-port=80/tcp --permanent
        firewall-cmd --add-port=443/tcp --permanent
        firewall-cmd --add-port=6379/tcp --permanent
        firewall-cmd --add-port=5432/tcp --permanent
        firewall-cmd --reload

        echo "Firewall rules applied"

    else
        echo "firewalld not active"
    fi
}

#############################################
# Create Directory Structure
#############################################

create_directories() {

    log "Creating directories"

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$STORAGE_DIR"
    mkdir -p "$POSTGRES_DIR"
    mkdir -p "$REDIS_DIR"

    chmod -R 777 "$QUAY_DIR"

    echo
    echo "If SELinux is enabled run:"
    echo
    echo "setfacl -m u:26:-wx $POSTGRES_DIR"
    echo "setfacl -m u:1001:-wx $STORAGE_DIR"
}

#############################################
# Deploy PostgreSQL
#############################################

deploy_postgres() {

    log "Starting PostgreSQL container"

    podman rm -f postgresql-quay &>/dev/null || true

    podman run -d --rm --name postgresql-quay \
      -e POSTGRESQL_USER="$POSTGRES_USER" \
      -e POSTGRESQL_PASSWORD="$POSTGRES_PASS" \
      -e POSTGRESQL_DATABASE=quay \
      -e POSTGRESQL_ADMIN_PASSWORD="$POSTGRES_ADMIN_PASS" \
      -p 5432:5432 \
      -v "$POSTGRES_DIR":/var/lib/pgsql/data:Z \
      "$POSTGRES_IMAGE"
}

#############################################
# Deploy Redis
#############################################

deploy_redis() {

    log "Starting Redis container"

    podman rm -f redis &>/dev/null || true

    podman run -d --rm --name redis \
      -p 6379:6379 \
      -e REDIS_PASSWORD="$REDIS_PASSWORD" \
      "$REDIS_IMAGE"
}

#############################################
# Generate Quay Config
#############################################

generate_quay_config() {

    log "Generating config.yaml"

    get_answer CREATE_SUPERUSER "Create Quay super user (y/n)"

    CONFIG_FILE="/tmp/config.yaml"

cat <<EOF > $CONFIG_FILE
BUILDLOGS_REDIS:
    host: $QUAY_FQDN
    password: $REDIS_PASSWORD
    port: 6379
CREATE_NAMESPACE_ON_PUSH: true
DATABASE_SECRET_KEY: a8c2744b-7004-4af2-bcee-e417e7bdd235
DB_URI: postgresql://$POSTGRES_USER:$POSTGRES_PASS@$QUAY_FQDN:5432/quay
DISTRIBUTED_STORAGE_CONFIG:
    default:
        - LocalStorage
        - storage_path: /datastorage/registry
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: []
DISTRIBUTED_STORAGE_PREFERENCE:
    - default
FEATURE_MAILING: false
SECRET_KEY: e9bd34f4-900c-436a-979e-7530e5d74ac8
SERVER_HOSTNAME: $QUAY_FQDN
SETUP_COMPLETE: true
EOF

    if [[ "$CREATE_SUPERUSER" == "y" ]]; then
        echo "SUPER_USERS:" >> $CONFIG_FILE
        echo "  - quayadmin" >> $CONFIG_FILE
    fi

cat <<EOF >> $CONFIG_FILE
USER_EVENTS_REDIS:
    host: $QUAY_FQDN
    password: $REDIS_PASSWORD
    port: 6379
EOF

    cp $CONFIG_FILE "$CONFIG_DIR/config.yaml"

    echo "config.yaml written to $CONFIG_DIR/config.yaml"
}

#############################################
# Deploy Quay
#############################################

deploy_quay() {

    log "Starting Quay container"

    podman rm -f quay &>/dev/null || true

    podman run -d --rm \
      -p 80:8080 \
      -p 443:8443 \
      --name=quay \
      -v "$QUAY_DIR/config:/conf/stack:Z" \
      -v "$QUAY_DIR/storage:/datastorage:Z" \
      "$QUAY_IMAGE"
}

#############################################
# Main
#############################################

log "SECTION 1: Install Red Hat Quay Registry"

install_dependencies
detect_network
configure_fqdn
gather_inputs
login_registry
configure_firewall
create_directories
deploy_postgres
deploy_redis
generate_quay_config
deploy_quay

log "Deployed Quay image registry"
