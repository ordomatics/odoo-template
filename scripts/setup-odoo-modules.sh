#!/bin/bash
# setup_odoo_modules.sh — Odoo module installer for Docker/K8s
# Installs or upgrades all modules in a single Odoo invocation (not one-at-a-time).
# Safe to re-run: already-installed modules are upgraded, missing ones are installed.

set -e

DB_NAME="${DB_NAME:-odoo}"
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-odoo}"
DB_PASSWORD="${DB_PASSWORD:-odoo}"
ODOO_CONFIG="/etc/odoo/odoo.conf"

# Timeout for the odoo --init/--update invocation (seconds).
# A full fresh install of all modules can take several minutes.
SETUP_TIMEOUT="${ODOO_SETUP_TIMEOUT:-900}"

# Module list — loaded from modules.cfg (single source of truth).
# In-image path: /tmp/modules.cfg (COPY'd by Dockerfile).
# Dev bind-mount path: /mnt (addons/ is not mounted directly, so image copy is used).
MODULES_FILE="${MODULES_FILE:-/tmp/modules.cfg}"

load_modules() {
    if [ ! -f "$MODULES_FILE" ]; then
        echo "❌ modules.cfg not found at $MODULES_FILE" && exit 1
    fi
    # Strip comments, blank lines, and section headers (e.g. [activate])
    grep -v '^\s*#' "$MODULES_FILE" | grep -v '^\s*$' | grep -v '^\s*\['
}

# Loaded as an array for use throughout the script
mapfile -t ALL_MODULES < <(load_modules)

# ─── Helpers ────────────────────────────────────────────────────────────────

psql_run() {
    PGPASSWORD="$DB_PASSWORD" PGSSLMODE="${DB_SSLMODE:-prefer}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$@"
}

wait_for_db() {
    echo "⏳ Waiting for database..."
    local tries=0
    until psql_run -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ $tries -gt 90 ] && echo "❌ Database timeout after 180s" && exit 1
        sleep 2
    done
    echo "✅ Database ready"
}

cleanup_stale_assets() {
    if [ "${CLEANUP_ASSETS:-false}" != "true" ]; then
        return 0
    fi
    if ! db_initialized; then
        echo "ℹ️  Fresh DB — skipping asset cleanup"
        return 0
    fi
    echo "🧹 Cleaning stale asset attachments..."
    psql_run -d "$DB_NAME" -c \
        "DELETE FROM ir_attachment WHERE name LIKE '%.assets_%' OR name LIKE '/web/assets/%';"
    echo "✅ Stale assets cleared"
}

db_initialized() {
    # Returns 0 if the app DB exists and has been seeded by Odoo (ir_module_module present)
    psql_run -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$DB_NAME" && \
    psql_run -d "$DB_NAME" -c "SELECT 1 FROM ir_module_module LIMIT 1" >/dev/null 2>&1
}

odoo_run() {
    PYTHONUNBUFFERED=1 timeout "$SETUP_TIMEOUT" odoo \
        --config="$ODOO_CONFIG" \
        --database="$DB_NAME" \
        --without-demo=all \
        --stop-after-init \
        --no-http \
        "$@"
}

odoo_shell_run() {
    timeout "$SETUP_TIMEOUT" odoo shell \
        --config="$ODOO_CONFIG" \
        --database="$DB_NAME" \
        --no-http
}

module_installed() {
    local module_name="$1"
    psql_run -d "$DB_NAME" -tAc \
        "SELECT 1 FROM ir_module_module WHERE name = '${module_name}' AND state = 'installed' LIMIT 1;" \
        | grep -qx '1'
}

run_ordomatics_bootstrap() {
    if ! module_installed "ordomatics"; then
        return 0
    fi

    echo "🧩 Running ordomatics bootstrap..."
    odoo_shell_run <<'EOF'
from odoo.addons.ordomatics.hooks import run_bootstrap

run_bootstrap(env)
env.cr.commit()
EOF
    echo "✅ ordomatics bootstrap complete"
}

# Auto-discovered addons with a hooks.py (installed + bootstrapped below).
INFRA_ADDONS_DIR="${INFRA_ADDONS_DIR:-/mnt/extra-addons/infra}"

scan_infra_modules() {
    [ -d "$INFRA_ADDONS_DIR" ] || return 0
    local dir
    for dir in "$INFRA_ADDONS_DIR"/*/; do
        [ -f "${dir}hooks.py" ] && basename "$dir"
    done
}

run_infra_bootstraps() {
    local mod
    while read -r mod; do
        [ -z "$mod" ] && continue
        module_installed "$mod" || continue
        echo "🧩 Running $mod bootstrap..."
        odoo_shell_run <<EOF
from odoo.addons.${mod}.hooks import run_bootstrap

run_bootstrap(env)
env.cr.commit()
EOF
        echo "✅ $mod bootstrap complete"
    done < <(scan_infra_modules)
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    local infra_modules=()
    mapfile -t infra_modules < <(scan_infra_modules)
    local all_modules=("${ALL_MODULES[@]}" "${infra_modules[@]}")

    echo "🚀 Starting Odoo module setup..."
    echo "📋 Database: $DB_NAME @ $DB_HOST:$DB_PORT"
    echo "📦 Modules: ${all_modules[*]}"

    wait_for_db
    cleanup_stale_assets

    # Seed the database if this is a fresh install
    if ! db_initialized; then
        echo "🔧 Fresh database — seeding with base module..."
        odoo_run --init=base --log-level=warn
        echo "✅ Base seeded"
    fi

    # Query which modules are already installed in this DB
    local installed
    installed=$(psql_run -d "$DB_NAME" -t -c \
        "SELECT name FROM ir_module_module WHERE state = 'installed';" 2>/dev/null \
        | tr -d ' ' | grep -v '^$' || true)

    # Split into --init (not yet installed) and --update (already installed)
    local to_init=() to_update=()
    for mod in "${all_modules[@]}"; do
        if echo "$installed" | grep -qx "$mod"; then
            to_update+=("$mod")
        else
            to_init+=("$mod")
        fi
    done

    # Detect uninstalled deps of already-installed modules.
    # Handles the case where a new dependency is added to an installed module's
    # manifest — Odoo's --update won't auto-install new deps.
    local orphaned_deps
    mapfile -t orphaned_deps < <(psql_run -d "$DB_NAME" -tAc \
        "SELECT DISTINCT d.name
         FROM ir_module_module_dependency d
         JOIN ir_module_module parent ON parent.id = d.module_id
             AND parent.state IN ('installed', 'to upgrade')
         LEFT JOIN ir_module_module dep ON dep.name = d.name
         WHERE dep.state IS NULL OR dep.state = 'uninstalled'
         ORDER BY d.name;" 2>/dev/null || true)

    for dep in "${orphaned_deps[@]}"; do
        [ -z "$dep" ] && continue
        if ! printf '%s\n' "${to_init[@]}" "${to_update[@]}" | grep -qx "$dep"; then
            echo "🔍 Orphaned dep detected (new in manifest, not yet installed): $dep"
            to_init+=("$dep")
        fi
    done

    if [ ${#to_init[@]} -eq 0 ] && [ ${#to_update[@]} -eq 0 ]; then
        echo "✅ All modules already installed and up-to-date"
        return 0
    fi

    # Build a single odoo invocation for both --init and --update
    local args=()
    [ ${#to_init[@]} -gt 0 ]   && args+=(--init="$(IFS=,; echo "${to_init[*]}")")
    [ ${#to_update[@]} -gt 0 ] && args+=(--update="$(IFS=,; echo "${to_update[*]}")")

    echo "📥 Installing:  ${to_init[*]:-none}"
    echo "🔄 Upgrading:   ${to_update[*]:-none}"

    odoo_run "${args[@]}" --log-level=info
    run_ordomatics_bootstrap
    run_infra_bootstraps

    echo "✨ Module setup complete!"
}

# ─── Subcommands ────────────────────────────────────────────────────────────

case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [--help|--core-only|--verify|--debug]"
        echo "  (no args)    Install/upgrade all modules (idempotent)"
        echo "  --core-only  Install only core modules (no custom)"
        echo "  --verify     Show installed module states from DB"
        echo "  --debug      Show addons paths and available modules"
        exit 0
        ;;
    --core-only)
        # Install only up to and including endpoint_route_handler (OCA infra layer).
        # Override via: MODULES_FILE=/path/to/custom-list.txt setup_odoo_modules.sh
        mapfile -t ALL_MODULES < <(load_modules | grep -E "^(base|web|contacts|product|account|mail|queue_job|fastapi|endpoint_route_handler)$")
        main
        ;;
    --verify)
        wait_for_db
        psql_run -d "$DB_NAME" -c \
            "SELECT name, state FROM ir_module_module
             WHERE name = ANY('{$(IFS=,; echo "${ALL_MODULES[*]}")}')
             ORDER BY name;"
        ;;
    --debug)
        echo "=== addons_path from $ODOO_CONFIG ==="
        grep "addons_path" "$ODOO_CONFIG" || echo "(not found)"
        echo ""
        echo "=== Modules discovered under /mnt ==="
        find /mnt -name "__manifest__.py" 2>/dev/null \
            | sed 's|/__manifest__.py||' | xargs -I{} basename {} | sort
        ;;
    *)
        main
        ;;
esac
