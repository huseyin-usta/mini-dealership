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

# Resmi postgres imajı initdb için geçici bir sunucu açar ve kapatır;
# "ready" satırı iki kez görünür. İkincisini beklemek yarışı kapatır.
hazir=0
while [ "$hazir" -eq 0 ]; do
  if [ "$(docker logs "$CONTAINER" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ] \
     && docker exec "$CONTAINER" psql -U postgres -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
    hazir=1
  else
    sleep 1
  fi
done

for f in db/*.sql; do
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$f"
done

tbls doc "postgres://postgres:$PW@127.0.0.1:5433/postgres?sslmode=disable" docs/sema -f
