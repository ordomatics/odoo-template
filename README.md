# Ordomatics Odoo Client Template

This is the official template for creating a client Odoo repository on the Ordomatics platform.
It provides a production-ready Docker build, a multi-environment CI/CD pipeline, and the standard
addon submodule structure.

---

## Quickstart

### 1. Create your repo from this template

On GitHub: click **Use this template** → **Create a new repository**.

- Set the owner to your org (e.g. `smartacuspro`)
- Name it `odoo`
- Make it **private**
- Create both a `main` and a `dev` branch

You do **not** need to pick a branch of this template repo based on which
Odoo version you want — always create from `main`. Odoo version is a
build-time setting (see step 4a below), not a branch choice, so it can be
changed later without recreating your repo.

### 2. Configure repo variables

In your repo: **Settings → Secrets and variables → Actions → Variables**

| Variable | Description | Example |
|---|---|---|
| `CLIENT_SLUG` | Your client slug, as onboarded by Ordomatics | `smartacus` |
| `EXTERNAL_GITLAB_REGISTRY` | GitLab registry host | `registry.gitlab.com` |
| `EXTERNAL_PATH` | Registry path for your image | `ordomatics/clients/smartacus` |

### 3. Configure repo secrets

In your repo: **Settings → Secrets and variables → Actions → Secrets**

| Secret | Description | Provided by |
|---|---|---|
| `GITLAB_USERNAME` | Registry deploy token username | Ordomatics platform team |
| `GITLAB_ACCESS_TOKEN` | Registry deploy token (read/write registry) | Ordomatics platform team |
| `GITLAB_DEPLOY_SSH_KEY` | SSH deploy key (push access to your `ordomatics/clients/<slug>` deploy repo, for the `values.<env>.yaml` image-tag bump) | Ordomatics platform team |
| `GIT_TOKEN` | GitHub PAT to check out private submodules | Your org |

`GITLAB_USERNAME`, `GITLAB_ACCESS_TOKEN`, and `GITLAB_DEPLOY_SSH_KEY` are generated automatically
by the `onboard-tier2` Backstage template and shown once in the onboarding task's output.

`GIT_TOKEN` must be a GitHub personal access token (classic) with `repo` scope, able to read
all private submodule repos listed in `.gitmodules`. No credential is needed to pull the
platform base image (`ordomatics/odoo` on Docker Hub) — it's a public image.

### 4. Populate addons/

The `Dockerfile` copies `addons/` into the image. This directory is for
**your own custom addons only**. The base image
(`ordomatics/odoo` on Docker Hub) already includes a generic module
set — Odoo core + `crm`, `queue_job`, the LLM tool/assistant chain
(`llm`, `llm_tool`, `llm_thread`, `llm_mcp_server`, `llm_assistant`,
`web_json_editor` — not the full LLM suite, no chat/generation modules),
and `n8n_connector`/`n8n_crm`/`llm_mssql`/`llm_n8n` — see the base image's
own README (`odoo-template`'s `18.0`/`19.0`/etc. branches) for the exact
list. It does **not** include any Ordomatics-proprietary modules
(WhatsApp, billing, the full LLM suite) — those are Ordomatics's own
internal addons, not part of this public template.

Each addon is a Git submodule pointing to its own repo. The template includes `addons/ordomatics`
(Ordomatics's own public generic-modules repo) as a working example so a fresh clone builds
out of the box with no fake/placeholder URLs — replace it with your own custom addons (it's
redundant with the base image, which already includes these same modules):

```bash
git rm addons/ordomatics
git submodule add https://github.com/your-org/your-addon.git addons/your-addon
git add .gitmodules addons/your-addon
git commit -m "feat: replace example submodule with your-addon"
```

Or just add your own addons alongside it:

```bash
git submodule add https://github.com/your-org/your-addon.git addons/your-addon
git add .gitmodules addons/your-addon
git commit -m "feat: add your-addon submodule"
```

If you have no custom addons yet, create an empty placeholder so the Docker build succeeds:

```bash
mkdir -p addons/.keep && touch addons/.keep
git add addons/.keep
git commit -m "chore: placeholder for custom addons"
```

Add your own module name(s) at the bottom of `modules.cfg`, after the platform base list — do
not remove the existing entries, they're already baked into the base image and this file is
what tells the deploy pipeline to install/upgrade them.

### 4a. Pick your Odoo version (optional)

Defaults to whatever `ordomatics/odoo:latest` currently points at. To pin a
specific version instead (`17.0`, `18.0`, `19.0`, ...), set `PLATFORM_TAG` in the `env:` block at
the top of `.github/workflows/ci.yaml`:

```yaml
env:
  PLATFORM_TAG: "18.0"
```

This changes both which base image CI pulls/builds against and which `ARG PLATFORM_TAG` value
gets passed into the `Dockerfile`'s `FROM`. No need to recreate your repo or switch branches to
change version — just edit this one line and push.

### 5. Configure odoo.conf.template

`odoo.conf.template` is rendered at container startup using environment variables injected
by the Helm chart. You generally do not need to edit this file.

Key variables it uses:

| Variable | Set by |
|---|---|
| `DB_NAME` | Helm values (`odoo.config.dbName`) |
| `DB_HOST` | Helm values (`odoo.config.dbHost`) |
| `DB_USER` | Helm values (`odoo.config.dbUser`) |
| `DB_PASSWORD` | K8s secret |
| `ODOO_WORKERS` | Helm values (`odoo.config.odooWorkers`) |
| `SERVER_URL` | Helm values (`odoo.config.serverUrl`) |

`dbfilter` is derived automatically from `DB_NAME` as `^${DB_NAME}$`, ensuring strict
single-database routing per deployment.

---

## CI/CD Pipeline

The pipeline is defined in `.github/workflows/ci.yaml`. It follows a promotion model:
images are built once on `dev` and promoted through environments by retagging. `ci.yaml`
requires `CLIENT_SLUG`/`EXTERNAL_*` repo variables to be set (see step 2 above) — a second,
always-on workflow, `.github/workflows/validate-build.yml`, does a build-only sanity check
of the Dockerfile with no variables or secrets needed at all, so a broken Dockerfile still
fails CI even before those variables are configured.

```
dev branch push
    └── build job
            └── test-promote job
                    └── (manual) staging-promote job
                            └── (manual) prod-promote job
```

### Branch model

| Branch | Triggers | Result |
|---|---|---|
| `dev` | push | Build image, run tests, promote to test env |
| `staging` | push | Pull test-latest, validate, promote to staging |
| `main` | push or tag `v*` | Promote to production |

### What test-promote does

1. Pulls `dev-latest` from the registry
2. Runs smoke tests (Odoo CLI check, base module init, health check)
3. Retags as `test-<sha>` and `test-latest`
4. Updates `chart/values.<CLIENT_SLUG>-test.yaml` in the Ordomatics helm repo
5. ArgoCD picks up the change and deploys to the test namespace

### What deploy-helm does

The `.github/actions/deploy-helm` action clones the Ordomatics Helm GitLab repo, updates
`image.tag` in the relevant values file using `yq`, commits, and pushes. ArgoCD auto-syncs
from there.

### Environments

The pipeline uses GitHub Environments (`test`, `staging`, `production`). You can add
required reviewers or deployment protection rules in **Settings → Environments**.

---

## Local development

```bash
# Clone with all submodules
git clone --recurse-submodules https://github.com/your-org/odoo.git
cd odoo

# Or initialize submodules after cloning
git submodule update --init --recursive

# Copy and fill in local env
cp .env.example .env   # edit DB credentials, API keys, etc.

# Start (first time or after code changes)
docker compose up --build -d
```

Access Odoo at `http://localhost:8069`.

### Cloudflare Tunnel

The compose stack includes a `cloudflared` service for exposing the local instance via a Cloudflare Tunnel. It is gated behind the `tunnel` profile and only starts when explicitly requested:

```bash
docker compose --profile tunnel up -d
```

Place your tunnel credentials in `cloudflared/credentials.json` and your tunnel config in `cloudflared/config.yml` before starting. The credentials file is gitignored and must never be committed.

### Redis

Redis is included in the compose stack for session storage (`SESSION_REDIS_HOST=redis`). It starts automatically with `docker compose up` and requires no extra configuration for local dev.

### Picking up platform updates

When the Ordomatics platform team releases a new base image (new platform modules, entrypoint
changes, etc.), force-pull the latest base image before rebuilding:

```bash
docker compose build --pull
docker compose down -v   # removes stale anonymous volumes so new module structure is picked up
docker compose up -d
```

> `--pull` tells Docker to always check the registry for a newer base image rather than using
> the locally cached version. `down -v` is needed because `VOLUME /mnt/extra-addons` in the
> base image means Docker uses an anonymous volume for that path — without `-v`, the old volume
> (with the old module structure) would be reused even after a rebuild.

---

## File structure

```
.
├── .github/
│   ├── actions/
│   │   └── deploy-helm/        # Reusable action: update helm values + push
│   └── workflows/
│       ├── ci.yaml             # Multi-env CI/CD pipeline
│       └── validate-build.yml  # Build-only sanity check, no vars/secrets needed
├── addons/                     # Client-specific addon submodules (mounted as /mnt/extra-addons)
│   └── ordomatics/              # Working example (real, public) — replace with your own addons
├── cloudflared/                # Cloudflare Tunnel config (activate with --profile tunnel)
│   ├── config.yml
│   └── credentials.json        # Never commit — listed in .gitignore
├── Dockerfile                  # Thin layer on platform base image
├── db.Dockerfile               # Postgres + pgvector for local dev
├── docker-compose.yml          # Local development stack (includes Redis + Cloudflare Tunnel)
├── modules.cfg                 # Modules to install/upgrade on deploy
└── requirements.txt            # Client-specific Python packages
```

---

## Troubleshooting

**CI fails with "CLIENT_SLUG repo variable is not set"**
→ Add the three required variables in Settings → Secrets and variables → Actions → Variables.

**Build fails with `/addons: not found`**
→ Submodules were not initialized. Ensure `GIT_TOKEN` is set and has read access to all
submodule repos listed in `.gitmodules`.

**Odoo shows "Database manager has been disabled"**
→ This means `DB_NAME` is not set or `dbfilter` is too broad. Check that
`odoo.config.dbName` is set correctly in your Helm values file.

**`test-promote` fails on base module init**
→ Usually a missing submodule or broken addon. Check the step logs for the specific module
that failed to load.
