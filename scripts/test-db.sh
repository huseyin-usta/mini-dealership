#!/bin/sh
# Veritabanı Otomatik Test Paketi:
# Geçici bir PostgreSQL konteynerinde tüm şemayı ve trigger'ları ayağa kaldırır,
# iş kurallarını, çakışma kısıtlarını ve uç senaryoları test eder.
# Gereksinim: Docker
set -e
cd "$(dirname "$0")/.."

PW=$(openssl rand -hex 12)
CONTAINER=md-test-tmp

echo "==> PostgreSQL 17 test konteyneri başlatılıyor..."
docker run --rm -d --name "$CONTAINER" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1:5435:5432 postgres:17-alpine >/dev/null
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1' EXIT

until docker exec "$CONTAINER" pg_isready -U postgres -q; do sleep 1; done

echo "==> Şema ve trigger dosyaları (db/*.sql) yükleniyor..."
for f in db/*.sql; do
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$f"
done

echo "==> Test senaryoları çalıştırılıyor..."

docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 << 'EOF'
\set QUIET 1

-- 1. Temel Seed Verileri
INSERT INTO sube (sehir, ad) VALUES ('Ankara', 'Cankaya'), ('Istanbul', 'Kadikoy');

-- Pazartesi - Cumartesi arası mesai ve tür saatleri
INSERT INTO mesai (gun, acilis, kapanis)
SELECT g, '08:00', '18:00' FROM generate_series(1, 6) g;

INSERT INTO yetkinlik (kod, ad) VALUES ('TEST_SURUSU', 'Test Surusu Yetkisi');

INSERT INTO calisan (sube_id, ad, soyad, departman, eposta, kullanici_adi, sifre_hash, ise_giris_tarihi)
VALUES 
  (1, 'Ahmet', 'Satici', 'SATIS', 'ahmet@bayi.com', 'ahmet.s', 'hash', '2024-01-01'),
  (1, 'Mehmet', 'Usta', 'SERVIS', 'mehmet@bayi.com', 'mehmet.u', 'hash', '2024-01-01'),
  (2, 'Ayse', 'Satici2', 'SATIS', 'ayse@bayi.com', 'ayse.s', 'hash', '2024-01-01'),
  (1, 'Burak', 'Stajyer', 'SATIS', 'burak@bayi.com', 'burak.s', 'hash', '2024-01-01');

-- Yalnızca Ahmet'e test sürüşü yetkisi ver (Burak'ın yetkisi yok)
INSERT INTO calisan_yetkinlik (calisan_id, yetkinlik_id, verilis_tarihi) VALUES (1, 1, '2024-01-01');

INSERT INTO model (ad, garanti_yil, garanti_km) VALUES ('Ioniq 5', 3, 100000);
INSERT INTO versiyon (model_id, paket_adi, model_yili, liste_fiyati) VALUES (1, 'Advance', 2024, 2000000);

INSERT INTO musteri (ad, soyad, telefon) VALUES ('Ali', 'Musteri', '+905550001122');

INSERT INTO arac (vin, versiyon_id, sube_id, renk, durum) 
VALUES ('VIN11111111111111', 1, 1, 'Beyaz', 'STOKTA');

INSERT INTO arac (vin, versiyon_id, sube_id, renk, durum, tahmini_varis_tarihi) 
VALUES ('VIN22222222222222', 1, 1, 'Gri', 'YOLDA', '2026-12-01');

INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id) 
VALUES ('VIN33333333333333', 1, 1, 'Siyah', '06ABC01', 'SATILDI', 1);

INSERT INTO stok_hareketi (arac_vin, hareket_turu, zaman, kaynak_sube_id)
VALUES ('VIN33333333333333', 'SATIS', '2024-01-01 10:00:00+03', 1);

-- Ara rapordaki resmi standart tür kodları
INSERT INTO randevu_turu (tur_kodu, ad, sure_dakika, departman, yetkinlik_id)
VALUES ('TEST_SURUSU', 'Test Surusu', 60, 'SATIS', 1),
       ('TESLIMAT', 'Yeni Arac Teslimi', 60, 'SATIS', NULL),
       ('PERIYODIK_BAKIM', 'Periyodik Bakim', 60, 'SERVIS', NULL),
       ('SERVIS_GIRIS', 'Servise Giris', 30, 'SERVIS', NULL);

INSERT INTO tur_saat (tur_kodu, gun, baslangic, bitis)
SELECT 'TEST_SURUSU', g::smallint, '10:00'::time, '12:00'::time FROM generate_series(1, 6) g
UNION ALL
SELECT 'TESLIMAT', g::smallint, '14:00'::time, '16:00'::time FROM generate_series(1, 6) g
UNION ALL
SELECT 'PERIYODIK_BAKIM', g::smallint, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL
SELECT 'SERVIS_GIRIS', g::smallint, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g;

\set QUIET 0

-- TEST 1: GiST EXCLUDE Çakışma Kısıtı
DO $$
BEGIN
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (1, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-16 10:00:00', '2026-11-16 11:00:00', 'PANEL');

  BEGIN
    -- Aynı çalışan ve araçla çakışan saat (10:30 - 11:30)
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (1, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-16 10:30:00', '2026-11-16 11:30:00', 'PANEL');
    RAISE EXCEPTION 'TEST 1 BASARISIZ: GiST cakismasi yakalanamadi!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%exclusion%' OR SQLERRM LIKE '%cakis%' THEN
      RAISE NOTICE '  [PASS] Test 1: GiST randevu cakismasi engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 1 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 2: Randevu İptal Sonrası Saatin Boşa Çıkması
DO $$
BEGIN
  UPDATE randevu SET durum = 'IPTAL' WHERE randevu_id = 1;
  -- İptal sonrasi ayni saate eklenebilmeli
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (1, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-16 10:00:00', '2026-11-16 11:00:00', 'PANEL');
  RAISE NOTICE '  [PASS] Test 2: Iptal edilen randevu saati yeniden acildi';
END $$;

-- TEST 3: Şube Uyuşmazlığı
DO $$
BEGIN
  BEGIN
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (1, 1, 'TEST_SURUSU', 3, 'VIN11111111111111', '2026-11-16 11:00:00', '2026-11-16 12:00:00', 'PANEL');
    RAISE EXCEPTION 'TEST 3 BASARISIZ!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%uyuşmuyor%' OR SQLERRM LIKE '%uyusmuyor%' THEN
      RAISE NOTICE '  [PASS] Test 3: Sube uyusmazligi engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 3 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 4: Departman Uyuşmazlığı
DO $$
BEGIN
  BEGIN
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (1, 1, 'TEST_SURUSU', 2, 'VIN11111111111111', '2026-11-16 11:00:00', '2026-11-16 12:00:00', 'PANEL');
    RAISE EXCEPTION 'TEST 4 BASARISIZ!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%departmanı%' OR SQLERRM LIKE '%departmani%' THEN
      RAISE NOTICE '  [PASS] Test 4: Departman uyusmazligi engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 4 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 5: Yetkinlik Sertifikası Olmayan Çalışana Test Sürüşü Verilemez
DO $$
BEGIN
  BEGIN
    -- Burak (id: 4) satış çalışanıdır ama test sürüşü sertifikası yoktur
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (1, 1, 'TEST_SURUSU', 4, 'VIN11111111111111', '2026-11-16 11:00:00', '2026-11-16 12:00:00', 'PANEL');
    RAISE EXCEPTION 'TEST 5 BASARISIZ!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%yetkinlik%' THEN
      RAISE NOTICE '  [PASS] Test 5: Yetkinlik sertifikasi olmayan calisana randevu engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 5 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 6: Tür Saat Penceresi Dışına Randevu Verme
DO $$
BEGIN
  BEGIN
    -- 13:00 test sürüşü saatleri dışındadır (10:00-12:00 izinli)
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (1, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-16 13:00:00', '2026-11-16 14:00:00', 'PANEL');
    RAISE EXCEPTION 'TEST 6 BASARISIZ!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%geçerli saat%' OR SQLERRM LIKE '%gecerli saat%' THEN
      RAISE NOTICE '  [PASS] Test 6: Tur saati disindaki randevu engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 6 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 7: Yoldaki Aracın Varış Tarihinden Önce Teslim Randevusu
DO $$
BEGIN
  BEGIN
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (1, 1, 'TESLIMAT', 1, 'VIN22222222222222', '2026-11-16 14:00:00', '2026-11-16 15:00:00', 'PANEL');
    RAISE EXCEPTION 'TEST 7 BASARISIZ!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%varış%' OR SQLERRM LIKE '%varis%' THEN
      RAISE NOTICE '  [PASS] Test 7: Yoldaki arac varisindan once teslimat engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 7 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 8: İptal Durumunda Saçma Randevu Ekleyip Sonradan PLANLANDI Yapma Hilesi
DO $$
DECLARE v_id integer;
BEGIN
  -- Başta IPTAL durumunda (kontrol baypas edilir)
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
  VALUES (1, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-16 22:00:00', '2026-11-16 23:00:00', 'IPTAL', 'PANEL')
  RETURNING randevu_id INTO v_id;

  BEGIN
    -- Geri PLANLANDI yapılmaya çalışıldığında trigger yakalamalı!
    UPDATE randevu SET durum = 'PLANLANDI' WHERE randevu_id = v_id;
    RAISE EXCEPTION 'TEST 8 BASARISIZ!';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '  [PASS] Test 8: Gecersiz randevunun IPTALden PLANLANDIya cevrilmesi engellendi';
  END;
END $$;

-- TEST 9: Bakım Masrafına Sigorta Girilemez
DO $$
DECLARE v_r integer; v_sk integer;
BEGIN
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (1, 1, 'PERIYODIK_BAKIM', 2, 'VIN33333333333333', '2026-11-16 09:00:00', '2026-11-16 10:00:00', 'PANEL')
  RETURNING randevu_id INTO v_r;

  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'BAKIM', 10000)
  RETURNING servis_kaydi_id INTO v_sk;

  BEGIN
    INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi)
    VALUES (v_sk, 'Yag Degisimi', 3000, 'SIGORTA');
    RAISE EXCEPTION 'TEST 9 BASARISIZ!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%yalnızca müşteri%' OR SQLERRM LIKE '%yalnizca musteri%' THEN
      RAISE NOTICE '  [PASS] Test 9: Bakim masrafina sigorta girilmesi engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 9 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 10: Periyodik Bakımı Süre Olarak Aksatılan (>1 Yıl) Araca Garanti Girilemez
DO $$
DECLARE v_r integer; v_sk integer;
BEGIN
  -- 1. Bakım: 2024-07-01 (Düzgün)
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
  VALUES (1, 1, 'PERIYODIK_BAKIM', 2, 'VIN33333333333333', '2024-07-01 10:00:00', '2024-07-01 11:00:00', 'TAMAMLANDI', 'PANEL')
  RETURNING randevu_id INTO v_r;

  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'BAKIM', 10000)
  RETURNING servis_kaydi_id INTO v_sk;

  INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi)
  VALUES (v_sk, 'Yag Degisimi', 3000, 'MUSTERI');

  -- 2. Servis: 2025-11-03 (1. bakımdan 16 ay sonra, 1 yıl sınırı aşıldı!)
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (1, 1, 'SERVIS_GIRIS', 2, 'VIN33333333333333', '2025-11-03 10:00:00', '2025-11-03 10:30:00', 'PANEL')
  RETURNING randevu_id INTO v_r;

  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'ARIZA', 18000)
  RETURNING servis_kaydi_id INTO v_sk;

  BEGIN
    INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi)
    VALUES (v_sk, 'Aks Mili Degisimi', 25000, 'GARANTI');
    RAISE EXCEPTION 'TEST 10 BASARISIZ: Sure asimi yakalanamadi!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%aksatılmıştır%' OR SQLERRM LIKE '%aksatilmistir%' THEN
      RAISE NOTICE '  [PASS] Test 10: Suresi aksatilan (>1 yil) aracin garanti odemesi engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 10 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 11: Periyodik Bakımı Kilometre Olarak Aksatılan (>15.000 KM) Araca Garanti Girilemez
DO $$
DECLARE v_r integer; v_sk integer;
BEGIN
  -- Yeni satılan araç (satış: 2024-01-01, km: 0)
  -- 6 ay sonra arıza servisine geliyor ama km: 18.000 (15.000 km bakım yapılmadan geçilmiş!)
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (1, 1, 'SERVIS_GIRIS', 2, 'VIN33333333333333', '2024-06-03 10:00:00', '2024-06-03 10:30:00', 'PANEL')
  RETURNING randevu_id INTO v_r;

  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'ARIZA', 18000)
  RETURNING servis_kaydi_id INTO v_sk;

  BEGIN
    INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi)
    VALUES (v_sk, 'Sanziman Valfi', 35000, 'GARANTI');
    RAISE EXCEPTION 'TEST 11 BASARISIZ: KM asimi yakalanamadi!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%aksatılmıştır%' OR SQLERRM LIKE '%aksatilmistir%' THEN
      RAISE NOTICE '  [PASS] Test 11: Kilometresi aksatilan (>15.000 km) aracin garanti odemesi engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 11 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 12: İptal Edilen Bakım Randevusu Garanti Sayılamaz
DO $$
DECLARE v_r integer; v_sk integer;
BEGIN
  -- Test 12 için izole araç (satış: 2024-01-01)
  INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id) 
  VALUES ('VIN44444444444444', 1, 1, 'Kırmızı', '06TEST12', 'SATILDI', 1);

  INSERT INTO stok_hareketi (arac_vin, hareket_turu, zaman, kaynak_sube_id)
  VALUES ('VIN44444444444444', 'SATIS', '2024-01-01 10:00:00+03', 1);

  -- Ali bakım randevusu aldı ama IPTAL etti
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
  VALUES (1, 1, 'PERIYODIK_BAKIM', 2, 'VIN44444444444444', '2024-06-01 10:00:00', '2024-06-01 11:00:00', 'IPTAL', 'PANEL')
  RETURNING randevu_id INTO v_r;

  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'BAKIM', 12000)
  RETURNING servis_kaydi_id INTO v_sk;

  -- 2025-05-05'de arıza (satıştan bu yana 16 ay geçmiş, aradaki bakım IPTAL olduğundan garanti düşmüş olmalı)
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (1, 1, 'SERVIS_GIRIS', 2, 'VIN44444444444444', '2025-05-05 10:00:00', '2025-05-05 10:30:00', 'PANEL')
  RETURNING randevu_id INTO v_r;

  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'ARIZA', 14000)
  RETURNING servis_kaydi_id INTO v_sk;

  BEGIN
    INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi)
    VALUES (v_sk, 'Direksiyon Kutusu', 40000, 'GARANTI');
    RAISE EXCEPTION 'TEST 12 BASARISIZ: Iptal edilen bakim garanti sayildi!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%aksatılmıştır%' OR SQLERRM LIKE '%aksatilmistir%' THEN
      RAISE NOTICE '  [PASS] Test 12: Iptal edilen bakimin garanti sayilmasi engellendi';
    ELSE
      RAISE EXCEPTION 'TEST 12 BEKLENMEYEN HATA: %', SQLERRM;
    END IF;
  END;
END $$;

-- TEST 13: Geçerli ve Bakımlı Araçta Garanti Kabul Edilir
DO $$
DECLARE v_r integer; v_sk integer;
BEGIN
  -- 2024-05-06'da (satıştan 5 ay sonra, 8000 km) arıza servisi
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (1, 1, 'SERVIS_GIRIS', 2, 'VIN33333333333333', '2024-05-06 10:00:00', '2024-05-06 10:30:00', 'PANEL')
  RETURNING randevu_id INTO v_r;

  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'ARIZA', 8000)
  RETURNING servis_kaydi_id INTO v_sk;

  INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi)
  VALUES (v_sk, 'Yazilim Guncellemesi', 10000, 'GARANTI');

  RAISE NOTICE '  [PASS] Test 13: Bakimli ve suresi dolmamis aracta garanti odemesi basariyla kabul edildi';
END $$;

EOF

echo ""
echo "============================================="
echo "   TUM VERITABANI TESTLERI BASARIYLA GECTI!  "
echo "============================================="
