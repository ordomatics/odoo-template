# Generic Odoo 18.0 base image — deployment tooling (entrypoint, module-setup
# script, config templating) baked in, but NO proprietary addons. Published
# as registry.gitlab.com/ordomatics/odoo:18.0 (public). Used as:
#   1. The seed image for every new Tier2 client's first onboarding, before
#      their own CI has produced a real image.
#   2. The FROM base for client forks of this template (see main/dev
#      branches) — so a client's own image never depends on Ordomatics's
#      own internal, proprietary image (ordomatics/clients/ordomatics).
FROM odoo:18.0

USER root

# unixodbc-dev + msodbcsql18: needed for pyodbc (llm_mssql).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      postgresql-client \
      gettext-base \
      git \
      gosu \
      curl \
      gnupg \
      unixodbc-dev && \
    curl https://packages.microsoft.com/keys/microsoft.asc | \
      gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    curl https://packages.microsoft.com/config/debian/12/prod.list \
      > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/log/odoo /mnt/extra-addons /var/lib/odoo/addons/18.0 && \
    chown -R odoo:odoo /var/log/odoo /mnt /var/lib/odoo && \
    chmod 755 /var/log/odoo

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

COPY ./requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip3 install --break-system-packages -r /tmp/requirements.txt

# addons/ mirrors /mnt/extra-addons/ — sparse-checked-out per .gitmodules'
# sparseCheckout keys (see scripts/setup-submodules.sh, applied by CI before
# this COPY runs): session_redis/bus_keepalive/n8n_connector/n8n_crm/
# llm_mssql/llm_n8n from addons/ordomatics; llm/llm_tool/llm_thread/
# web_json_editor/llm_mcp_server/llm_assistant from addons/odoo-llm;
# queue_job from addons/oca/queue.
COPY --chown=odoo:odoo ./addons /mnt/extra-addons

COPY ./scripts/setup-odoo-modules.sh /tmp/setup-odoo-modules.sh
COPY ./modules.cfg /tmp/modules.cfg
COPY ./entrypoint.sh /entrypoint.sh
COPY ./odoo.conf.template /etc/odoo/odoo.conf.template

RUN chmod +x /entrypoint.sh /tmp/setup-odoo-modules.sh && \
    chown odoo:odoo /tmp/setup-odoo-modules.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["odoo", "-c", "/etc/odoo/odoo.conf"]
