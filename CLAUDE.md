# Working in this repository

An Odoo project hosted on the Ordomatics platform. This repo holds the project's own
modules and the build; the platform runs servers, databases and releases. README.md has
the full developer guide — this file is what an agent needs to act correctly.

## Layout

- `addons/` — the project's modules. A module directory (`addons/<module>/__manifest__.py`)
  or a Git submodule of several. In the image and in compose it sits at
  `/mnt/extra-addons/client`.
- `modules.cfg` — every module installed on a new database and upgraded on every release.
  Add the project's modules at the **end**, dependencies first. Never remove the platform's
  entries above them. A module not listed here is never installed; a listed one that fails to
  install fails the release.
- `Dockerfile` — `FROM ordomatics/odoo:${PLATFORM_TAG}`. Don't change the base image or
  default it to `latest`.
- `.github/workflows/ci.yaml` — the release pipeline. Change it only to take a template update.

## Odoo version

`PLATFORM_TAG` (GitHub repo variable, mirrored in `.env`) is the version production runs.
Write modules for that version (`'version': '<PLATFORM_TAG>.x.y.z'` in the manifest). Never
target a newer major version: production's database cannot be opened by it.

## Running and testing locally

```bash
docker compose up --build -d          # first start installs modules.cfg; takes minutes
docker compose logs -f odoo           # setup progress, then the server log
docker compose restart odoo           # after view/data/field changes: upgrades modules.cfg
```

Python changes reload on their own (`--dev=reload`). The database is `$DB_NAME` from `.env`.

Run a module's tests in the running stack, on a throwaway database, on ports that don't clash
with the server:

```bash
docker compose exec odoo odoo -d test_<module> -i <module> --test-enable --test-tags /<module> \
  --stop-after-init --http-port=8079 --gevent-port=8089
```

Without `--test-tags`, every dependency's tests run too (`base` included), which takes very long.

If Odoo waits for the database and times out, the shell is exporting `DB_NAME`/`DB_USER`/
`DB_PASSWORD`, which override `.env` in compose: unset them and `docker compose down -v`.

## Releasing

- Push `dev`: CI builds the image, smoke-tests it and publishes `test-<commit>` (and updates
  the test environment, if the project has one).
- Fast-forward `main` to `dev` after `dev`'s run passed: CI releases **that last `dev` image**
  to production. It does not rebuild.
- A production release upgrades the project's database before the servers restart. Follow it
  in the portal (environment page, **View logs**), not by guessing from CI.

Don't push to `main` without the user asking: it releases to their customers.

## Don't

- Commit `.env`, credentials or `cloudflared/credentials.json`.
- Edit the CI's repository variables or secrets by hand — the portal writes them
  (**Refresh pipeline settings** rewrites them).
- Run Odoo's database manager or create databases by hand on a deployed environment; databases
  are managed from the portal.
