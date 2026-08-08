# ordomatics/odoo — generic base image (this branch: 17.0)

This branch builds `ordomatics/odoo:17.0` (Docker Hub) — a generic,
public Odoo 17.0 image with Ordomatics's deployment tooling baked in
(entrypoint, module-setup script, config templating) but **no proprietary
addons**. It is not itself a client template — see `main`/`dev` on this
same repo for that (the "Use this template" branches, `FROM` this image).
The current default/`:latest` version is `19.0` — pin this specific tag if
you need Odoo 17.0.

Used as:
1. The seed image for every new Tier2 client's first onboarding, before
   their own CI has produced a real image.
2. The `FROM` base for client forks of this template — so a client's own
   image never depends on Ordomatics's own internal, proprietary image.

## What's baked in

- Odoo 17.0 core + `crm`, `queue_job` (required by `server_wide_modules`)
- `session_redis`, `bus_keepalive` — generic infra (post_load hooks,
  required by `odoo.conf.template`)
- `n8n_connector`, `n8n_crm` — standalone n8n integration
- `llm_mssql`, `llm_n8n` — MSSQL/n8n connectors for the LLM tool-calling
  layer, plus their transitive deps from `odoo-llm` (`llm`, `llm_tool`,
  `llm_thread`, `llm_mcp_server`, `llm_assistant`, `web_json_editor`) —
  *not* the full LLM suite (no chat/generation modules)
- Microsoft ODBC Driver 18 + `pyodbc` (for `llm_mssql`)

All submodule sources (`ordomatics/ordomatics`, `moctarjallo/odoo-llm`,
`OCA/queue`) are public — CI needs no GitHub token to check them out, only
a Docker Hub access token to push the built image.

## Adding a version branch (e.g. 18.0, 19.0)

1. Branch from `18.0` (the branch with the most complete, current fixes —
   see its own README for the exact steps; this branch exists as a
   reference for Odoo 17.0's own quirks, not as the template to fork from).
2. `Dockerfile`: change `FROM odoo:<version>` and the addons-path `mkdir`.
3. `entrypoint.sh`: change `/var/lib/odoo/addons/<version>`.
4. `.gitmodules`: point `addons/oca/queue` at that version's OCA/queue
   branch (falls back to upstream `OCA/queue` if a personal fork lacks
   that branch — confirm with `git ls-remote --heads`), then re-point the
   submodule checkout itself and stage it (`git submodule update --remote`
   only tracks the `.gitmodules` branch field on an explicit `--remote`
   update — a plain `git submodule update` keeps the old commit).
5. `.github/workflows/ci.yaml`: change the trigger branch and the tag
   (`ordomatics/odoo:<old>` → `ordomatics/odoo:<version>`) — do *not* push
   `:latest` from more than one version branch. If the new branch is
   meant to become the new default, move the `:latest` tag onto it here
   and remove it from whichever branch owned it before.
6. Push — CI builds and publishes automatically.

Note: `odoo:17.0`'s base OS (Ubuntu 22.04, pip 22.0.2) predates PEP 668 —
`pip3 install --break-system-packages` errors with "no such option" here,
while `odoo:18.0`/`19.0`'s newer base requires the flag. The pip install
step in this Dockerfile detects support instead of hardcoding it; keep
that detection if you add another version branch on an older base.

## Local development

Three layered compose files:

| File | Merged | Contents |
|---|---|---|
| `docker-compose.yml` | always | `odoo` — the one thing this repo is actually about |
| `docker-compose.override.yml` | auto (no flags needed) | `db`, `redis`, `proxy`, `cloudflared` — infra/networking mirroring production topology |
| `docker-compose.integrations.yml` | opt-in (`-f`) | `n8n`, `mssql` — third-party services specific modules talk to |

```bash
./scripts/setup-submodules.sh
cp .env.example .env   # fill in DB_NAME at minimum

# Core: odoo + db + redis + proxy (cloudflared stays off until --profile tunnel)
docker compose up --build -d

# + n8n/mssql integrations
docker compose -f docker-compose.yml -f docker-compose.integrations.yml up --build -d

# + mssql specifically (also needs its own profile)
docker compose -f docker-compose.yml -f docker-compose.integrations.yml --profile mssql up --build -d

# + Cloudflare Tunnel (needs cloudflared/config.yml + credentials.json — gitignored, bring your own)
docker compose --profile tunnel up -d
```

Access Odoo at `http://localhost:8069` (direct) or `http://localhost:8070`
(via the Caddy proxy, matching production's WebSocket/MCP routing).

## File structure

```
.
├── .github/workflows/
│   └── ci.yaml                  # Builds + pushes ordomatics/odoo:17.0 on push
├── addons/                     # Submodules, sparse-checked-out (see .gitmodules)
│   ├── ordomatics/              # session_redis, bus_keepalive, n8n_*, llm_mssql, llm_n8n
│   ├── odoo-llm/                 # llm, llm_tool, llm_thread, llm_mcp_server, llm_assistant, web_json_editor
│   └── oca/queue/                 # queue_job
├── caddy/
│   └── Caddyfile.dev            # Reverse proxy config (docker-compose.override.yml's proxy service)
├── Dockerfile                  # FROM odoo:17.0 — this is the actual base image build
├── db.Dockerfile               # Postgres + pgvector, creates the n8n database too
├── docker-compose.yml          # Core: odoo only
├── docker-compose.override.yml # Auto-merged: db, redis, proxy, cloudflared
├── docker-compose.integrations.yml  # Opt-in: n8n, mssql
├── entrypoint.sh                # Config templating + module-setup dispatch
├── modules.cfg                  # Modules to install/upgrade on deploy
├── odoo.conf.template            # Rendered to odoo.conf at container start
├── requirements.txt             # Python deps for the modules baked into this image
└── scripts/
    ├── setup-odoo-modules.sh     # Module install/upgrade (run via entrypoint.sh)
    └── setup-submodules.sh       # Applies .gitmodules' sparseCheckout patterns
```

## Local testing (image only, no compose stack)

```bash
./scripts/setup-submodules.sh
docker build -t ordomatics-odoo-base:17.0 .
docker run --rm -e ADMIN_PASSWD=test ordomatics-odoo-base:17.0 odoo --version
```
