FROM registry.gitlab.com/ordomatics/helm/odoo:latest

USER root

# Install client-specific Python packages
COPY ./requirements.txt /tmp/client-requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=secret,id=github_token \
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true) && \
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/" && \
    pip3 install --break-system-packages -r /tmp/client-requirements.txt && \
    (git config --global --unset url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf || true)

# Copy client-specific addons and module list
COPY --chown=odoo:odoo ./addons /mnt/extra-addons
COPY ./modules.cfg /tmp/modules.cfg
