FROM postgres:15

# Install pgvector
RUN apt-get update && apt-get install -y postgresql-15-pgvector && rm -rf /var/lib/apt/lists/*

# Automatically enable the extension, and create the n8n database (used only
# if docker-compose.integrations.yml's n8n service is also up), on DB init.
COPY init-pgvector.sql /docker-entrypoint-initdb.d/
COPY init-n8n.sh /docker-entrypoint-initdb.d/
