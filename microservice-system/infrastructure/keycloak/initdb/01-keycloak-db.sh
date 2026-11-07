#!/bin/bash
# Tạo database + user riêng cho Keycloak.
# Chỉ chạy MỘT LẦN, lúc volume postgres-data còn rỗng (cơ chế của image postgres).
# Keycloak dùng user riêng chứ không dùng superuser: nó tự chạy migration schema,
# nên chỉ cần toàn quyền trên database của chính nó.
set -euo pipefail

DB="${KEYCLOAK_DB_NAME:-keycloak}"
USR="${KEYCLOAK_DB_USER:?}"
PWD_="${KEYCLOAK_DB_PASSWORD:?}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
    CREATE USER "$USR" WITH PASSWORD '$PWD_';
    CREATE DATABASE "$DB" OWNER "$USR" ENCODING 'UTF8';
    GRANT ALL PRIVILEGES ON DATABASE "$DB" TO "$USR";
SQL

# Postgres 15+ : quyền trên schema public không còn mặc định cho mọi user
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB" <<SQL
    GRANT ALL ON SCHEMA public TO "$USR";
    ALTER SCHEMA public OWNER TO "$USR";
SQL

echo "[initdb] đã tạo database '$DB' và user '$USR' cho Keycloak"
