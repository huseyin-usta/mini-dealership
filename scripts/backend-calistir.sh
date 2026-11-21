#!/bin/sh
# Backend'i yerelde çalıştırır. backend/.env varsa değişkenleri yükler.
# Kullanım: ./scripts/backend-calistir.sh
set -e
cd "$(dirname "$0")/.."

if [ -f backend/.env ]; then
  set -a
  . backend/.env
  set +a
else
  echo "UYARI: backend/.env yok; backend/.env.example'ı kopyalayıp doldurun." >&2
fi

JAR=backend/target/mini-dealership-backend.jar
[ -f "$JAR" ] || { echo "HATA: $JAR yok; cd backend && ./mvnw -q clean package -DskipTests" >&2; exit 1; }

exec java -jar "$JAR"
