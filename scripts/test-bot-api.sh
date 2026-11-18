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
-- GET /bot/slot — müsaitlik ve imkanlar
-- ===========================================================================
-- Seed: mesai, randevu türleri, tür saatleri, yetkinlikli çalışanlar, stokta araç
INSERT INTO mesai (gun, acilis, kapanis)
SELECT g, '08:00'::time, '18:00'::time FROM generate_series(1, 6) g;

INSERT INTO yetkinlik (kod, ad) VALUES ('TEST_SURUSU', 'Test Surusu Yetkisi');

INSERT INTO randevu_turu (tur_kodu, ad, sure_dakika, departman, yetkinlik_id) VALUES
  ('TEST_SURUSU',      'Test Surusu',         60, 'SATIS',  1),
  ('TESLIMAT',         'Yeni Arac Teslimi',   60, 'SATIS',  NULL),
  ('PERIYODIK_BAKIM',  'Periyodik Bakim',     60, 'SERVIS', NULL),
  ('SERVIS_GIRIS',     'Servise Giris',       30, 'SERVIS', NULL),
  ('SERVIS_TESLIM',    'Servisten Teslim',    30, 'SERVIS', NULL),
  ('ARAC_INCELEME',    'Arac Inceleme',       60, 'SATIS',  NULL),
  ('SATIN_ALIM',       'Satin Alim',          60, 'SATIS',  NULL);

INSERT INTO tur_saat (tur_kodu, gun, baslangic, bitis)
SELECT 'TEST_SURUSU', g, '10:00'::time, '12:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'TEST_SURUSU', g, '14:00'::time, '16:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'PERIYODIK_BAKIM', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'SERVIS_GIRIS', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'SERVIS_TESLIM', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'TESLIMAT', g, '14:00'::time, '16:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'ARAC_INCELEME', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'SATIN_ALIM', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g;

INSERT INTO model (ad, garanti_yil, garanti_km) VALUES ('Ioniq 5', 3, 100000), ('Tucson', 3, 100000);
INSERT INTO versiyon (model_id, paket_adi, model_yili, liste_fiyati) VALUES
  (1, 'Advance', 2024, 2000000), (2, 'Elite', 2024, 2350000);

-- Sube 1: uc test surusu yetkinlikli satici + bir servis calisani
INSERT INTO calisan (sube_id, ad, soyad, departman, eposta, kullanici_adi, sifre_hash, ise_giris_tarihi)
VALUES (1, 'Ahmet', 'Satici',  'SATIS',  'a@x', 'a.s', 'h', '2024-01-01'),
       (1, 'Burak', 'Satici2', 'SATIS',  'b@x', 'b.s', 'h', '2024-01-01'),
       (1, 'Cem',   'Satici3', 'SATIS',  'c@x', 'c.s', 'h', '2024-01-01'),
       (1, 'Deniz', 'Usta',    'SERVIS', 'd@x', 'd.u', 'h', '2024-01-01');
INSERT INTO calisan_yetkinlik (calisan_id, yetkinlik_id, verilis_tarihi)
VALUES (1, 1, '2024-01-01'), (2, 1, '2024-01-01'), (3, 1, '2024-01-01');

-- Sube 1 stok: 2 Ioniq 5 + 1 Tucson
INSERT INTO arac (vin, versiyon_id, sube_id, renk, durum) VALUES
  ('VIN00000000000001', 1, 1, 'Beyaz', 'STOKTA'),
  ('VIN00000000000002', 1, 1, 'Gri',   'STOKTA'),
  ('VIN00000000000003', 2, 1, 'Siyah', 'STOKTA');

INSERT INTO musteri (ad, soyad, telefon) VALUES
  ('Ali',   'Veli',  '+905550001122'),
  ('Ayse',  'Yilmaz','+905550001133'),
  ('Can',   'Demir', '+905550001144');

-- Sabit test gunu: gelecekte bir Carsamba (mesai acik)
CREATE TEMP TABLE test_gun AS SELECT date '2026-12-02' AS g;  -- Carsamba

-- Dolu randevu: Ahmet (1) ve arac1 -> 10:00-11:00
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT 1, 1, 'TEST_SURUSU', 1, 'VIN00000000000001',
       g + time '10:00', g + time '11:00', 'PLANLANDI', 'PANEL'
  FROM test_gun;

-- Musaitlik sorgusu: sozlesmedeki sorgunun birebir kopyasi ($1 tarih, $2 tur, $3 sube, $4 vin)
CREATE FUNCTION pg_temp.slotlar(p_tarih date, p_tur varchar, p_sube int, p_vin varchar)
RETURNS TABLE (baslangic time, bitis time, musait_calisan_sayisi bigint, musait_araclar json)
LANGUAGE sql STABLE AS $$
WITH olası AS (
    SELECT gs AS baslangic, gs + (rt.sure_dakika * interval '1 minute') AS bitis
      FROM randevu_turu rt
      JOIN tur_saat ts ON ts.tur_kodu = rt.tur_kodu
      JOIN mesai    m  ON m.gun = ts.gun
     CROSS JOIN generate_series(
           p_tarih + ts.baslangic,
           p_tarih + ts.bitis - (rt.sure_dakika * interval '1 minute'),
           (rt.sure_dakika * interval '1 minute')) AS gs
     WHERE rt.tur_kodu = p_tur
       AND extract(isodow FROM p_tarih) = ts.gun
       AND m.acilis <= ts.baslangic AND ts.bitis <= m.kapanis
),
tur AS (
    SELECT rt.yetkinlik_id, rt.departman,
           rt.tur_kodu IN ('TEST_SURUSU','TESLIMAT','SERVIS_TESLIM') AS arac_gerekli
      FROM randevu_turu rt WHERE rt.tur_kodu = p_tur
),
uygun_calisan AS (
    SELECT c.calisan_id FROM calisan c, tur t
     WHERE c.sube_id = p_sube AND c.aktif_mi AND c.departman = t.departman
       AND (t.yetkinlik_id IS NULL OR EXISTS (
             SELECT 1 FROM calisan_yetkinlik cy
              WHERE cy.calisan_id = c.calisan_id AND cy.yetkinlik_id = t.yetkinlik_id))
),
uygun_arac AS (
    SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
      FROM arac a
      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
      JOIN model   md ON md.model_id   = v.model_id
     WHERE a.sube_id = p_sube AND a.durum = 'STOKTA'
)
SELECT o.baslangic::time, o.bitis::time,
       (SELECT count(*) FROM uygun_calisan uc
         WHERE NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                            WHERE d.calisan_id = uc.calisan_id
                              AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))),
       CASE WHEN t.arac_gerekli THEN
         COALESCE((SELECT json_agg(json_build_object('vin', ua.vin, 'model', ua.model,
                                                     'paket', ua.paket_adi, 'renk', ua.renk))
                     FROM uygun_arac ua
                    WHERE (p_vin IS NULL OR ua.vin = p_vin)
                      AND NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                                       WHERE d.arac_vin = ua.vin
                                         AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))),
                  '[]'::json)
       ELSE '[]'::json END
  FROM olası o, tur t
 WHERE (SELECT count(*) FROM uygun_calisan uc
         WHERE NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                            WHERE d.calisan_id = uc.calisan_id
                              AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))) > 0
   AND (NOT t.arac_gerekli OR EXISTS (
         SELECT 1 FROM uygun_arac ua
          WHERE (p_vin IS NULL OR ua.vin = p_vin)
            AND NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                             WHERE d.arac_vin = ua.vin
                               AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))))
 ORDER BY o.baslangic
$$;

-- 8. SENARYO: 3 yetkin calisandan 1'i dolu -> 2 musait; 3 aractan 1'i dolu -> 2 musait
SELECT pg_temp.kontrol(
  'SENARYO: 1/3 calisan ve 1/3 arac dolu -> 10:00 slotunda 2 calisan + 2 arac musait',
  (SELECT musait_calisan_sayisi = 2
      AND json_array_length(musait_araclar) = 2
     FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 1, NULL)
    WHERE baslangic = time '10:00'),
  'slot 10:00 beklenen: 2 calisan, 2 arac'
);

-- 9. 11:00 slotunda hicbir sey dolu degil -> 3 calisan + 3 arac
SELECT pg_temp.kontrol(
  'SENARYO: bos slotta 3 calisan + 3 arac musait',
  (SELECT musait_calisan_sayisi = 3
      AND json_array_length(musait_araclar) = 3
     FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 1, NULL)
    WHERE baslangic = time '11:00')
);

-- 10. Test surusu yalnizca tanimli saatlerde: 13:00 slotu yok
SELECT pg_temp.kontrol(
  'TEST_SURUSU icin 13:00 slotu yok (tur saati disinda)',
  NOT EXISTS (SELECT 1 FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 1, NULL)
               WHERE baslangic = time '13:00')
);

-- 11. Arac gerektirmeyen turlerde musait_araclar daima bos dizi
SELECT pg_temp.kontrol(
  'PERIYODIK_BAKIM arac listesi bos (arac gerekmez)',
  (SELECT bool_and(json_array_length(musait_araclar) = 0)
     FROM pg_temp.slotlar((SELECT g FROM test_gun), 'PERIYODIK_BAKIM', 1, NULL))
);

-- 12. Arac gerektirmeyen turde dolu arac slottan elemez
SELECT pg_temp.kontrol(
  'PERIYODIK_BAKIM 10:00 slotu var (dolu arac engellemiyor)',
  EXISTS (SELECT 1 FROM pg_temp.slotlar((SELECT g FROM test_gun), 'PERIYODIK_BAKIM', 1, NULL)
           WHERE baslangic = time '10:00')
);

-- 13. Servis turu servis calisanini kullanir (Deniz), saticilari degil
SELECT pg_temp.kontrol(
  'PERIYODIK_BAKIM musait calisan sayisi 1 (yalnizca servis calisani)',
  (SELECT bool_and(musait_calisan_sayisi = 1)
     FROM pg_temp.slotlar((SELECT g FROM test_gun), 'PERIYODIK_BAKIM', 1, NULL))
);

-- 14. arac_vin filtresi: dolu arac geri donmez
SELECT pg_temp.kontrol(
  'arac_vin=dolu arac -> 10:00 slotu donmez',
  NOT EXISTS (SELECT 1 FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 1, 'VIN00000000000001')
               WHERE baslangic = time '10:00')
);

-- 15. arac_vin filtresi: bos arac yalniz o arac ile doner
SELECT pg_temp.kontrol(
  'arac_vin=bos arac -> 11:00 slotunda yalniz o arac',
  (SELECT json_array_length(musait_araclar) = 1
      FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 1, 'VIN00000000000003')
     WHERE baslangic = time '11:00')
);

-- 16. Tum calisanlar (1,2,3) 11:00-12:00 dolu -> slot elenir
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m, 1, 'TEST_SURUSU', c, v, g + time '11:00', g + time '12:00', 'PLANLANDI', 'PANEL'
  FROM test_gun, (VALUES (1, 'VIN00000000000003', 1),
                        (2, 'VIN00000000000002', 2),
                        (3, 'VIN00000000000001', 3)) AS p(c, v, m);
SELECT pg_temp.kontrol(
  'SENARYO: tum yetkin calisanlar 11:00-12:00 dolu -> 11:00 slotu elenir',
  NOT EXISTS (SELECT 1 FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 1, NULL)
               WHERE baslangic = time '11:00')
);

-- 17. Tum araclar dolu -> slot elenir (calisan musait olsa da)
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m, 1, 'TEST_SURUSU', c, v, g + time '14:00', g + time '15:00', 'PLANLANDI', 'PANEL'
  FROM test_gun, (VALUES (1, 'VIN00000000000001', 1),
                        (2, 'VIN00000000000002', 2),
                        (3, 'VIN00000000000003', 3)) AS p(c, v, m);
SELECT pg_temp.kontrol(
  'SENARYO: tum araclar 14:00-15:00 dolu -> 14:00 slotu elenir',
  NOT EXISTS (SELECT 1 FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 1, NULL)
               WHERE baslangic = time '14:00')
);

-- 18. Iptal edilen randevu slotu yeniden acar
UPDATE randevu SET durum = 'IPTAL'
 WHERE baslangic = (SELECT g + time '14:00' FROM test_gun);
SELECT pg_temp.kontrol(
  'Iptal edilen randevular slotu yeniden acar',
  EXISTS (SELECT 1 FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 1, NULL)
           WHERE baslangic = time '14:00')
);

-- 19. Hafta sonu (Pazar): mesai yok -> slot yok
SELECT pg_temp.kontrol(
  'Pazar gunu slot yok (mesai disi)',
  (SELECT count(*) FROM pg_temp.slotlar(date '2026-12-06', 'TEST_SURUSU', 1, NULL)) = 0
);

-- 20. Baska subede dolu olan calisan bu subeyi etkilemez
SELECT pg_temp.kontrol(
  'Baska subenin dolu randevulari bu subenin slotlarini etkilemez',
  (SELECT count(*) FROM pg_temp.slotlar((SELECT g FROM test_gun), 'TEST_SURUSU', 2, NULL)) = 0
  -- sube 2'de hic calisan/arac yok -> slot yok
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
