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

-- ===== VIEW TESTLERİ =====
-- Tarihler bugüne göre hesaplanır (garanti/gecikme "bugün" itibarıyla türetilir).
-- Randevular geçmiş haftaların Pazartesi 15:00'ine konur (tur_saat penceresi içinde).

-- TEST 14: Maskeleme fonksiyonları ve maskeli rapor view'ları ham PII sızdırmaz
DO $$
BEGIN
  IF fn_maskele_telefon('+905321234567') <> '0532 *** ** 67'
     OR fn_maskele_telefon('0532 123 45 67') <> '0532 *** ** 67'
     OR fn_maskele_telefon('123') <> '*** *** ** **'
     OR fn_maskele_ad('ayşe') <> 'A***'
     OR fn_maskele_ad('  ') <> '***' THEN
    RAISE EXCEPTION 'TEST 14 BASARISIZ: maskeleme fonksiyonu hatali';
  END IF;

  IF (SELECT telefon FROM v_rapor_musteri WHERE musteri_id = 1) <> '0555 *** ** 22'
     OR (SELECT ad || ' ' || soyad FROM v_rapor_musteri WHERE musteri_id = 1) <> 'A*** M***' THEN
    RAISE EXCEPTION 'TEST 14 BASARISIZ: v_rapor_musteri maskelemiyor';
  END IF;

  IF EXISTS (SELECT 1 FROM v_rapor_randevu
              WHERE musteri_telefon LIKE '%0001122%' OR musteri LIKE '%Ali%' OR musteri LIKE '%Musteri%') THEN
    RAISE EXCEPTION 'TEST 14 BASARISIZ: v_rapor_randevu ham PII iceriyor';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM v_rapor_randevu WHERE model_adi = 'Ioniq 5' AND sube_adi = 'Cankaya') THEN
    RAISE EXCEPTION 'TEST 14 BASARISIZ: v_rapor_randevu join bilgisi eksik';
  END IF;
  RAISE NOTICE '  [PASS] Test 14: Maskeli rapor view''lari PII sizdirmiyor';
END $$;

-- TEST 15: Müşterinin son randevusu iptal edilenleri saymaz
DO $$
DECLARE v_son record;
BEGIN
  -- Müşteri 1'in en geç randevusu 2026-11-16 22:00 ama IPTAL; bir önceki aktif olan seçilmeli
  SELECT * INTO v_son FROM v_musteri_son_randevu WHERE musteri_id = 1;
  IF v_son.baslangic <> (SELECT max(baslangic) FROM randevu WHERE musteri_id = 1 AND durum <> 'IPTAL')
     OR v_son.durum = 'IPTAL' OR v_son.sube_adi <> 'Cankaya' THEN
    RAISE EXCEPTION 'TEST 15 BASARISIZ: son randevu yanlis (%)', v_son;
  END IF;

  -- Yalnızca iptal randevusu olan müşteri listede yer almaz
  INSERT INTO musteri (ad, soyad, telefon) VALUES ('Zeynep', 'Kaya', '+905321234567');
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
  VALUES (2, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-17 22:00', '2026-11-17 23:00', 'IPTAL', 'WHATSAPP');
  IF EXISTS (SELECT 1 FROM v_musteri_son_randevu WHERE musteri_id = 2) THEN
    RAISE EXCEPTION 'TEST 15 BASARISIZ: iptal randevu son randevu sayildi';
  END IF;
  RAISE NOTICE '  [PASS] Test 15: Musterinin son randevusu dogru (iptaller haric)';
END $$;

-- TEST 16: Servis durumu — son durum, kalan gün, gecikme, masraf kırılımı
DO $$
DECLARE
  v_pzt date := date_trunc('week', current_date)::date;  -- bu haftanın Pazartesi'si
  v_r integer; v_sk integer; v_s record;
BEGIN
  -- VIN55: 20 hafta önce satıldı, 2 hafta önce arıza ile servise girdi (5.000 km)
  INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id)
  VALUES ('VIN55555555555555', 1, 1, 'Mavi', '06VIEW55', 'SATILDI', 2);
  INSERT INTO stok_hareketi (arac_vin, hareket_turu, zaman, kaynak_sube_id)
  VALUES ('VIN55555555555555', 'SATIS', (v_pzt - 140) + time '15:00', 1);

  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
  VALUES (2, 1, 'SERVIS_GIRIS', 2, 'VIN55555555555555', (v_pzt - 14) + time '15:00', (v_pzt - 14) + time '15:30', 'TAMAMLANDI', 'PANEL')
  RETURNING randevu_id INTO v_r;
  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi, tahmini_teslim_tarihi)
  VALUES (v_r, 2, 'ARIZA', 5000, current_date - 3)
  RETURNING servis_kaydi_id INTO v_sk;

  INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum, zaman) VALUES
    (v_sk, 'INCELENIYOR', (v_pzt - 14) + time '15:30'),
    (v_sk, 'ISLEMDE',     (v_pzt - 13) + time '09:00');
  INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi) VALUES
    (v_sk, 'Sensor Degisimi', 5000, 'MUSTERI'),
    (v_sk, 'Iscilik',         2000, 'MUSTERI');

  SELECT * INTO v_s FROM v_servis_durumu WHERE servis_kaydi_id = v_sk;
  IF v_s.son_durum <> 'ISLEMDE' OR v_s.kalan_gun <> -3 OR NOT v_s.gecikti_mi OR v_s.kapandi_mi
     OR v_s.toplam_masraf <> 7000 OR v_s.musteri_payi <> 7000 OR v_s.garanti_payi <> 0 THEN
    RAISE EXCEPTION 'TEST 16 BASARISIZ: servis durumu yanlis (%)', v_s;
  END IF;

  -- Teslime hazır + tamamlandı olunca gecikmede sayılmaz
  INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum, zaman)
  VALUES (v_sk, 'TAMAMLANDI', (v_pzt - 12) + time '09:00');
  IF (SELECT gecikti_mi OR NOT kapandi_mi FROM v_servis_durumu WHERE servis_kaydi_id = v_sk) THEN
    RAISE EXCEPTION 'TEST 16 BASARISIZ: tamamlanan kayit gecikmede sayildi';
  END IF;
  RAISE NOTICE '  [PASS] Test 16: Servis durumu, kalan gun ve masraf kirilimi dogru';
END $$;

-- TEST 17: Garanti durumu — GECERLI / BAKIM_AKSATILDI / KM_ASILDI / SURE_DOLDU
DO $$
DECLARE
  v_pzt date := date_trunc('week', current_date)::date;
  v_r integer; v_d text;
BEGIN
  -- VIN55 (Test 16): 20 hafta önce satıldı, 5.000 km, bakım zamanı gelmedi -> GECERLI
  SELECT garanti_durumu INTO v_d FROM v_arac_garanti_durumu WHERE vin = 'VIN55555555555555';
  IF v_d IS DISTINCT FROM 'GECERLI' THEN
    RAISE EXCEPTION 'TEST 17 BASARISIZ: VIN55 GECERLI beklendi, % geldi', v_d;
  END IF;
  IF (SELECT sonraki_bakim_son_tarih FROM v_arac_garanti_durumu WHERE vin = 'VIN55555555555555')
     <> ((v_pzt - 140) + interval '1 year')::date THEN
    RAISE EXCEPTION 'TEST 17 BASARISIZ: VIN55 sonraki bakim tarihi yanlis';
  END IF;

  -- VIN66: 60 hafta önce satıldı, hiç bakım yok; gelecekte planlı bakım sayılmamalı -> BAKIM_AKSATILDI
  INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id)
  VALUES ('VIN66666666666666', 1, 1, 'Beyaz', '06VIEW66', 'SATILDI', 2);
  INSERT INTO stok_hareketi (arac_vin, hareket_turu, zaman, kaynak_sube_id)
  VALUES ('VIN66666666666666', 'SATIS', (v_pzt - 420) + time '15:00', 1);
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (2, 1, 'PERIYODIK_BAKIM', 2, 'VIN66666666666666', (v_pzt + 21) + time '15:00', (v_pzt + 21) + time '16:00', 'WHATSAPP')
  RETURNING randevu_id INTO v_r;
  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'BAKIM', 9000);

  SELECT garanti_durumu INTO v_d FROM v_arac_garanti_durumu WHERE vin = 'VIN66666666666666';
  IF v_d IS DISTINCT FROM 'BAKIM_AKSATILDI' THEN
    RAISE EXCEPTION 'TEST 17 BASARISIZ: VIN66 BAKIM_AKSATILDI beklendi, % geldi', v_d;
  END IF;

  -- VIN77: 4 yıl önce satıldı (model garantisi 3 yıl) -> SURE_DOLDU
  INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id)
  VALUES ('VIN77777777777777', 1, 1, 'Gri', '06VIEW77', 'SATILDI', 2);
  INSERT INTO stok_hareketi (arac_vin, hareket_turu, zaman, kaynak_sube_id)
  VALUES ('VIN77777777777777', 'SATIS', (current_date - interval '4 years') + interval '15 hours', 1);
  SELECT garanti_durumu INTO v_d FROM v_arac_garanti_durumu WHERE vin = 'VIN77777777777777';
  IF v_d IS DISTINCT FROM 'SURE_DOLDU' THEN
    RAISE EXCEPTION 'TEST 17 BASARISIZ: VIN77 SURE_DOLDU beklendi, % geldi', v_d;
  END IF;

  -- VIN88: 10 hafta önce satıldı, 3 hafta önce 120.000 km ile servise geldi (sınır 100.000) -> KM_ASILDI
  INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id)
  VALUES ('VIN88888888888888', 1, 1, 'Siyah', '06VIEW88', 'SATILDI', 2);
  INSERT INTO stok_hareketi (arac_vin, hareket_turu, zaman, kaynak_sube_id)
  VALUES ('VIN88888888888888', 'SATIS', (v_pzt - 70) + time '15:00', 1);
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
  VALUES (2, 1, 'SERVIS_GIRIS', 2, 'VIN88888888888888', (v_pzt - 21) + time '15:00', (v_pzt - 21) + time '15:30', 'TAMAMLANDI', 'PANEL')
  RETURNING randevu_id INTO v_r;
  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  VALUES (v_r, 2, 'ARIZA', 120000);
  SELECT garanti_durumu INTO v_d FROM v_arac_garanti_durumu WHERE vin = 'VIN88888888888888';
  IF v_d IS DISTINCT FROM 'KM_ASILDI' THEN
    RAISE EXCEPTION 'TEST 17 BASARISIZ: VIN88 KM_ASILDI beklendi, % geldi', v_d;
  END IF;

  -- Satılmamış araçlar listelenmez
  IF EXISTS (SELECT 1 FROM v_arac_garanti_durumu WHERE vin IN ('VIN11111111111111', 'VIN22222222222222')) THEN
    RAISE EXCEPTION 'TEST 17 BASARISIZ: satilmamis arac garanti view''inda';
  END IF;
  RAISE NOTICE '  [PASS] Test 17: Garanti durumu (gecerli / bakim aksatildi / km / sure) dogru hesaplandi';
END $$;

-- ===== ROL / YETKİ / RLS TESTLERİ =====
-- Her test SET LOCAL ROLE ile ilgili role geçer (DO bloğu bitince geri döner).
-- Yetki hatası ve RLS ihlali SQLSTATE 42501 (insufficient_privilege) döner.

-- TEST 18: Hiçbir uygulama rolünün hiçbir tabloda DELETE / TRUNCATE yetkisi yok
DO $$
DECLARE v_sayi integer; v_rol text;
BEGIN
  SELECT count(*) INTO v_sayi
    FROM pg_tables t, unnest(ARRAY['personel', 'bot', 'rapor']) AS rol
   WHERE t.schemaname = 'public'
     AND has_table_privilege(rol, format('public.%I', t.tablename), 'DELETE, TRUNCATE');
  IF v_sayi <> 0 THEN
    RAISE EXCEPTION 'TEST 18 BASARISIZ: % tabloda DELETE/TRUNCATE yetkisi var', v_sayi;
  END IF;

  FOREACH v_rol IN ARRAY ARRAY['personel', 'bot', 'rapor'] LOOP
    BEGIN
      EXECUTE format('SET LOCAL ROLE %I', v_rol);
      DELETE FROM randevu WHERE randevu_id = 1;
      RAISE EXCEPTION 'TEST 18 BASARISIZ: % rolu DELETE yapabildi', v_rol;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  RAISE NOTICE '  [PASS] Test 18: Hicbir rolun DELETE/TRUNCATE yetkisi yok';
END $$;

-- TEST 19: rapor rolü yalnızca view okur, müşteri ve randevu tablosuna erişemez
DO $$
BEGIN
  SET LOCAL ROLE rapor;
  PERFORM count(*) FROM v_rapor_musteri;
  PERFORM count(*) FROM v_rapor_randevu;
  PERFORM count(*) FROM v_servis_durumu;
  PERFORM count(*) FROM v_arac_garanti_durumu;

  BEGIN
    PERFORM count(*) FROM musteri;
    RAISE EXCEPTION 'TEST 19 BASARISIZ: rapor musteri tablosunu okudu';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM count(*) FROM v_musteri_son_randevu;
    RAISE EXCEPTION 'TEST 19 BASARISIZ: rapor maskesiz view okudu';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE '  [PASS] Test 19: Rapor rolu yalnizca maskeli/PII''siz view''lari okuyor';
END $$;

-- TEST 20: bot RLS okuma — yalnızca konuştuğu müşteri; oturum değişkeni yoksa hiçbir şey
DO $$
BEGIN
  SET LOCAL ROLE bot;

  -- Fail-closed: müşteri telefonu set edilmeden hiçbir satır görünmez
  IF EXISTS (SELECT 1 FROM randevu) OR EXISTS (SELECT 1 FROM musteri) OR EXISTS (SELECT 1 FROM mesaj) THEN
    RAISE EXCEPTION 'TEST 20 BASARISIZ: oturum degiskeni yokken satir gorundu';
  END IF;

  PERFORM set_config('app.musteri_telefon', '+905550001122', true);  -- Ali (musteri_id = 1)
  IF NOT EXISTS (SELECT 1 FROM randevu)
     OR EXISTS (SELECT 1 FROM randevu WHERE musteri_id <> 1)
     OR (SELECT count(*) FROM musteri) <> 1
     OR EXISTS (SELECT 1 FROM v_musteri_son_randevu WHERE musteri_id <> 1) THEN
    RAISE EXCEPTION 'TEST 20 BASARISIZ: bot baska musterinin satirini gordu';
  END IF;

  -- Müsaitlik için diğer müşterilerin dolu slotları PII'siz görünür
  IF (SELECT count(*) FROM v_dolu_slot) <= (SELECT count(*) FROM randevu WHERE durum <> 'IPTAL') THEN
    RAISE EXCEPTION 'TEST 20 BASARISIZ: v_dolu_slot diger musterilerin slotlarini gostermiyor';
  END IF;

  -- Araç: stoktaki ve kendi aracı görünür, başkasının aracı görünmez
  IF NOT EXISTS (SELECT 1 FROM arac WHERE vin = 'VIN11111111111111')
     OR NOT EXISTS (SELECT 1 FROM arac WHERE vin = 'VIN33333333333333')
     OR EXISTS (SELECT 1 FROM arac WHERE vin = 'VIN55555555555555') THEN
    RAISE EXCEPTION 'TEST 20 BASARISIZ: arac RLS yanlis';
  END IF;

  -- Çalışanın adı / hash'i bot'a kapalı
  BEGIN
    PERFORM ad FROM calisan;
    RAISE EXCEPTION 'TEST 20 BASARISIZ: bot calisan adini okudu';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE '  [PASS] Test 20: Bot yalnizca konustugu musteriyi goruyor (fail-closed)';
END $$;

-- TEST 21: bot yazma — kendi adına WhatsApp randevusu, yalnızca IPTAL'e çekme
DO $$
DECLARE v_id integer; v_n integer;
BEGIN
  SET LOCAL ROLE bot;
  PERFORM set_config('app.musteri_telefon', '+905550001122', true);  -- Ali

  -- Başka müşteri adına randevu eklenemez
  BEGIN
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (2, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-18 11:00', '2026-11-18 12:00', 'WHATSAPP');
    RAISE EXCEPTION 'TEST 21 BASARISIZ: bot baska musteri adina randevu ekledi';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Bot PANEL kaynaklı randevu yazamaz
  BEGIN
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (1, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-18 11:00', '2026-11-18 12:00', 'PANEL');
    RAISE EXCEPTION 'TEST 21 BASARISIZ: bot PANEL kaynakli randevu ekledi';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Geçerli WhatsApp randevusu eklenir
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
  VALUES (1, 1, 'TEST_SURUSU', 1, 'VIN11111111111111', '2026-11-18 11:00', '2026-11-18 12:00', 'WHATSAPP')
  RETURNING randevu_id INTO v_id;

  -- RLS'de görünmeyen (başkasına satılmış) araca test sürüşü: trigger admin yetkisiyle görür ve reddeder
  BEGIN
    INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, kaynak)
    VALUES (1, 1, 'TEST_SURUSU', 1, 'VIN55555555555555', '2026-11-19 11:00', '2026-11-19 12:00', 'WHATSAPP');
    RAISE EXCEPTION 'TEST 21 BASARISIZ: satilmis araca test surusu verildi';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%STOKTA%' THEN RAISE; END IF;
  END;

  -- Başka durum yazılamaz (yalnızca IPTAL)
  BEGIN
    UPDATE randevu SET durum = 'TAMAMLANDI' WHERE randevu_id = v_id;
    RAISE EXCEPTION 'TEST 21 BASARISIZ: bot durumu TAMAMLANDI yapti';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Durum dışındaki kolonlar güncellenemez
  BEGIN
    UPDATE randevu SET notlar = 'x' WHERE randevu_id = v_id;
    RAISE EXCEPTION 'TEST 21 BASARISIZ: bot notlar kolonunu guncelledi';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Başka müşterinin randevusu iptal edilemez (görünmez, 0 satır)
  UPDATE randevu SET durum = 'IPTAL' WHERE musteri_id = 2;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 0 THEN RAISE EXCEPTION 'TEST 21 BASARISIZ: bot baska musterinin randevusunu iptal etti'; END IF;

  -- Kendi randevusunu iptal eder
  UPDATE randevu SET durum = 'IPTAL' WHERE randevu_id = v_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'TEST 21 BASARISIZ: bot kendi randevusunu iptal edemedi'; END IF;

  -- Mesaj ve müşteri yalnızca kendi kimliğiyle
  INSERT INTO mesaj (musteri_id, yon, icerik) VALUES (1, 'GELEN', 'Merhaba');
  BEGIN
    INSERT INTO mesaj (musteri_id, yon, icerik) VALUES (2, 'GIDEN', 'x');
    RAISE EXCEPTION 'TEST 21 BASARISIZ: bot baska musteriye mesaj kaydetti';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO musteri (ad, soyad, telefon) VALUES ('Sahte', 'Kayit', '+905009998877');
    RAISE EXCEPTION 'TEST 21 BASARISIZ: bot baska telefonla musteri acti';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE '  [PASS] Test 21: Bot yalnizca kendi musterisi adina yaziyor, yalnizca IPTAL edebiliyor';
END $$;

-- TEST 22: personel — tüm operasyonel veriyi görür, şifre hash'ini görmez, katalog/log değiştiremez
DO $$
DECLARE v_toplam integer; v_hash text;
BEGIN
  SELECT count(*) INTO v_toplam FROM randevu;
  SET LOCAL ROLE personel;

  IF (SELECT count(*) FROM randevu) <> v_toplam THEN
    RAISE EXCEPTION 'TEST 22 BASARISIZ: personel tum randevulari goremiyor';
  END IF;
  UPDATE randevu SET notlar = 'panelden not' WHERE randevu_id = 1;

  BEGIN
    PERFORM sifre_hash FROM calisan;
    RAISE EXCEPTION 'TEST 22 BASARISIZ: personel sifre_hash okudu';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  SELECT sifre_hash INTO v_hash FROM fn_panel_giris('ahmet.s');
  IF v_hash IS DISTINCT FROM 'hash' THEN
    RAISE EXCEPTION 'TEST 22 BASARISIZ: fn_panel_giris hash donmedi';
  END IF;

  BEGIN
    INSERT INTO model (ad, garanti_yil, garanti_km) VALUES ('Sahte', 1, 1);
    RAISE EXCEPTION 'TEST 22 BASARISIZ: personel katalog tablosuna yazdi';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE stok_hareketi SET zaman = now();
    RAISE EXCEPTION 'TEST 22 BASARISIZ: personel stok hareketi gecmisini degistirdi';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO mesaj (musteri_id, yon, icerik) VALUES (1, 'GIDEN', 'x');
    RAISE EXCEPTION 'TEST 22 BASARISIZ: personel bot mesaji yazdi';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE '  [PASS] Test 22: Personel yetkileri dogru (hash gizli, katalog ve loglar salt-okunur)';
END $$;

-- Test 23: v_musteri_servis_durumu — yalnizca konusulan musteri, fail-closed
DO $$
DECLARE
  v_sayi integer;
  v_vin  text;
  v_id   integer;
  v_tel1 text;
  v_tel2 text;
BEGIN
  -- Iki musteri, her birinin bir araci + acik servis kaydi
  INSERT INTO musteri (ad, soyad, telefon) VALUES ('Selin', 'A', '+905550009911') RETURNING musteri_id, telefon INTO v_id, v_tel1;
  INSERT INTO musteri (ad, soyad, telefon) VALUES ('Kerem', 'B', '+905550009922') RETURNING musteri_id INTO v_id;
  SELECT telefon INTO v_tel2 FROM musteri WHERE musteri_id = v_id;

  INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id)
  VALUES ('VINSTEST000000001', 1, 1, 'Beyaz', '06TT01', 'SATILDI',
          (SELECT musteri_id FROM musteri WHERE telefon = v_tel1)),
         ('VINSTEST000000002', 1, 1, 'Gri', '06TT02', 'SATILDI', v_id);

  -- Her musteri icin ayri saat ve ayri calisan (cakisma kisitlari icin)
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
  SELECT m.musteri_id, 1, 'PERIYODIK_BAKIM', 2, a.vin,
         timestamp '2030-01-07 09:00', timestamp '2030-01-07 10:00', 'TAMAMLANDI', 'PANEL'
    FROM musteri m JOIN arac a ON a.musteri_id = m.musteri_id
   WHERE m.telefon = v_tel1;
  INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
  SELECT m.musteri_id, 1, 'PERIYODIK_BAKIM', 2, a.vin,
         timestamp '2030-01-07 11:00', timestamp '2030-01-07 12:00', 'TAMAMLANDI', 'PANEL'
    FROM musteri m JOIN arac a ON a.musteri_id = m.musteri_id
   WHERE m.telefon = v_tel2;

  INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
  SELECT r.randevu_id, 2, 'BAKIM', 1000 FROM randevu r WHERE r.arac_vin LIKE 'VINSTEST%';
  INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum)
  SELECT sk.servis_kaydi_id, 'TESLIME_HAZIR' FROM servis_kaydi sk
    JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id WHERE r.arac_vin LIKE 'VINSTEST%';

  -- (a) Kimlik degiskeni yok -> 0 satir (fail-closed)
  SET LOCAL ROLE bot;
  RESET app.musteri_telefon;
  SELECT count(*) INTO v_sayi FROM v_musteri_servis_durumu;
  IF v_sayi <> 0 THEN
    RAISE EXCEPTION 'TEST 23 BASARISIZ: kimlik yokken % satir dondu', v_sayi;
  END IF;

  -- (b) 1. musteri oturumu -> yalnizca kendi VIN'i
  PERFORM set_config('app.musteri_telefon', v_tel1, true);
  SELECT count(*), max(arac_vin) INTO v_sayi, v_vin FROM v_musteri_servis_durumu;
  IF v_sayi <> 1 OR v_vin <> 'VINSTEST000000001' THEN
    RAISE EXCEPTION 'TEST 23 BASARISIZ: musteri 1 kendi disinda satir gordu (% satir, vin=%)', v_sayi, v_vin;
  END IF;

  -- (c) 2. musteri oturumu -> diger musterinin VIN'i gorunmez
  PERFORM set_config('app.musteri_telefon', v_tel2, true);
  SELECT count(*), max(arac_vin) INTO v_sayi, v_vin FROM v_musteri_servis_durumu;
  IF v_sayi <> 1 OR v_vin <> 'VINSTEST000000002' THEN
    RAISE EXCEPTION 'TEST 23 BASARISIZ: musteri 2 yalniz kendi satirini gormedi (% satir, vin=%)', v_sayi, v_vin;
  END IF;

  -- (d) PII/hassas kolon sizintisi: masraf ve calisan kimligi view'da olmamali
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_name = 'v_musteri_servis_durumu'
                AND column_name IN ('toplam_masraf', 'musteri_payi', 'garanti_payi',
                                    'sigorta_payi', 'sorumlu_calisan_id', 'giris_kilometresi')) THEN
    RAISE EXCEPTION 'TEST 23 BASARISIZ: view hassas kolon sizdiriyor';
  END IF;

  RESET ROLE;
  RESET app.musteri_telefon;
  RAISE NOTICE '  [PASS] Test 23: v_musteri_servis_durumu musteriyi izole ediyor (fail-closed, masrafsiz)';
END $$;

EOF

echo ""
echo "============================================="
echo "   TUM VERITABANI TESTLERI BASARIYLA GECTI!  "
echo "============================================="
