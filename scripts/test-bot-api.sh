#!/bin/sh
# Bot API Sözleşmesi Test Paketi
#
# docs/api/bot-sozlesmesi.md içindeki endpoint'lerin SQL karşılıklarını geçici
# bir PostgreSQL konteynerinde GERÇEKTEN çalıştırır ve beklenen sonuçları
# doğrular. Şema testi değildir (o: scripts/test-db.sh); bot rolünün gördüğü
# veriyi ve sözleşmedeki SQL'lerin doğruluğunu kanıtlar.
#
# Gereksinim: Docker
# Kullanım:  ./scripts/test-bot-api.sh
set -e
cd "$(dirname "$0")/.."

PW=$(openssl rand -hex 12)
CONTAINER=md-test-bot-api-tmp

echo "==> PostgreSQL 17 test konteyneri başlatılıyor..."
docker run --rm -d --name "$CONTAINER" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1:5436:5432 postgres:17-alpine >/dev/null
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1' EXIT

until docker exec "$CONTAINER" pg_isready -U postgres -q; do sleep 1; done

echo "==> Şema dosyaları (db/*.sql) yükleniyor..."
for f in db/*.sql; do
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$f"
done

echo "==> Endpoint SQL'leri doğrulanıyor..."

docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA << 'EOF'
\set QUIET 1

-- Deterministik çıktı: psql'de NOTICE kanalından PASS/FAIL yazılır
CREATE OR REPLACE FUNCTION pg_temp.kontrol(ad text, kosul boolean, detay text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF kosul THEN
    RAISE NOTICE '[PASS] %', ad;
  ELSE
    RAISE EXCEPTION '[FAIL] % %', ad, detay;
  END IF;
END $$;

\set QUIET 0

-- ---------------------------------------------------------------------------
-- Seed: spec'teki şube ağı (Ankara 2, İstanbul 3, İzmir 1, Bursa 1, Antalya 1)
-- ---------------------------------------------------------------------------
INSERT INTO sube (sehir, ad) VALUES
  ('Ankara',   'Çankaya'),
  ('Ankara',   'Yenimahalle'),
  ('İstanbul', 'Kadıköy'),
  ('İstanbul', 'Beşiktaş'),
  ('İstanbul', 'Ataşehir'),
  ('İzmir',    'Bornova'),
  ('Bursa',    'Nilüfer'),
  ('Antalya',  'Muratpaşa');

-- ===========================================================================
-- GET /bot/sube
-- ===========================================================================

-- 1. Parametresiz: yalnızca şehir adları, tekrarsız ve alfabetik
SELECT pg_temp.kontrol(
  'GET /bot/sube (parametresiz) yalnızca 5 benzersiz şehir döner',
  (SELECT array_agg(sehir::text) FROM (SELECT DISTINCT sehir FROM sube ORDER BY sehir) s)
    = ARRAY['Ankara', 'Antalya', 'Bursa', 'İstanbul', 'İzmir'],
  format('gelen: %s', (SELECT array_agg(sehir::text) FROM (SELECT DISTINCT sehir FROM sube ORDER BY sehir) s))
);

-- 2. DISTINCT şubeleri elemez: şehir başına şube sayısı korunur
SELECT pg_temp.kontrol(
  'Şube sayısı DISTINCT ile kaybolmuyor (Ankara=2, İstanbul=3)',
  (SELECT count(*) FROM sube WHERE sehir = 'Ankara') = 2
    AND (SELECT count(*) FROM sube WHERE sehir = 'İstanbul') = 3,
  format('Ankara=%s İstanbul=%s',
    (SELECT count(*) FROM sube WHERE sehir = 'Ankara'),
    (SELECT count(*) FROM sube WHERE sehir = 'İstanbul'))
);

-- 3. Şehir verilerek: o şehrin şubeleri, alfabetik
SELECT pg_temp.kontrol(
  'GET /bot/sube?sehir=Ankara iki şubeyi alfabetik döner',
  (SELECT array_agg(ad::text ORDER BY ad) FROM sube WHERE sehir = 'Ankara')
    = ARRAY['Yenimahalle', 'Çankaya'],
  format('gelen: %s', (SELECT array_agg(ad::text ORDER BY ad) FROM sube WHERE sehir = 'Ankara'))
);

-- 4. Tek şubeli şehir de eksiksiz döner
SELECT pg_temp.kontrol(
  'GET /bot/sube?sehir=İzmir tek şubeyi döner',
  (SELECT array_agg(ad::text) FROM sube WHERE sehir = 'İzmir') = ARRAY['Bornova']
);

-- 5. Tam eşleşme: farklı harf büyüklüğü eşleşmez (sözleşme kararı: tam eşleşme)
SELECT pg_temp.kontrol(
  'Tam eşleşme: sehir=''ankara'' eşleşmez (SEHIRDE_SUBE_YOK yoluna düşer)',
  (SELECT count(*) FROM sube WHERE sehir = 'ankara') = 0
);

-- 6. Türkçe karakter: 'İstanbul' eşleşir, ASCII 'Istanbul' eşleşmez
SELECT pg_temp.kontrol(
  'Türkçe karakter: İstanbul eşleşir, Istanbul eşleşmez',
  (SELECT count(*) FROM sube WHERE sehir = 'İstanbul') = 3
    AND (SELECT count(*) FROM sube WHERE sehir = 'Istanbul') = 0
);

-- 7. Olmayan şehir: sözleşmedeki detay.mevcut_sehirler alanının kaynağı
SELECT pg_temp.kontrol(
  'Olmayan şehirde 0 şube; mevcut_sehirler 5 şehir döner',
  (SELECT count(*) FROM sube WHERE sehir = 'Kars') = 0
    AND (SELECT count(DISTINCT sehir) FROM sube) = 5
);

-- ===========================================================================
-- Yetki: bot rolü sube tablosunu okuyabilir
-- ===========================================================================
SET ROLE bot;
SELECT pg_temp.kontrol(
  'bot rolü sube tablosunu okuyabiliyor',
  (SELECT count(*) FROM sube) = 8
);
SELECT pg_temp.kontrol(
  'bot rolü DISTINCT şehir sorgusunu çalıştırabiliyor',
  (SELECT count(DISTINCT sehir) FROM sube) = 5
);
RESET ROLE;

-- ===========================================================================
-- Yetki: bot rolü sube tablosuna yazamaz
-- ===========================================================================
SET ROLE bot;
DO $$
BEGIN
  BEGIN
    INSERT INTO sube (sehir, ad) VALUES ('Test', 'Test');
    RAISE EXCEPTION '[FAIL] bot rolü sube tablosuna INSERT edebildi';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE '[PASS] bot rolü sube tablosuna INSERT edemiyor';
  END;
END $$;
RESET ROLE;

\echo ''
\echo '============================================='
\echo '   BOT API SÖZLEŞME TESTLERİ BAŞARIYLA GEÇTİ '
\echo '============================================='
EOF
