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

# unixodbc-dev/msodbcsql18 (needed for pyodbc/llm_mssql) deliberately NOT
# installed here — llm_mssql is an opt-in integration module, not baked
# into this image. A client who adds it back as their own addon installs
# the ODBC driver in their own Dockerfile layer.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      postgresql-client \
      gettext-base \
      git \
      gosu && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/log/odoo /mnt/extra-addons /var/lib/odoo/addons/18.0 && \
    chown -R odoo:odoo /var/log/odoo /mnt /var/lib/odoo && \
    chmod 755 /var/log/odoo

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

COPY ./requirements.txt /tmp/requirements.txt
# --ignore-installed: several debian-packaged Python libs (typing_extensions,
# idna, etc.) ship without a pip RECORD file, which makes a normal upgrade
# fail with "Cannot uninstall ... RECORD file not found". Confirmed live
# 2026-08-07 hitting this one package at a time; --ignore-installed sidesteps
# all of them at once instead of allowlisting each by name.
# --break-system-packages (PEP 668) is only understood by pip 23.0.1+ — this
# image's base OS (Ubuntu 22.04 for odoo:17.0's pip 22.0.2, Debian 12 for
# odoo:18.0/19.0's newer pip) determines whether it's needed or even valid,
# so detect support instead of hardcoding it.
RUN --mount=type=cache,target=/root/.cache/pip \
    PIP_BREAK_FLAG=""; \
    pip3 install --help 2>&1 | grep -q -- "--break-system-packages" && PIP_BREAK_FLAG="--break-system-packages"; \
    pip3 install $PIP_BREAK_FLAG --ignore-installed -r /tmp/requirements.txt

# addons/ mirrors /mnt/extra-addons/ — sparse-checked-out per .gitmodules'
# sparseCheckout keys (see scripts/setup-submodules.sh, applied by CI before
# this COPY runs): session_redis/bus_keepalive from addons/ordomatics;
# llm/llm_tool/llm_thread/web_json_editor/llm_mcp_server/llm_assistant from
# addons/odoo-llm; queue_job from addons/oca/queue.
COPY --chown=odoo:odoo ./addons /mnt/extra-addons

COPY ./scripts/setup-odoo-modules.sh /tmp/setup-odoo-modules.sh
COPY ./modules.cfg /tmp/modules.cfg
COPY ./entrypoint.sh /entrypoint.sh
COPY ./odoo.conf.template /etc/odoo/odoo.conf.template

RUN chmod +x /entrypoint.sh /tmp/setup-odoo-modules.sh && \
    chown odoo:odoo /tmp/setup-odoo-modules.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["odoo", "-c", "/etc/odoo/odoo.conf"]
