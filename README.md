# Ordomatics Odoo project template

The starting point for an Odoo project hosted on [Ordomatics](https://odoo.ordomatics.com):
a Docker build on the platform's base image, a local development stack, and the CI that
builds your image and releases it.

You write Odoo modules here. The platform runs them: servers, databases, upgrades,
domains and backups are managed from your project's pages in the Ordomatics portal.

---

## From nothing to production

### 1. Create the project in the portal

On [odoo.ordomatics.com](https://odoo.ordomatics.com), sign in and **Create a project**.
Its production environment is ready in a few minutes at `https://<project>.ordomatics.com`,
running the platform's standard modules. Your own code comes next.

### 2. Create your repository from this template

On GitHub: **Use this template** → **Create a new repository**, private.

Leave **Include all branches** off: the template's other branches build the platform's
base images and are not yours. Then create `dev` from `main`:

```bash
git clone https://github.com/<you>/<repo>.git && cd <repo>
git switch -c dev && git push -u origin dev
```

### 3. Connect GitHub in the portal

On your project's page, **Connect GitHub**, install the Ordomatics Platform CI app on
**only this repository**, then pick it with **Use**.

The platform writes what CI needs into the repository (Settings → Secrets and variables →
Actions). You do not set these yourself:

| Variable | What it is |
|---|---|
| `CLIENT_SLUG` | Your project's name on the platform |
| `PLATFORM_TAG` | Your project's Odoo version, e.g. `18.0` (see [Your Odoo version](#your-odoo-version)) |
| `EXTERNAL_GITLAB_REGISTRY`, `EXTERNAL_PATH` | Where your images are pushed |

| Secret | What it is |
|---|---|
| `GITLAB_USERNAME`, `GITLAB_ACCESS_TOKEN` | Push access to your image registry |
| `GITLAB_DEPLOY_SSH_KEY` | Lets CI record which image to release |

If the platform adds or rotates one of these later, **Refresh pipeline settings** next to
your repository on the project page writes them again.

### 4. Run it locally

```bash
git submodule update --init --recursive
cp .env.example .env
```

In `.env`, set at least:

| Variable | Value |
|---|---|
| `COMPOSE_PROJECT_NAME` | Your project's name, so its containers and volumes are its own |
| `DB_NAME` | Your project's name too: production's database is named after it |
| `PLATFORM_TAG` | The same value as the `PLATFORM_TAG` repo variable |

```bash
docker compose up --build -d
```

Odoo is on [localhost:8069](http://localhost:8069) (user `admin`, password `admin`). The first
start installs every module in `modules.cfg` and takes a few minutes; `docker compose logs -f odoo`
shows it.

If port 8069 is taken, override it in an untracked `docker-compose.override.yml`:

```yaml
services:
  odoo:
    ports: !override
      - "8079:8069"
```

### 5. Write your module

Put it in `addons/` — either a module directory (`addons/my_module/__manifest__.py`) or a Git
submodule holding several (`git submodule add <url> addons/<repo>`). Then add its name at the
**end** of `modules.cfg`, after the platform's list. Every module listed there is installed on
a new database and upgraded on every release; one that is not listed is never installed.

`addons/` is mounted into the container, and Odoo runs with `--dev=reload`:

- **Python** changes reload on their own.
- **Views, data, new fields or a new module** need an upgrade: `docker compose restart odoo`
  upgrades everything in `modules.cfg`.

A release fails if a module in `modules.cfg` did not install, so a typo there shows up as a
failed release rather than a missing feature.

### 6. Release it

| You push | CI does |
|---|---|
| `dev` | Builds the image, runs smoke tests (Odoo starts, `base` installs, health check), and publishes it as `test-<commit>`. If the project has a **test** environment, it is updated to that image. |
| `main` | Releases the **last image `dev` built and tested** to production as `prod-<commit>`. Nothing is rebuilt. |

So: push to `dev`, wait for its run to pass, then fast-forward `main` to `dev`.

A production release then runs on its own, in this order:

1. The servers stop; the site answers 503 for a few minutes.
2. Your project's database is upgraded on the new image (every module in `modules.cfg`).
3. The new servers start; other databases on the environment are upgraded after.

The environment reads **Updating…** on the portal throughout, and **View logs** shows each
step. If the upgrade fails, the site stays down and the database shows the failure with
**Retry upgrade**: fix the module and release again.

---

## Modules from elsewhere

**Community modules (OCA and others).** Add the repository as a Git submodule on the branch for
your Odoo version, then list in `modules.cfg` only the modules you use from it:

```bash
git submodule add -b 18.0 https://github.com/OCA/<repo>.git addons/oca-<repo>
```

Their Python dependencies go in `requirements.txt`. A private repository also needs the
`GIT_TOKEN` secret (see [Troubleshooting](#troubleshooting)).

**Already in the base image — don't add them.** The image already carries OCA `queue`,
`rest-framework`, `web-api`, `dms`, `server-env` and `storage`, and the Ordomatics modules. A copy
in your `addons/` takes precedence over the platform's, so it would stop platform fixes to those
modules from reaching you.

**Your own modules.** A module only this project uses goes straight in `addons/`. One you would
reuse across projects belongs in its own repository, added here as a submodule like the above.

---

## Your Odoo version

Your project's Odoo version is set by the platform, not chosen here: CI builds on
`ordomatics/odoo:<PLATFORM_TAG>`, the image your deployments already run, and refuses to build
without it.

Never set it to `latest` or a newer version: a newer major version of Odoo cannot open your
production database. Moving to a new version is an upgrade done through the platform.

The base image already contains Odoo itself plus the platform's modules (sign-in with Google,
background jobs, file storage, the assistant chain, n8n). `modules.cfg` lists the ones every
project installs; keep them and add yours after.

---

## Taking template updates

When this template changes (CI, Dockerfile, compose), bring the change into your repository
like any other: merge or cherry-pick it onto `dev`, push, and release.

Pushing a change to `.github/workflows/` needs a GitHub token with the `workflow` scope. With
the GitHub CLI: `gh auth refresh -s workflow`.

To pick up a new base image locally: `docker compose build --pull && docker compose up -d`.

---

## Troubleshooting

**Locally, Odoo waits for the database and gives up ("Database timeout").**
Compose lets variables exported in your shell override `.env`. If your shell exports `DB_NAME`
(or `DB_USER`, `DB_PASSWORD`), Postgres is created with that name while Odoo looks for the one
in `.env`. Unset them, then recreate: `docker compose down -v && docker compose up -d`.

**A release fails with "Not installed: my_module".**
The module is listed in `modules.cfg` but Odoo could not find or install it: a typo in the name,
a missing `__manifest__.py`, or an error while installing — the release's logs show which.

**CI fails with "PLATFORM_TAG repo variable is not set".**
The repository was connected before the platform wrote it: **Refresh pipeline settings** on
your project page.

**CI cannot check out a submodule.**
A private submodule needs a `GIT_TOKEN` secret: a GitHub token with `repo` scope that can read
it. Public ones need nothing.

**`git push` is refused for a workflow file.**
Your GitHub token lacks the `workflow` scope (see [Taking template updates](#taking-template-updates)).

---

## Files

```
.
├── .github/
│   ├── actions/deploy-helm/    # Records the image to release in your GitLab deploy repo
│   └── workflows/
│       └── ci.yaml             # Build on dev, release on main
├── addons/                     # Your modules and submodules → /mnt/extra-addons/client
├── cloudflared/                # Optional tunnel to your local Odoo (--profile tunnel)
├── Dockerfile                  # Your layer on ordomatics/odoo:<PLATFORM_TAG>
├── db.Dockerfile               # Local Postgres with pgvector
├── docker-compose.yml          # Local stack: Odoo, Postgres, Redis
├── modules.cfg                 # Modules installed and upgraded on every release
└── requirements.txt            # Extra Python packages for your modules
```
