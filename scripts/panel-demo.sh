#!/bin/sh
# Paneli sentetik veriyle yerelde açar (geliştirme ve demo için).
#
# Geçici bir PostgreSQL 17 konteynerine şemayı (db/*.sql) ve veri/uretilen/
# sentetik verisini (~450 bin satır) yükler, panel ve bot login rollerini
# rastgele şifrelerle oluşturur, iki demo çalışana (bir satış, bir servis)
# panel şifresi atar ve backend'i http://127.0.0.1:8080 adresinde başlatır.
# Ctrl+C ile durur; konteyner ve içindeki her şey silinir.
#
# Demo şifresi PANEL_DEMO_SIFRE ortam değişkeninden alınır; verilmezse rastgele
# üretilip ekrana yazılır (repoya şifre girmez).
#
# Gereksinim: Docker, Java 17, Python 3
# Kullanım:  scripts/panel-demo.sh
set -e
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

C=md-panel-demo
PORT=${DEMO_DB_PORT:-5438}
HTTP_PORT=${HTTP_PORT:-8080}
# WSL2'de Windows tarayıcısından erişmek için BIND_ADRESI=0.0.0.0 verin
# (WSL'in sanal ağı yalnızca bu bilgisayardan erişilebilir).
BIND_ADRESI=${BIND_ADRESI:-127.0.0.1}
JAR=backend/target/mini-dealership-backend.jar
SIFRE=${PANEL_DEMO_SIFRE:-$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)}
PANELPW=$(openssl rand -hex 16)
BOTPW=$(openssl rand -hex 16)

temizle() {
  [ -n "${SRV_PID:-}" ] && { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }
  docker rm -f "$C" >/dev/null 2>&1 || true
}
trap temizle EXIT INT TERM

if [ ! -f veri/uretilen/yukle.sql ]; then
  echo "==> Sentetik veri üretiliyor..."
  PY=python3; $PY -c '' 2>/dev/null || PY=python
  $PY veri/uret.py
fi
if [ ! -f "$JAR" ]; then
  echo "==> Backend derleniyor..."
  ( cd backend && ./mvnw -q clean package -DskipTests )
fi

echo "==> PostgreSQL 17 başlatılıyor (port $PORT)..."
docker rm -f "$C" >/dev/null 2>&1 || true
docker run --rm -d --name "$C" -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" \
  -p 127.0.0.1:$PORT:5432 postgres:17-alpine >/dev/null
until [ "$(docker logs "$C" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ] \
      && docker exec "$C" psql -U postgres -tAc 'SELECT 1' >/dev/null 2>&1; do sleep 1; done

PSQL="docker exec -i $C psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1"
$PSQL -c "ALTER DATABASE postgres SET timezone = 'Europe/Istanbul'"

echo "==> Şema yükleniyor..."
for f in db/*.sql; do $PSQL < "$f" >/dev/null; done

echo "==> Sentetik veri yükleniyor (bir-iki dakika sürebilir)..."
docker cp veri/uretilen "$C:/veri" >/dev/null
docker exec -w /veri "$C" psql -U postgres -X -q -v ON_ERROR_STOP=1 -1 -f yukle.sql >/dev/null
$PSQL -c "VACUUM ANALYZE"

HASH=$(printf '%s' "$SIFRE" | java -cp "$JAR" tr.edu.etu.dealership.panel.SifreHash)
$PSQL -v hash="$HASH" -v panelpw="$PANELPW" -v botpw="$BOTPW" <<'SQL'
CREATE ROLE panel_app LOGIN NOINHERIT PASSWORD :'panelpw' IN ROLE personel, rapor;
CREATE ROLE bot_app LOGIN PASSWORD :'botpw' IN ROLE bot;
-- Demo hesapları: şube 1'in ilk aktif satış ve servis çalışanı
UPDATE calisan SET sifre_hash = :'hash'
 WHERE calisan_id IN (
   (SELECT min(calisan_id) FROM calisan WHERE sube_id = 1 AND aktif_mi AND departman = 'SATIS'),
   (SELECT min(calisan_id) FROM calisan WHERE sube_id = 1 AND aktif_mi AND departman = 'SERVIS'));
SQL
HESAPLAR=$($PSQL -tA -F ' ' -c "
  SELECT kullanici_adi, departman FROM calisan
   WHERE calisan_id IN (
     (SELECT min(calisan_id) FROM calisan WHERE sube_id = 1 AND aktif_mi AND departman = 'SATIS'),
     (SELECT min(calisan_id) FROM calisan WHERE sube_id = 1 AND aktif_mi AND departman = 'SERVIS'))
   ORDER BY departman")

echo "==> Backend başlatılıyor..."
DB_HOST=127.0.0.1 DB_PORT=$PORT DB_NAME=postgres \
BOT_DB_USER=bot_app BOT_DB_PASS="$BOTPW" BOT_TOKEN="$(openssl rand -hex 32)" \
PANEL_DB_USER=panel_app PANEL_DB_PASS="$PANELPW" HTTP_PORT=$HTTP_PORT BIND_ADRESI="$BIND_ADRESI" \
  java -jar "$JAR" > /tmp/md-panel-demo.log 2>&1 &
SRV_PID=$!
until curl -fsS "http://127.0.0.1:$HTTP_PORT/saglik" >/dev/null 2>&1; do
  kill -0 "$SRV_PID" 2>/dev/null || { echo "HATA: backend başlamadı" >&2; cat /tmp/md-panel-demo.log >&2; exit 1; }
  sleep 0.5
done

echo ""
echo "=================================================="
echo "  Panel: http://127.0.0.1:$HTTP_PORT"
echo "  Demo hesapları (şube 1):"
printf '%s\n' "$HESAPLAR" | while read -r kadi dep; do echo "    $kadi  ($dep)"; done
if [ -z "${PANEL_DEMO_SIFRE:-}" ]; then
  echo "  Şifre: $SIFRE"
else
  echo "  Şifre: PANEL_DEMO_SIFRE"
fi
echo "  Durdurmak için Ctrl+C (veritabanı silinir)"
echo "=================================================="
wait "$SRV_PID"
