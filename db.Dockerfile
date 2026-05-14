FROM postgres:15

# Install pgvector
RUN apt-get update && apt-get install -y postgresql-15-pgvector && rm -rf /var/lib/apt/lists/*

# Automatically enable the extension on DB init
COPY init-pgvector.sql /docker-entrypoint-initdb.d/
