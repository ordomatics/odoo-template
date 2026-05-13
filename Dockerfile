FROM registry.gitlab.com/ordomatics/helm/odoo:latest

# Switch to root to install dependencies
USER root

# Runtime environment variables (injected by K8s ConfigMap/Secret at runtime)
# These are NOT set at build time — declare here only for documentation/tooling
ENV OPENAI_API_KEY=""
ENV ANTHROPIC_API_KEY=""
ENV NOMIC_API_KEY=""
ENV DB_HOST=""
ENV DB_PORT=""
ENV DB_USER=""
ENV DB_PASSWORD=""
ENV DB_NAME=""
ENV PGPASSWORD=""
ENV ODOO_DB=""
ENV ODOO_USERNAME=""
ENV ADMIN_PASSWD=""
ENV WAVE_API_KEY=""
ENV WAVE_WEBHOOK_SIGNING_SECRET=""
ENV WAVE_CHECKOUT_API_KEY=""
ENV WAVE_PAYOUT_API_KEY=""
ENV WAVE_BALANCE_API_KEY=""
ENV WAVE_PAYMENT_RECEIVED_SHARED_SECRET=""
ENV META_VERIFY_TOKEN=""
ENV META_ACCESS_TOKEN=""
ENV WHATSAPP_PHONE_NUMBER=""
ENV WHATSAPP_PHONE_NUMBER_ID=""
ENV DEFAULT_ADMIN_PHONE=""
ENV WHATSAPP_BUSINESS_ACCOUNT_ID=""
ENV WHATSAPP_FLOW_PRIVATE_KEY=""
ENV DULAYNI_API_KEY=""
ENV AGENTIC_API_KEY=""
ENV DB_URI=""
ENV BILLING_DEFAULT_CREDIT_COST=""
ENV BILLING_MINIMUM_TOPUP=""

# Cache busting: separate COPY for requirements
COPY ./requirements.txt /tmp/requirements.txt
COPY ./requirements-dev.txt /tmp/requirements-dev.txt

# Install all OS-level dependencies in a single layer
RUN apt-get update && \
    apt-get install -y \
      iputils-ping \
      postgresql-client \
      git \
      gettext-base \
      gosu \
      curl \
      locales \
      python3-packaging \
      poppler-utils \
      ffmpeg && \
    rm -rf /var/lib/apt/lists/*

# Fix locale settings
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen en_US.UTF-8

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Claude Code CLI — dev/agent tool only, not needed in production
# Gate behind build arg so prod images stay lean
ARG INSTALL_CLAUDE_CODE=false
RUN if [ "$INSTALL_CLAUDE_CODE" = "true" ]; then \
      /usr/bin/npm install -g @anthropic-ai/claude-code @steipete/claude-code-mcp; \
    fi

# Create log directory with proper permissions BEFORE Python installation
RUN mkdir -p /var/log/odoo && \
    chown -R odoo:odoo /var/log/odoo && \
    chmod -R 755 /var/log/odoo

# Install Python dependencies with GitHub token for private repos
RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=secret,id=github_token \
    set -x && \
    # Read GitHub token from secret
    GITHUB_TOKEN=$(cat /run/secrets/github_token 2>/dev/null || echo "") && \
    if [ -z "$GITHUB_TOKEN" ]; then \
        echo "ERROR: No GitHub token provided!" && \
        echo "Private repository gupe-client will fail to install." && \
        exit 1; \
    fi && \
    echo "GitHub token found, configuring git credentials..." && \
    # Configure git to use the token for GitHub
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/" && \
    echo "Installing requirements from /tmp/requirements.txt:" && \
    cat /tmp/requirements.txt && \
    pip3 install \
        --verbose \
        --break-system-packages \
        --ignore-installed \
        -r /tmp/requirements.txt && \
    echo "Cleaning up git configuration..." && \
    # Scope || true to only the unset command — pip failures must not be silenced
    (git config --global --unset url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf || true)

# Optionally install dev dependencies (ipdb, ipython, etc.)
ARG INSTALL_DEV_DEPS=false
RUN if [ "$INSTALL_DEV_DEPS" = "true" ]; then \
      pip3 install --break-system-packages -r /tmp/requirements-dev.txt; \
    fi

RUN mkdir -p /mnt/extra-addons /var/lib/odoo/addons/18.0 && \
    chown -R odoo:odoo /mnt && \
    chown -R odoo:odoo /var/lib/odoo

# All addon repos live under addons/ mirroring /mnt/extra-addons/.
# Adding a new submodule requires no Dockerfile change — just .gitmodules.
COPY --chown=odoo:odoo ./addons /mnt/extra-addons

# Copy scripts and module list
COPY ./scripts/setup-odoo-modules.sh /tmp/setup-odoo-modules.sh
COPY ./modules.cfg /tmp/modules.cfg
COPY ./entrypoint.sh /entrypoint.sh

# Make scripts executable and set proper ownership
RUN chmod +x /entrypoint.sh /tmp/setup-odoo-modules.sh && \
    chown odoo:odoo /tmp/setup-odoo-modules.sh

# Create a default configuration template
COPY ./odoo.conf.template /etc/odoo/odoo.conf.template

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8069/web/health || exit 1

# Set the entrypoint (runs as root, then switches to odoo user)
ENTRYPOINT ["/entrypoint.sh"]

# Default command — no dev flags baked in; entrypoint handles dev/prod switching via ODOO_DEV_MODE
CMD ["odoo", "-c", "/etc/odoo/odoo.conf"]
