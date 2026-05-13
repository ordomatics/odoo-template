#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
echo_success() { echo -e "${GREEN}✅ $1${NC}"; }
echo_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
echo_error() { echo -e "${RED}❌ $1${NC}"; }

echo "=== Starting Odoo Configuration Generation ==="

# Set defaults for all config vars before envsubst substitution
# CI / local dev can override by exporting these before container start
if [ -n "${CI}" ] || [ -n "${GITHUB_ACTIONS}" ] || [ "${DB_HOST}" = "localhost" ]; then
    export DB_HOST=${DB_HOST:-"localhost"}
else
    export DB_HOST=${DB_HOST:-"db"}
fi

export DB_PORT=${DB_PORT:-"5432"}
export DB_USER=${DB_USER:-"odoo"}
export DB_PASSWORD=${DB_PASSWORD:-"odoo"}
export DB_NAME=${DB_NAME:-""}
export DB_SSLMODE=${DB_SSLMODE:-"prefer"}
export ODOO_DB_MAXCONN=${ODOO_DB_MAXCONN:-"32"}

# ADMIN_PASSWD must be set explicitly — no default to avoid weak passwords in prod.
# K8s: inject via Secret; local dev: set in .env file.
if [ -z "${ADMIN_PASSWD}" ]; then
    echo_error "ADMIN_PASSWD is not set. Set it in .env or as a K8s Secret."
    exit 1
fi
export ADMIN_PASSWD

export ODOO_LOG_LEVEL=${ODOO_LOG_LEVEL:-"info"}
export ODOO_LIMIT_TIME_REAL=${ODOO_LIMIT_TIME_REAL:-"3600"}
export ODOO_LIMIT_TIME_CPU=${ODOO_LIMIT_TIME_CPU:-"3600"}
export ODOO_QUEUE_JOB_CHANNELS=${ODOO_QUEUE_JOB_CHANNELS:-"root:2,whatsapp:1"}
export ODOO_DB_NAME=${ODOO_DB_NAME:-${DB_NAME}}
if [ -n "${ODOO_DB_FILTER:-}" ]; then
    export ODOO_DB_FILTER
elif [ -n "${ODOO_DB_NAME}" ]; then
    export ODOO_DB_FILTER="^${ODOO_DB_NAME}$"
else
    export ODOO_DB_FILTER=""
fi
# SERVER_URL and other app-level vars default to empty; K8s ConfigMap provides them
export SERVER_URL=${SERVER_URL:-""}
export META_BASE_API_URL=${META_BASE_API_URL:-""}
export AGENTIC_BASE_URL=${AGENTIC_BASE_URL:-""}
export OLLAMA_API_BASE=${OLLAMA_API_BASE:-""}
export DEFAULT_ADMIN_PHONE=${DEFAULT_ADMIN_PHONE:-""}
export DEFAULT_COMPANY_EMAIL=${DEFAULT_COMPANY_EMAIL:-""}
export DEFAULT_COMPANY_PHONE=${DEFAULT_COMPANY_PHONE:-""}

# Build addons_path from /mnt/extra-addons/.
# - Top-level repos (whatsapp, billing, ...) → added directly
# - enterprise → inner path odoo/addons/ added explicitly
# - oca/ → OCA repos live one level deeper; each repo dir is an addons_path entry
# Adding a new submodule only requires a .gitmodules change — never this file.
_std_paths=$(find /mnt/extra-addons -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
  | grep -v '/\.' \
  | grep -v '^/mnt/extra-addons/enterprise$' \
  | grep -v '^/mnt/extra-addons/oca$' \
  | sort | tr '\n' ',' | sed 's/,$//')
_oca_paths=$(find /mnt/extra-addons/oca -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
  | grep -v '/\.' | sort | tr '\n' ',' | sed 's/,$//')
export ODOO_ADDONS_PATH="/usr/lib/python3/dist-packages/odoo/addons,/var/lib/odoo/addons/18.0,/mnt/extra-addons/enterprise/odoo/addons${_std_paths:+,${_std_paths}}${_oca_paths:+,${_oca_paths}}"
unset _std_paths _oca_paths

# Worker count depends on dev vs prod mode
if [ "${ODOO_DEV_MODE:-false}" = "true" ]; then
    # workers=0 means single-threaded (Odoo development mode)
    export ODOO_WORKERS=${ODOO_WORKERS:-"0"}
    export ODOO_CRON_THREADS=${ODOO_CRON_THREADS:-"0"}
else
    # Formula: 2 * vCPU + 1 is a common baseline; override via ODOO_WORKERS env var
    export ODOO_WORKERS=${ODOO_WORKERS:-"2"}
    export ODOO_CRON_THREADS=${ODOO_CRON_THREADS:-"1"}
fi

echo "Using DB_HOST=${DB_HOST}, DB_PORT=${DB_PORT}"

# ============= Fix log directory permissions FIRST =============
echo "=== Fixing log directory permissions ==="
mkdir -p /var/log/odoo
chown -R odoo:odoo /var/log/odoo 2>/dev/null || echo_warning "Could not chown /var/log/odoo (mounted volume with host ownership - continuing)"
chmod -R 755 /var/log/odoo 2>/dev/null || echo_warning "Could not chmod /var/log/odoo (continuing)"
echo "Log directory permissions check done."

# ============= Create symbolic link for Docker logs =============
echo "=== Creating symbolic link for Docker logs ==="
rm -f /var/log/odoo/odoo.log 2>/dev/null || true
ln -sf /dev/stdout /var/log/odoo/odoo.log 2>/dev/null || echo_warning "Could not create symlink for odoo.log (continuing without log file)"
chown -h odoo:odoo /var/log/odoo/odoo.log 2>/dev/null || true
echo "Symbolic link step done."

# ============= Fix filestore permissions =============
echo "=== Fixing filestore permissions ==="
chown -R odoo:odoo /var/lib/odoo
chmod -R 755 /var/lib/odoo
echo "Filestore permissions fixed."

# ============= Generate odoo.conf from template =============
if [ ! -w /etc/odoo/odoo.conf ] && [ -f /etc/odoo/odoo.conf ]; then
    echo_warning "Cannot write to /etc/odoo/odoo.conf (permission denied) - using existing config file"
else
    envsubst < /etc/odoo/odoo.conf.template > /etc/odoo/odoo.conf
    chown odoo:odoo /etc/odoo/odoo.conf
    chmod 644 /etc/odoo/odoo.conf

    echo "Generated config:"
    cat /etc/odoo/odoo.conf
fi

# ============= Module Setup Integration =============
run_as_odoo() {
    if [ "$(id -u)" = "0" ]; then
        gosu odoo "$@"
    else
        exec "$@"
    fi
}

# Handle different execution modes
case "$1" in
    odoo)
        echo_info "Starting Odoo with module setup..."

        # Module setup defaults to SKIP in production (K8s rolling deploys).
        # For local dev, set SKIP_MODULE_SETUP=false via docker-compose.override.yml.
        # For fresh installs, run the odoo-setup one-shot service or a K8s Job.
        if [ "${SKIP_MODULE_SETUP:-true}" != "true" ]; then
            echo_info "Running module setup script..."
            if [ -f "/tmp/setup-odoo-modules.sh" ]; then
                run_as_odoo /tmp/setup-odoo-modules.sh
            else
                echo_warning "Module setup script not found - skipping"
            fi
        else
            echo_info "Module setup skipped (SKIP_MODULE_SETUP=true)"
        fi

        # Start Odoo based on dev mode.
        # Pass through any extra args after "odoo" (e.g. --version, --stop-after-init, -i base).
        # In normal service start the CMD only has "odoo" so ${@:2} is empty.
        if [ "${ODOO_DEV_MODE:-false}" = "true" ]; then
            echo_info "Starting Odoo in DEVELOPMENT mode (--dev=reload, workers=0)"
            echo_info "Queue jobs will execute SYNCHRONOUSLY for immediate testing"
            exec gosu odoo odoo -c /etc/odoo/odoo.conf "${@:2}" --dev=reload
        else
            echo_info "Starting Odoo in PRODUCTION mode (workers=${ODOO_WORKERS})"
            echo_info "Queue jobs will execute ASYNCHRONOUSLY via queue_job runners"
            echo_info "Queue job channels: ${ODOO_QUEUE_JOB_CHANNELS}"
            exec gosu odoo odoo -c /etc/odoo/odoo.conf "${@:2}"
        fi
        ;;

    setup-modules-only)
        echo_info "Running module setup only..."
        if [ -f "/tmp/setup-odoo-modules.sh" ]; then
            run_as_odoo /tmp/setup-odoo-modules.sh
        else
            echo_error "Module setup script not found!"
            exit 1
        fi
        ;;

    setup-core-only)
        echo_info "Running core module setup only..."
        if [ -f "/tmp/setup-odoo-modules.sh" ]; then
            run_as_odoo /tmp/setup-odoo-modules.sh --core-only
        else
            echo_error "Module setup script not found!"
            exit 1
        fi
        ;;

    bash|sh)
        echo_info "Starting interactive shell..."
        exec gosu odoo "$@"
        ;;

    *)
        # Default case - run original behavior
        echo "Starting Odoo..."
        exec gosu odoo "$@"
        ;;
esac
