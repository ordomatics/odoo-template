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
PLAN_ONLY=false

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

# The database's own base URL, from SERVER_URL. Pod env is per-deployment, so
# SERVER_URL normally names the deployment — but the init Job overrides it to
# the tenant's own hostname alongside DB_NAME, which is what makes this correct
# for an attached client. Anything derived from web.base.url is per-tenant, and
# Meta's webhook callback above all: a tenant inheriting the host deployment's
# URL would have its inbound WhatsApp delivered to another tenant's database
# (found setting up the second tenant on ordomatics-test, 2026-09-12).
set_base_url() {
    local url="${SERVER_URL:-}"
    url="${url%/}"
    if [ -z "$url" ]; then
        echo "ℹ️  SERVER_URL not set — leaving web.base.url alone"
        return 0
    fi
    # Frozen too: otherwise the next login rewrites it from whichever request
    # arrives first, and on a wildcard-routed deployment that is not
    # necessarily this tenant's own hostname.
    # ON_ERROR_STOP, and the status is checked: without it a failure here
    # printed the success line anyway, and a fresh tenant silently kept Odoo's
    # localhost default (2026-09-12).
    if ! psql_run -d "$DB_NAME" -q -v ON_ERROR_STOP=1 -v url="$url" <<'SQL'
INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date)
VALUES ('web.base.url', :'url', 1, 1, now(), now())
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, write_date = now();
INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date)
VALUES ('web.base.url.freeze', 'True', 1, 1, now(), now())
ON CONFLICT (key) DO NOTHING;
SQL
    then
        echo "❌ Could not set web.base.url to $url"
        return 1
    fi
    echo "🔗 web.base.url = $url"
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

# Auto-discovered addons that bootstrap themselves on every deploy: any module
# with a hooks.py defining run_bootstrap (e.g. asterisk configuring sip.provider
# from env vars).
#
# Found by content, not by a list of directory names. This script is baked into
# every image, clients included, so naming telephony/, whatsapp/, saas/ or
# platform/ here would state a dependency a client image must never have -- and
# those directories simply do not exist in one, so nothing is found. Filtering on
# run_bootstrap also skips a hooks.py that has none, which the old name-based
# scan would have imported and died on.
EXTRA_ADDONS_ROOT="${EXTRA_ADDONS_ROOT:-/mnt/extra-addons}"

scan_infra_modules() {
    local dir
    for dir in "$EXTRA_ADDONS_ROOT"/*/*/; do
        [ -f "${dir}hooks.py" ] || continue
        grep -q '^def run_bootstrap' "${dir}hooks.py" 2>/dev/null || continue
        basename "$dir"
    done
}

run_infra_bootstraps() {
    local mods=() mod
    while read -r mod; do
        [ -z "$mod" ] && continue
        module_installed "$mod" || continue
        mods+=("$mod")
    done < <(scan_infra_modules)
    [ ${#mods[@]} -eq 0 ] && return 0
    echo "🧩 Running bootstraps: ${mods[*]}"
    # One odoo shell for all of them: each used to pay a full registry load
    # (~16s), about five minutes per deploy. Committed one by one, as when each
    # had its own process: a failure rolls back only that module's work (some
    # bootstraps commit themselves, so a savepoint cannot hold one).
    odoo_shell_run <<EOF
import importlib
import traceback

for mod in [$(printf "'%s'," "${mods[@]}")]:
    try:
        importlib.import_module(f"odoo.addons.{mod}.hooks").run_bootstrap(env)
        env.cr.commit()
        print(f"✅ {mod} bootstrap complete", flush=True)
    except Exception:
        env.cr.rollback()
        env.invalidate_all()
        print(f"⚠️ {mod} bootstrap failed; continuing", flush=True)
        traceback.print_exc()
EOF
}

# ─── Changed modules ────────────────────────────────────────────────────────
# A checksum of every installed module's files, kept in the database, so a
# deploy upgrades only what changed: `-u base` upgraded all ~160 modules on
# every release, ~4 minutes with the site down (2026-10-18). Odoo itself is one
# more entry; when it changes, everything is upgraded as before.
CHECKSUM_KEY="ordomatics.module_checksums"

# Prints {"module": "sha256", ..., "__odoo__": "sha256"} for the modules named.
module_checksums() {
    python3 - "$ODOO_CONFIG" "$@" <<'PY'
import configparser, hashlib, json, os, sys
import odoo

def digest(root, skip=()):
    h = hashlib.sha256()
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in ('__pycache__', '.git') + skip)
        for f in sorted(files):
            if f.endswith(('.pyc', '.pyo')):
                continue
            path = os.path.join(d, f)
            h.update(os.path.relpath(path, root).encode())
            with open(path, 'rb') as fh:
                h.update(fh.read())
    return h.hexdigest()

cfg = configparser.ConfigParser()
cfg.read(sys.argv[1])
paths = [p.strip() for p in cfg.get('options', 'addons_path', fallback='').split(',') if p.strip()]
wanted = set(sys.argv[2:])
found = {}
for path in paths:
    if not os.path.isdir(path):
        continue
    for name in sorted(wanted - found.keys()):
        if os.path.isfile(os.path.join(path, name, '__manifest__.py')):
            found[name] = os.path.join(path, name)   # first on the path wins, as in Odoo
sums = {name: digest(root) for name, root in sorted(found.items())}
sums['__odoo__'] = digest(os.path.dirname(odoo.__file__), skip=('addons',))
print(json.dumps(sums, sort_keys=True))
PY
}

stored_checksums() {
    psql_run -d "$DB_NAME" -tAc \
        "SELECT value FROM ir_config_parameter WHERE key = '$CHECKSUM_KEY';" 2>/dev/null || true
}

store_checksums() {
    psql_run -d "$DB_NAME" -q -v ON_ERROR_STOP=1 -v key="$CHECKSUM_KEY" -v value="$1" <<'SQL'
INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date)
VALUES (:'key', :'value', 1, 1, now(), now())
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, write_date = now();
SQL
}

# The installed modules whose checksum differs from the stored one, one per
# line, or ALL when there is nothing to compare with or Odoo itself changed.
changed_modules() {
    python3 - "$1" "$2" <<'PY'
import json, sys
current = json.loads(sys.argv[1])
try:
    stored = json.loads(sys.argv[2])
except ValueError:
    stored = {}
if not stored or stored.get('__odoo__') != current.get('__odoo__'):
    print('ALL')
else:
    for name, value in sorted(current.items()):
        if name != '__odoo__' and stored.get(name) != value:
            print(name)
PY
}

# ─── Renamed modules ────────────────────────────────────────────────────────
# Odoo has no rename: under a new name a module would install afresh beside its
# old rows. A manifest's "renamed_from" (read only here) names the old ones.

# Prints "old new" per rename declared by a module on the addons path.
declared_renames() {
    python3 - "$ODOO_CONFIG" <<'PY'
import ast, configparser, os, sys

cfg = configparser.ConfigParser()
cfg.read(sys.argv[1])
seen = set()
for path in (p.strip() for p in cfg.get('options', 'addons_path', fallback='').split(',')):
    if not os.path.isdir(path):
        continue
    for name in sorted(os.listdir(path)):
        manifest = os.path.join(path, name, '__manifest__.py')
        if name in seen or not os.path.isfile(manifest):
            continue
        seen.add(name)
        try:
            old_names = ast.literal_eval(open(manifest).read()).get('renamed_from') or []
        except (SyntaxError, ValueError):
            continue
        for old in old_names:
            print(old, name)
PY
}

# The declared renames still to apply to this database.
pending_renames() {
    local old new
    while read -r old new; do
        [ -n "$old" ] || continue
        psql_run -d "$DB_NAME" -tAc \
            "SELECT 1 FROM ir_module_module WHERE name = '$old' AND state <> 'uninstalled'
             AND NOT EXISTS (SELECT 1 FROM ir_module_module WHERE name = '$new' AND state <> 'uninstalled');" \
            | grep -qx 1 && echo "$old $new"
    done < <(declared_renames)
    return 0
}

apply_module_renames() {
    local old new
    while read -r old new; do
        [ -n "$old" ] || continue
        echo "🏷️  Renaming module $old → $new"
        psql_run -d "$DB_NAME" -q -v ON_ERROR_STOP=1 -v old="$old" -v new="$new" <<'SQL'
BEGIN;
-- A row the apps list may have added for the new name, never installed.
DELETE FROM ir_module_module WHERE name = :'new' AND state = 'uninstalled';
UPDATE ir_module_module SET name = :'new' WHERE name = :'old';
UPDATE ir_module_module_dependency SET name = :'new' WHERE name = :'old';
UPDATE ir_model_data SET module = :'new' WHERE module = :'old';
UPDATE ir_model_data SET name = 'module_' || :'new'
 WHERE module = 'base' AND model = 'ir.module.module' AND name = 'module_' || :'old';
UPDATE ir_ui_view SET key = :'new' || substr(key, length(:'old') + 1)
 WHERE left(key, length(:'old') + 1) = :'old' || '.';
COMMIT;
SQL
    done < <(pending_renames)
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    local infra_modules=()
    mapfile -t infra_modules < <(scan_infra_modules)
    local all_modules=()
    mapfile -t all_modules < <(printf '%s\n' "${ALL_MODULES[@]}" "${infra_modules[@]}" | awk 'NF && !seen[$0]++')

    echo "🚀 Starting Odoo module setup..."
    echo "📋 Database: $DB_NAME @ $DB_HOST:$DB_PORT"
    echo "📦 Modules: ${all_modules[*]}"

    wait_for_db
    # A plan only reads.
    [ "$PLAN_ONLY" = "true" ] || cleanup_stale_assets

    # Seed the database if this is a fresh install
    if ! db_initialized; then
        echo "🔧 Fresh database — seeding with base module..."
        odoo_run --init=base --log-level=warn
        echo "✅ Base seeded"
    fi

    if [ "$PLAN_ONLY" = "true" ]; then
        [ -z "$(pending_renames)" ] || { echo changes; return 0; }
    else
        apply_module_renames
    fi

    # Query which modules are already installed in this DB
    local installed
    installed=$(psql_run -d "$DB_NAME" -t -c \
        "SELECT name FROM ir_module_module WHERE state = 'installed';" 2>/dev/null \
        | tr -d ' ' | grep -v '^$' || true)

    # Not yet installed: --init. Installed: --update, but only what changed.
    local to_init=() to_update=()
    for mod in "${all_modules[@]}"; do
        echo "$installed" | grep -qx "$mod" || to_init+=("$mod")
    done
    # shellcheck disable=SC2086 # one module name per word
    CURRENT_CHECKSUMS=$(module_checksums $installed)
    local changed=()
    mapfile -t changed < <(changed_modules "$CURRENT_CHECKSUMS" "$(stored_checksums)")
    if [ "${changed[0]:-}" = "ALL" ]; then
        echo "🔁 No stored checksums, or Odoo itself changed: upgrading everything"
        for mod in "${all_modules[@]}"; do
            echo "$installed" | grep -qx "$mod" && to_update+=("$mod")
        done
    else
        # Odoo upgrades whatever depends on these too.
        to_update=("${changed[@]}")
    fi

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

    if [ "$PLAN_ONLY" = "true" ]; then
        # For the prescale Job: whether the site must stop for this deploy.
        if [ ${#to_init[@]} -eq 0 ] && [ ${#to_update[@]} -eq 0 ]; then echo none; else echo changes; fi
        return 0
    fi

    if [ ${#to_init[@]} -eq 0 ] && [ ${#to_update[@]} -eq 0 ]; then
        echo "✅ All modules already installed and up-to-date"
        store_checksums "$CURRENT_CHECKSUMS"
        set_base_url
        run_infra_bootstraps
        return 0
    fi

    # Build a single odoo invocation for both --init and --update
    local args=()
    [ ${#to_init[@]} -gt 0 ]   && args+=(--init="$(IFS=,; echo "${to_init[*]}")")
    [ ${#to_update[@]} -gt 0 ] && args+=(--update="$(IFS=,; echo "${to_update[*]}")")

    echo "📥 Installing:  ${to_init[*]:-none}"
    echo "🔄 Upgrading:   ${to_update[*]:-none}"

    odoo_run "${args[@]}" --log-level=info

    # Odoo skips a module it cannot find without failing, so check each one landed.
    local missing=()
    installed=$(psql_run -d "$DB_NAME" -t -c \
        "SELECT name FROM ir_module_module WHERE state = 'installed';" 2>/dev/null \
        | tr -d ' ' | grep -v '^$' || true)
    for mod in "${to_init[@]}"; do
        echo "$installed" | grep -qx "$mod" || missing+=("$mod")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Not installed: ${missing[*]} — not on the addons path, or failed to install"
        exit 1
    fi
    # Installed or upgraded now, so their checksums are the ones in the database.
    installed=$(psql_run -d "$DB_NAME" -t -c \
        "SELECT name FROM ir_module_module WHERE state = 'installed';" 2>/dev/null \
        | tr -d ' ' | grep -v '^$' || true)
    # shellcheck disable=SC2086
    store_checksums "$(module_checksums $installed)"
    # After the modules, so ir_config_parameter exists on a fresh database, and
    # before the bootstraps, which read web.base.url.
    set_base_url
    run_infra_bootstraps

    echo "✨ Module setup complete!"
}

# ─── Subcommands ────────────────────────────────────────────────────────────

case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [--help|--core-only|--plan|--verify|--debug]"
        echo "  (no args)    Install/upgrade all modules (idempotent)"
        echo "  --core-only  Install only core modules (no custom)"
        echo "  --plan       Print none if a deploy would change nothing, else changes"
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
    --plan)
        # Prints "none" when this image would change nothing in the database,
        # "changes" otherwise; anything unexpected must read as changes.
        PLAN_ONLY=true
        wait_for_db >/dev/null
        if ! db_initialized; then echo changes; exit 0; fi
        main | tail -1
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
