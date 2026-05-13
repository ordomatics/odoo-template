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
| `HELM_GITLAB_TOKEN` | GitLab token with helm repo write access | Ordomatics platform team |
| `GIT_TOKEN` | GitHub PAT to check out private submodules | Your org |

`GITLAB_USERNAME` and `GITLAB_ACCESS_TOKEN` are generated automatically when the platform team
runs the onboarding script. They will be handed to you after onboarding.

`GIT_TOKEN` must be a GitHub personal access token (classic) with `repo` scope, able to read
all private submodule repos listed in `.gitmodules`.

### 4. Populate addons/

The `Dockerfile` copies `addons/` into the image. This directory is for
**client-specific custom addons only** — platform modules (whatsapp, billing, llm suite,
OCA, enterprise) are already baked into the base image and do not need to be listed here.

Each addon is a Git submodule pointing to its own repo. The template includes `addons/enterprise`
as an example — replace the URL with your actual enterprise repo and add any other custom addons:

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

Update `modules.cfg` to list any custom modules that should be installed/upgraded on deployment.

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
images are built once on `dev` and promoted through environments by retagging.

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

# Start
docker compose up
```

Access Odoo at `http://localhost:8069`.

---

## File structure

```
.
├── .github/
│   ├── actions/
│   │   └── deploy-helm/        # Reusable action: update helm values + push
│   └── workflows/
│       └── ci.yaml             # Multi-env CI/CD pipeline
├── addons/                     # Git submodules — one per addon repo
│   ├── whatsapp/
│   ├── billing/
│   ├── platform/
│   ├── enterprise/
│   └── oca/
├── scripts/
│   └── setup-odoo-modules.sh   # Module install/upgrade entrypoint
├── Dockerfile
├── entrypoint.sh
├── modules.cfg                 # Modules to install/upgrade on deploy
├── odoo.conf.template          # Odoo config rendered at startup
├── requirements.txt
└── requirements-dev.txt
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
