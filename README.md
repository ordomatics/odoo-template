# ordomatics/odoo — generic base image (this branch: 18.0)

This branch builds `registry.gitlab.com/ordomatics/odoo:18.0` — a generic,
public Odoo 18.0 image with Ordomatics's deployment tooling baked in
(entrypoint, module-setup script, config templating) but **no proprietary
addons**. It is not itself a client template — see `main`/`dev` on this
same repo for that (the "Use this template" branches, `FROM` this image).

Used as:
1. The seed image for every new Tier2 client's first onboarding, before
   their own CI has produced a real image.
2. The `FROM` base for client forks of this template — so a client's own
   image never depends on Ordomatics's own internal, proprietary image.

## What's baked in

- Odoo 18.0 core + `crm`, `queue_job` (required by `server_wide_modules`)
- `session_redis`, `bus_keepalive` — generic infra (post_load hooks,
  required by `odoo.conf.template`)
- `n8n_connector`, `n8n_crm` — standalone n8n integration
- `llm_mssql`, `llm_n8n` — MSSQL/n8n connectors for the LLM tool-calling
  layer, plus their transitive deps from `odoo-llm` (`llm`, `llm_tool`,
  `llm_thread`, `llm_mcp_server`, `llm_assistant`, `web_json_editor`) —
  *not* the full LLM suite (no chat/generation modules)
- Microsoft ODBC Driver 18 + `pyodbc` (for `llm_mssql`)

All submodule sources (`ordomatics/ordomatics`, `moctarjallo/odoo-llm`,
`moctarjallo/queue`) are public — CI needs no GitHub token to check them
out, only a GitLab deploy token to push the built image.

## Adding a version branch (e.g. 17.0, 19.0)

1. Branch from `18.0`.
2. `Dockerfile`: change `FROM odoo:18.0` to the target version.
3. `entrypoint.sh`: change `/var/lib/odoo/addons/18.0` to the target version.
4. `.github/workflows/build-base-image.yml`: change the trigger branch and
   both tags (`ordomatics/odoo:18.0` → `ordomatics/odoo:<version>`) — do
   *not* push `:latest` from more than one version branch.
5. Push — CI builds and publishes automatically.

## Local testing

```bash
./scripts/setup-submodules.sh
docker build -t ordomatics-odoo-base:18.0 .
docker run --rm -e ADMIN_PASSWD=test ordomatics-odoo-base:18.0 odoo --version
```
