#!/bin/sh
# Sentetik veri yükleme: veri/uret.py çıktısını (veri/uretilen/*.csv) şeması kurulmuş,
# BOŞ bir veritabanına tek transaction'da yükler. Trigger'lar ve EXCLUDE kısıtları
# açıktır; kurala uymayan tek satır bile tüm yüklemeyi geri alır.
#
# Bağlantı standart libpq ortam değişkenleriyle verilir (PGHOST, PGPORT, PGUSER,
# PGDATABASE, PGPASSWORD); şema sahibi / superuser ile çalıştırılmalıdır.
#
# Kullanım:
#   python3 veri/uret.py                 # CSV'leri üret (veri/uretilen/, git'e girmez)
#   scripts/veri-yukle.sh [klasör]       # yükle
set -e
cd "$(dirname "$0")/.."
DIR=${1:-veri/uretilen}
[ -f "$DIR/yukle.sql" ] || { echo "HATA: $DIR/yukle.sql yok; önce python3 veri/uret.py çalıştırın" >&2; exit 1; }

PSQL="psql -v ON_ERROR_STOP=1 -X -q"

echo "==> Veritabanı boş mu kontrol ediliyor..."
DOLU=$($PSQL -tA -c "SELECT (SELECT count(*) FROM randevu) + (SELECT count(*) FROM musteri) + (SELECT count(*) FROM sube)")
if [ "$DOLU" != "0" ]; then
  echo "HATA: veritabanı boş değil ($DOLU satır). Yükleme yalnızca boş şemaya yapılır." >&2
  exit 1
fi

# Kimlikler COPY sırasıyla 1..N verilir; üretici FK'ları buna göre yazar.
# Önceki başarısız denemeler sequence'ları ilerletmiş olabilir: sıfırla.
echo "==> Kimlik sayaçları sıfırlanıyor..."
$PSQL <<'EOF'
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT table_name, column_name FROM information_schema.columns
            WHERE table_schema = 'public' AND is_identity = 'YES'
  LOOP
    EXECUTE format('ALTER TABLE %I ALTER COLUMN %I RESTART WITH 1', r.table_name, r.column_name);
  END LOOP;
END $$;
EOF

echo "==> Yükleniyor (tek transaction)..."
BASLA=$(date +%s)
( cd "$DIR" && $PSQL -1 -f yukle.sql )
echo "==> İstatistikler güncelleniyor (ANALYZE)..."
$PSQL -c "ANALYZE"
echo "==> Tamamlandı ($(( $(date +%s) - BASLA )) sn)"
