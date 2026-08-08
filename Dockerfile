# PLATFORM_TAG picks which Odoo version to build on
# (docker.io/ordomatics/odoo:17.0, :18.0, :19.0, ...) — defaults to
# :latest (the platform's current default version). Override per-build via
# the platform-tag input to build-client-image.yml in your own ci.yaml, no
# branch-picking or repo-recreation needed to change version. Docker Hub,
# not GitLab: GitLab's container registry rejects anonymous pulls even for
# a public project.
ARG PLATFORM_TAG=latest
FROM ordomatics/odoo:${PLATFORM_TAG}

USER root

# Install client-specific Python packages
COPY ./requirements.txt /tmp/client-requirements.txt
# --break-system-packages (PEP 668) is only understood by pip 23.0.1+ — the
# 17.0 base image predates it and errors on an unrecognized flag, so detect
# support instead of hardcoding it (same fix as odoo-template's own
# version-branch Dockerfile).
RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=secret,id=github_token \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) && \
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/" && \
    PIP_BREAK_FLAG=""; \
    pip3 install --help 2>&1 | grep -q -- "--break-system-packages" && PIP_BREAK_FLAG="--break-system-packages"; \
    pip3 install $PIP_BREAK_FLAG -r /tmp/client-requirements.txt && \
    (git config --global --unset url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf || true)

# Copy client-specific addons and module list
COPY --chown=odoo:odoo ./addons /mnt/extra-addons
COPY ./modules.cfg /tmp/modules.cfg
