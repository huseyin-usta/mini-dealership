#!/bin/sh
# İndeks / sorgu maliyeti analizi (tekrarlanabilir ölçüm):
# Geçici bir PostgreSQL 16 konteynerinde şemayı (indeksler hariç, db/0xx–4xx) kurar,
# sentetik veriyi yükler, docs/analiz/sorgular.sql'deki her sorguyu
# EXPLAIN (ANALYZE, BUFFERS) ile TEKRAR kez çalıştırıp medyan süreyi alır;
# ardından db/500_indeksler.sql'i uygular ve ölçümü tekrarlar.
#
# Sorgular, sorgular.sql içindeki "-- N. Başlık" satırlarından bölünür.
# JIT kapalı: maliyet tahmini jit_above_cost'u aşan sorgularda derleme süresi
# (~1 sn) ölçüme karışıp önce/sonra karşılaştırmasını bozuyordu.
#
# Ek ölçüm: tek bir aracın garanti durumu (v_arac_garanti_durumu WHERE vin = ...),
# panelin araç detay ekranının erişim deseni.
#
# Çıktı: docs/analiz/olcum/
#   olcum.md          önce/sonra süre tablosu, indeks boyutları, tablo satır sayıları
#   plan/once|sonra/  her sorgunun son EXPLAIN ANALYZE planı
#   sonuc/            her sorgunun çıktısı (indeksler sonucu değiştirmez)
#
# Gereksinim: Docker, Python 3 (veri/uretilen/ yoksa veriyi üretir)
# Kullanım: scripts/indeks-analiz.sh        (TEKRAR=5 varsayılan)
set -e
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1      # Windows Git Bash: konteyner içi yolları (/veri) çevirmesin

C=md-analiz-tmp
TEKRAR=${TEKRAR:-5}
OUT=docs/analiz/olcum
KAYNAK=docs/analiz/sorgular.sql

if [ ! -f veri/uretilen/yukle.sql ]; then
  echo "==> Sentetik veri üretiliyor..."
  PY=python3; $PY -c '' 2>/dev/null || PY=python
  $PY veri/uret.py
fi

echo "==> PostgreSQL 16 konteyneri başlatılıyor..."
docker run --rm -d --name "$C" -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" postgres:16-alpine >/dev/null
TMPD=$(mktemp -d)
trap 'docker rm -f "$C" >/dev/null 2>&1; rm -rf "$TMPD"' EXIT
# İmaj ilk açılışta geçici sunucuyu kapatıp yeniden başlatır: sorgu kabul edene kadar bekle
until docker exec "$C" psql -U postgres -tAc "SELECT 1" >/dev/null 2>&1; do sleep 1; done
sleep 2
until docker exec "$C" psql -U postgres -tAc "SELECT 1" >/dev/null 2>&1; do sleep 1; done

PSQL="docker exec -i $C psql -U postgres -X -q -v ON_ERROR_STOP=1"
$PSQL -c "ALTER DATABASE postgres SET timezone = 'Europe/Istanbul'"
$PSQL -c "ALTER DATABASE postgres SET jit = off"

echo "==> Şema (indeksler hariç) yükleniyor..."
for f in db/[0-4]*.sql; do $PSQL < "$f"; done

echo "==> Veri yükleniyor..."
docker cp veri/uretilen "$C:/veri"
docker exec -w /veri "$C" psql -U postgres -X -q -v ON_ERROR_STOP=1 -1 -f yukle.sql >/dev/null
$PSQL -c "VACUUM ANALYZE"

# sorgular.sql → sorgu_N.sql (her "-- N. ..." satırı yeni bir sorgu başlatır)
awk -v d="$TMPD" '
  /^-- [0-9]+\. / { n = $2; sub(/\./, "", n); f = sprintf("%s/sorgu_%s.sql", d, n) }
  f { print > f }
' "$KAYNAK"

# Ek: en çok servis kaydı olan aracın garanti durumu
VIN=$($PSQL -tA -c "SELECT r.arac_vin FROM servis_kaydi sk JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1")
printf "SELECT * FROM v_arac_garanti_durumu WHERE vin = '%s';\n" "$VIN" > "$TMPD/ek_arac_garanti.sql"

rm -rf "$OUT"
mkdir -p "$OUT/plan/once" "$OUT/plan/sonra" "$OUT/sonuc"
SORGULAR=$(ls "$TMPD"/sorgu_*.sql | sort -t_ -k2 -n; echo "$TMPD/ek_arac_garanti.sql")

# olc <dosya> <faz>: medyan Execution Time (ms) yazdırır, son planı kaydeder
olc() {
  ad=$(basename "$1" .sql)
  sureler=""
  i=0
  while [ $i -lt "$TEKRAR" ]; do
    plan=$( { echo "EXPLAIN (ANALYZE, BUFFERS)"; grep -v '^--' "$1"; } | $PSQL )
    sureler="$sureler $(printf '%s\n' "$plan" | sed -n 's/.*Execution Time: \([0-9.]*\) ms.*/\1/p')"
    i=$((i + 1))
  done
  printf '%s\n' "$plan" > "$OUT/plan/$2/$ad.txt"
  printf '%s\n' $sureler | sort -n | awk '{a[NR] = $1} END {print a[int((NR + 1) / 2)]}'
}

LISTE="$TMPD/liste"
echo "==> İndekssiz ölçüm ($TEKRAR tekrar, medyan)..."
for f in $SORGULAR; do
  ad=$(basename "$f" .sql)
  $PSQL -P pager=off < "$f" > "$OUT/sonuc/$ad.txt"
  t=$(olc "$f" once)
  echo "$f $t" >> "$LISTE"
  echo "    $ad: $t ms"
done

echo "==> İndeksler uygulanıyor (db/500_indeksler.sql)..."
$PSQL < db/500_indeksler.sql
$PSQL -c "VACUUM ANALYZE"

echo "==> İndeksli ölçüm..."
{
  echo "# İndeks analizi ölçüm sonuçları"
  echo
  echo "PostgreSQL 16 (Docker), \`scripts/indeks-analiz.sh\`, JIT kapalı, her sorgu $TEKRAR kez, medyan Execution Time."
  echo "Sorgular: \`$KAYNAK\`. Ek ölçüm (ek_arac_garanti): v_arac_garanti_durumu, vin=$VIN"
  echo
  echo "| Sorgu | İndekssiz (ms) | İndeksli (ms) | Hızlanma |"
  echo "|---|---:|---:|---:|"
} > "$OUT/olcum.md"
while read -r f once; do
  ad=$(basename "$f" .sql)
  sonra=$(olc "$f" sonra)
  echo "    $ad: $once -> $sonra ms"
  awk -v a="$ad" -v o="$once" -v s="$sonra" 'BEGIN {printf "| %s | %.2f | %.2f | %.1fx |\n", a, o, s, o / s}' >> "$OUT/olcum.md"
done < "$LISTE"

{
  echo
  echo "## İndeks boyutları"
  echo
  echo '```'
  $PSQL -P pager=off -c "SELECT relname AS tablo, indexrelname AS indeks, pg_size_pretty(pg_relation_size(indexrelid)) AS boyut FROM pg_stat_user_indexes WHERE indexrelname LIKE 'idx\_%' ORDER BY 1, 2"
  echo '```'
  echo
  echo "## Tablo satır sayıları"
  echo
  echo '```'
  $PSQL -P pager=off -c "SELECT relname AS tablo, n_live_tup AS satir FROM pg_stat_user_tables ORDER BY n_live_tup DESC"
  echo '```'
} >> "$OUT/olcum.md"

echo "==> Tamamlandı: $OUT/olcum.md"
