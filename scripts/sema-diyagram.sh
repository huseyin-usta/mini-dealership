#!/bin/sh
# Şema diyagramı üretimi: db/*.sql dosyalarını geçici bir Postgres konteynerinde
# uygular, tbls ile docs/sema altını yeniden üretir.
# Gereksinim: docker, tbls (brew install tbls)
set -e
cd "$(dirname "$0")/.."

PW=$(openssl rand -hex 12)
CONTAINER=md-diag-tmp

docker run --rm -d --name "$CONTAINER" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1:5433:5432 postgres:17-alpine
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1' EXIT

until docker exec "$CONTAINER" pg_isready -U postgres -q; do sleep 1; done

for f in db/*.sql; do
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$f"
done

tbls doc "postgres://postgres:$PW@127.0.0.1:5433/postgres?sslmode=disable" docs/sema -f
