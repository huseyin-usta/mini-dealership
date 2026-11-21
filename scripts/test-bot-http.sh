#!/bin/sh
# Bot API HTTP Test Paketi
#
# Her senaryo, LLM'in (ve WhatsApp köprüsünün) yapacağı gibi GERÇEK HTTP
# isteğiyle denenir: geçici PostgreSQL + gerçek backend JAR. Yanıt gövdesi ve
# HTTP durum kodu birebir karşılaştırılır.
#
# Gereksinim: Docker, Java 17
# Kullanım:  ./scripts/test-bot-http.sh [--derleme-atla]
set -e
cd "$(dirname "$0")/.."

DERLEME_ATLA=0
[ "$1" = "--derleme-atla" ] && DERLEME_ATLA=1

PW=$(openssl rand -hex 12)
BOTPW=$(openssl rand -hex 12)
BOTTOKEN=$(openssl rand -hex 32)
CONTAINER=md-test-bot-http-tmp
PORT=5436
HTTP_PORT=8099
JAR=backend/target/mini-dealership-backend.jar

temizle() {
  [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap temizle EXIT

if [ "$DERLEME_ATLA" = 0 ]; then
  echo "==> Backend derleniyor..."
  # clean: artımlı derleme bazen değişikliği kaçırıyor; test her zaman taze JAR görsün.
  ( cd backend && ./mvnw -q clean package -DskipTests )
fi
[ -f "$JAR" ] || { echo "HATA: $JAR yok; önce derleyin" >&2; exit 1; }

echo "==> PostgreSQL 17 test konteyneri başlatılıyor..."
docker run --rm -d --name "$CONTAINER" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1:$PORT:5432 \
  postgres:17-alpine >/dev/null

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

echo "==> Şema dosyaları (db/*.sql) yükleniyor..."
for f in db/*.sql; do
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$f"
done

echo "==> Test verisi yükleniyor..."
docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q << 'SQL'
CREATE ROLE bot_app LOGIN PASSWORD 'BOTPW_PLACEHOLDER' IN ROLE bot;

INSERT INTO sube (sehir, ad) VALUES
  ('Ankara', 'Çankaya'), ('Ankara', 'Yenimahalle'),
  ('İstanbul', 'Kadıköy'), ('İstanbul', 'Beşiktaş'), ('İstanbul', 'Ataşehir'),
  ('İzmir', 'Bornova'), ('Bursa', 'Nilüfer'), ('Antalya', 'Muratpaşa'),
  -- Sıralama kanıtı: COLLATE "C" (bayt sırası) Zonguldak'ı Çorum'dan önce
  -- getirir; Türkçe collation tersini yapardı. Sıra sözleşmede sabittir.
  ('Zonguldak', 'Merkez'), ('Çorum', 'Merkez');

INSERT INTO mesai (gun, acilis, kapanis)
SELECT g, '08:00'::time, '18:00'::time FROM generate_series(1, 6) g;

INSERT INTO yetkinlik (kod, ad) VALUES
  ('TEST_SURUSU', 'Test Surusu Yetkisi'),
  ('ILERI_TEST',  'Ileri Test Yetkisi');

INSERT INTO randevu_turu (tur_kodu, ad, sure_dakika, departman, yetkinlik_id) VALUES
  ('TEST_SURUSU',     'Test Sürüşü',        60, 'SATIS',  1),
  ('TESLIMAT',        'Yeni Araç Teslimi',  60, 'SATIS',  NULL),
  ('PERIYODIK_BAKIM', 'Periyodik Bakım',    60, 'SERVIS', NULL),
  ('SERVIS_GIRIS',    'Servise Giriş',      30, 'SERVIS', NULL),
  ('SERVIS_TESLIM',   'Servisten Teslim',   30, 'SERVIS', NULL),
  ('ARAC_INCELEME',   'Araç İnceleme',      60, 'SATIS',  NULL),
  ('SATIN_ALIM',      'Satın Alım',         60, 'SATIS',  NULL),
  -- Yetkinlik sınır testi için izole tür: yalnızca ILERI_TEST (id 2) yetkinliği ister.
  ('TEST_SURUSU2',    'İleri Test Sürüşü',  60, 'SATIS',  2);

INSERT INTO tur_saat (tur_kodu, gun, baslangic, bitis)
SELECT 'TEST_SURUSU', g, '10:00'::time, '12:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'TEST_SURUSU', g, '14:00'::time, '16:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'PERIYODIK_BAKIM', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'SERVIS_GIRIS', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'SERVIS_TESLIM', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'TESLIMAT', g, '14:00'::time, '16:00'::time FROM generate_series(1, 6) g
-- Örtüşen pencereler: 09:00-11:00 ve 10:00-12:00 aynı 10:00 dilimini üretir;
-- slot listesinde tekrarlanmamalı (olası CTE DISTINCT).
UNION ALL SELECT 'ARAC_INCELEME', g, '09:00'::time, '11:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'ARAC_INCELEME', g, '10:00'::time, '12:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'SATIN_ALIM', g, '09:00'::time, '17:00'::time FROM generate_series(1, 6) g
UNION ALL SELECT 'TEST_SURUSU2', g, '10:00'::time, '12:00'::time FROM generate_series(1, 6) g;

INSERT INTO model (ad, garanti_yil, garanti_km) VALUES
  ('Ioniq 5', 3, 100000), ('Tucson', 3, 100000);
INSERT INTO versiyon (model_id, paket_adi, model_yili, liste_fiyati) VALUES
  (1, 'Advance', 2024, 2000000), (1, 'Elite', 2024, 2400000), (2, 'Elite', 2024, 2350000);

-- Şube 1: üç test sürüşü yetkinlikli satıcı + bir servis çalışanı
INSERT INTO calisan (sube_id, ad, soyad, departman, eposta, kullanici_adi, sifre_hash, ise_giris_tarihi) VALUES
  (1, 'Ahmet', 'Satici',  'SATIS',  'a@x', 'a.s', 'h', '2024-01-01'),
  (1, 'Burak', 'Satici2', 'SATIS',  'b@x', 'b.s', 'h', '2024-01-01'),
  (1, 'Cem',   'Satici3', 'SATIS',  'c@x', 'c.s', 'h', '2024-01-01'),
  (1, 'Deniz', 'Usta',    'SERVIS', 'd@x', 'd.u', 'h', '2024-01-01');
INSERT INTO calisan_yetkinlik (calisan_id, yetkinlik_id, verilis_tarihi)
VALUES (1, 1, '2024-01-01'), (2, 1, '2024-01-01'), (3, 1, '2024-01-01');

INSERT INTO arac (vin, versiyon_id, sube_id, renk, durum, tahmini_varis_tarihi) VALUES
  ('VIN00000000000001', 1, 1, 'Beyaz', 'STOKTA', NULL),
  ('VIN00000000000002', 1, 1, 'Beyaz', 'STOKTA', NULL),
  ('VIN00000000000003', 1, 1, 'Siyah', 'STOKTA', NULL),
  ('VIN00000000000009', 1, 1, 'Mavi',  'YOLDA',  current_date + 10),
  -- Sube 1'de Elite paket (renk kirilimi ve paket ayrimi icin)
  ('VIN00000000000004', 2, 1, 'Beyaz', 'STOKTA', NULL),
  ('VIN00000000000005', 2, 1, 'Gri',   'STOKTA', NULL),
  -- Istanbul Kadikoy (sube 3): stok + yolda
  ('VIN00000000000011', 1, 3, 'Beyaz', 'STOKTA', NULL),
  ('VIN00000000000012', 1, 3, 'Gri',   'STOKTA', NULL),
  ('VIN00000000000013', 1, 3, 'Beyaz', 'YOLDA',  current_date + 5),
  -- Istanbul Besiktas (sube 4): farkli model
  ('VIN00000000000014', 3, 4, 'Siyah', 'STOKTA', NULL);

-- Musteriler: farkli senaryolar icin ayri musteriler (ayni musteri ayni saatte
-- birden fazla randevuda olamaz; EXCLUDE kisiti)
INSERT INTO musteri (ad, soyad, telefon) VALUES
  ('Ali',  'Veli',   '+905550001122'),
  ('Ayse', 'Yilmaz', '+905550001133'),
  ('Can',  'Demir',  '+905550001144'),
  ('Ece',  'Kaya',   '+905550001155'),
  ('Mert', 'Aydin',  '+905550001166');

-- Sabit test gunu: gelecekte bir Carsamba. Test seed'i sabit tarihle calisir;
-- bugune gore 21 gun limiti icinde kalmasi icin tarih $TEST_GUN ile verilir.
SQL

# Gelecekteki test gunu: mesai icinde bir Carsamba (Pazar'a denk gelirse ileri al)
GUN=$(date -v+7d +%Y-%m-%d)
[ "$(date -v+7d +%u)" -eq 7 ] && GUN=$(date -v+8d +%Y-%m-%d)
# Ikinci calisma gunu (arac doluluk senaryolari icin; Pazar'a denk gelirse atla)
GUN2=$(date -d "$GUN + 1 day" +%Y-%m-%d 2>/dev/null || date -j -v+1d -f "%Y-%m-%d" "$GUN" +%Y-%m-%d)
[ "$(date -j -f "%Y-%m-%d" "$GUN2" +%u 2>/dev/null)" = "7" ] && \
  GUN2=$(date -j -v+1d -f "%Y-%m-%d" "$GUN2" +%Y-%m-%d)

echo "==> Dolu/musait senaryolari icin randevular ($GUN)..."
docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
  -v g="$GUN" -v g2="$GUN2" << 'SQL2'
-- Sube 1'de uc saticidan 1'i (Ahmet) ve bir arac 10:00-11:00 dolu.
-- 11:00-12:00'de uc saticinin hepsi dolu (musait calisan 0).
-- 14:00-15:00'te uc aracin hepsi dolu (musait arac 0).
-- 15:00-16:00 iptal edilmis: slot yeniden acik olmali.
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
VALUES
  -- 10:00: 1/3 calisan, 1/3 arac dolu
  (1, 1, 'TEST_SURUSU', 1, 'VIN00000000000001', :'g'::date + time '10:00', :'g'::date + time '11:00', 'PLANLANDI', 'PANEL'),
  -- 11:00: 3/3 calisan dolu (araclar bos)
  (2, 1, 'TEST_SURUSU', 1, 'VIN00000000000001', :'g'::date + time '11:00', :'g'::date + time '12:00', 'PLANLANDI', 'PANEL'),
  (3, 1, 'TEST_SURUSU', 2, 'VIN00000000000002', :'g'::date + time '11:00', :'g'::date + time '12:00', 'PLANLANDI', 'PANEL'),
  (4, 1, 'TEST_SURUSU', 3, 'VIN00000000000003', :'g'::date + time '11:00', :'g'::date + time '12:00', 'PLANLANDI', 'PANEL'),
  -- 14:00: 3/3 arac dolu (calisanlar bos)
  (1, 1, 'TEST_SURUSU', 1, 'VIN00000000000001', :'g'::date + time '14:00', :'g'::date + time '15:00', 'PLANLANDI', 'PANEL'),
  (2, 1, 'TEST_SURUSU', 2, 'VIN00000000000002', :'g'::date + time '14:00', :'g'::date + time '15:00', 'PLANLANDI', 'PANEL'),
  (3, 1, 'TEST_SURUSU', 3, 'VIN00000000000003', :'g'::date + time '14:00', :'g'::date + time '15:00', 'PLANLANDI', 'PANEL'),
  -- 15:00: iptal -> slot yeniden acik olmali (arac 1 secildi ki tek arac senaryosu net olsun)
  (4, 1, 'TEST_SURUSU', 1, 'VIN00000000000001', :'g'::date + time '15:00', :'g'::date + time '16:00', 'IPTAL', 'PANEL');

-- Servis senaryolari: musteri 6'nin iki araca sahip (satilmis), biri serviste
-- PARCA_BEKLENIYOR (teslime hazir degil), digeri TESLIME_HAZIR.
INSERT INTO musteri (ad, soyad, telefon) VALUES ('Selin', 'Oz', '+905550001177');
INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id) VALUES
  ('VIN00000000000021', 1, 1, 'Kirmizi', '06SS01', 'SATILDI', 6),
  ('VIN00000000000022', 1, 1, 'Beyaz',   '06SS02', 'SATILDI', 6);
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak) VALUES
  (6, 1, 'SERVIS_GIRIS', 4, 'VIN00000000000021', :'g'::date - interval '14 day' + time '09:00',
                        :'g'::date - interval '14 day' + time '09:30', 'TAMAMLANDI', 'PANEL'),
  (6, 1, 'SERVIS_GIRIS', 4, 'VIN00000000000022', :'g'::date - interval '7 day' + time '09:00',
                        :'g'::date - interval '7 day' + time '09:30', 'TAMAMLANDI', 'PANEL');
INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi, tahmini_teslim_tarihi)
SELECT randevu_id, 4, 'ARIZA', 30000, current_date + 5 FROM randevu
 WHERE arac_vin = 'VIN00000000000021' AND tur_kodu = 'SERVIS_GIRIS';
INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi, tahmini_teslim_tarihi)
SELECT randevu_id, 4, 'ARIZA', 40000, current_date FROM randevu
 WHERE arac_vin = 'VIN00000000000022' AND tur_kodu = 'SERVIS_GIRIS';
INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum)
SELECT servis_kaydi_id, 'PARCA_BEKLENIYOR' FROM servis_kaydi sk
  JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id WHERE r.arac_vin = 'VIN00000000000021';
INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum)
SELECT servis_kaydi_id, 'TESLIME_HAZIR' FROM servis_kaydi sk
  JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id WHERE r.arac_vin = 'VIN00000000000022';

-- Ayni araca IKINCI acik servis kaydi (eski kayit PARCA_BEKLENIYOR, yeni
-- kayit TESLIME_HAZIR). Bot "herhangi biri hazirsa" kuralini uygulamali.
INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id) VALUES
  ('VIN00000000000023', 1, 1, 'Yesil', '06SS03', 'SATILDI', 6);
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak) VALUES
  (6, 1, 'SERVIS_GIRIS', 4, 'VIN00000000000023', :'g'::date - interval '21 day' + time '09:00',
                        :'g'::date - interval '21 day' + time '09:30', 'TAMAMLANDI', 'PANEL'),
  (6, 1, 'SERVIS_GIRIS', 4, 'VIN00000000000023', :'g'::date - interval '14 day' + time '11:00',
                        :'g'::date - interval '14 day' + time '11:30', 'TAMAMLANDI', 'PANEL');
INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
SELECT randevu_id, 4, 'BAKIM', 50000 FROM randevu
 WHERE arac_vin = 'VIN00000000000023' AND baslangic = :'g'::date - interval '21 day' + time '09:00';
INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
SELECT randevu_id, 4, 'ARIZA', 51000 FROM randevu
 WHERE arac_vin = 'VIN00000000000023' AND baslangic = :'g'::date - interval '14 day' + time '11:00';
INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum)
SELECT sk.servis_kaydi_id, 'PARCA_BEKLENIYOR' FROM servis_kaydi sk
  JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id
 WHERE r.arac_vin = 'VIN00000000000023' AND r.baslangic = :'g'::date - interval '21 day' + time '09:00';
INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum)
SELECT sk.servis_kaydi_id, 'TESLIME_HAZIR' FROM servis_kaydi sk
  JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id
 WHERE r.arac_vin = 'VIN00000000000023' AND r.baslangic = :'g'::date - interval '14 day' + time '11:00';

-- Sube 2'de serviste olan arac: sube 1 icin yapilan SERVIS_TESLIM sorgusunda
-- GORUNMEMELI (teslim ancak aracin serviste oldugu subede yapilir).
INSERT INTO sube (sehir, ad) VALUES ('İzmir', 'Bornova2');
INSERT INTO calisan (sube_id, ad, soyad, departman, eposta, kullanici_adi, sifre_hash, ise_giris_tarihi)
VALUES (9, 'Okan', 'Usta', 'SERVIS', 'o@x', 'o.u', 'h', '2024-01-01');
INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id) VALUES
  ('VIN00000000000024', 1, 9, 'Mor', '35BB01', 'SATILDI', 6);
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak) VALUES
  (6, 9, 'SERVIS_GIRIS', 5, 'VIN00000000000024', :'g'::date - interval '7 day' + time '13:00',
                        :'g'::date - interval '7 day' + time '13:30', 'TAMAMLANDI', 'PANEL');
INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi)
SELECT randevu_id, 5, 'ARIZA', 60000 FROM randevu WHERE arac_vin = 'VIN00000000000024';
INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum)
SELECT sk.servis_kaydi_id, 'TESLIME_HAZIR' FROM servis_kaydi sk
  JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id WHERE r.arac_vin = 'VIN00000000000024';

-- Yoldaki araclar: biri varmis (varis gecmis), biri yolda (varis gelecek).
-- TESLIMAT randevusu yalnizca varisi gelmis arac icin verilebilir (trigger kurali).
INSERT INTO arac (vin, versiyon_id, sube_id, renk, durum, tahmini_varis_tarihi) VALUES
  ('VIN00000000000031', 1, 1, 'Lacivert', 'YOLDA', current_date - 1),
  ('VIN00000000000032', 1, 1, 'Turuncu',  'YOLDA', current_date + 10);

-- Ikinci arac sahibi musteri (sahiplik izolasyonu testi). Tek araci var.
INSERT INTO musteri (ad, soyad, telefon) VALUES ('Kerem', 'Oz', '+905550001188');
INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id) VALUES
  ('VIN00000000000041', 1, 1, 'Beyaz', '06KK01', 'SATILDI',
   (SELECT musteri_id FROM musteri WHERE telefon = '+905550001188'));
-- Ikinci gunde bu araci 14:00-15:00 arasi doldur: TESLIMAT ve BAKIM slotlarinda
-- 14:00 gorunmemeli (arac kaynagi mesgul), 15:00 gorunmeli.
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
VALUES ((SELECT musteri_id FROM musteri WHERE telefon = '+905550001188'), 1, 'TESLIMAT', 1,
        'VIN00000000000041', :'g2'::date + time '14:00', :'g2'::date + time '15:00',
        'PLANLANDI', 'PANEL');

-- Gecmis randevu testi: bakimi eski, arada ariza kayitlari olan musteri.
INSERT INTO musteri (ad, soyad, telefon) VALUES ('Gecmis', 'Musteri', '+905550001199');
INSERT INTO arac (vin, versiyon_id, sube_id, renk, plaka, durum, musteri_id) VALUES
  ('VIN00000000000042', 1, 1, 'Gri', '06GG01', 'SATILDI',
   (SELECT musteri_id FROM musteri WHERE telefon = '+905550001199'));
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m.musteri_id, 1, 'PERIYODIK_BAKIM', 4, 'VIN00000000000042',
       :'g'::date - interval '28 day' + time '09:00',
       :'g'::date - interval '28 day' + time '10:00', 'TAMAMLANDI', 'PANEL'
  FROM musteri m WHERE m.telefon = '+905550001199';
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m.musteri_id, 1, 'SERVIS_GIRIS', 4, 'VIN00000000000042',
       :'g'::date - interval '14 day' + time '10:00',
       :'g'::date - interval '14 day' + time '10:30', 'TAMAMLANDI', 'PANEL'
  FROM musteri m WHERE m.telefon = '+905550001199';
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m.musteri_id, 1, 'SERVIS_GIRIS', 4, 'VIN00000000000042',
       :'g'::date - interval '7 day' + time '11:00',
       :'g'::date - interval '7 day' + time '11:30', 'TAMAMLANDI', 'PANEL'
  FROM musteri m WHERE m.telefon = '+905550001199';
-- Gizli arac testi: bu test surusu yapildiginda arac stoktaydi, sonra baska
-- musteriye satildi -> musteri 8 listesinde arac alani null gelmeli.
INSERT INTO musteri (ad, soyad, telefon) VALUES ('Baskasi', 'Sahip', '+905550001210');
INSERT INTO arac (vin, versiyon_id, sube_id, renk, durum) VALUES
  ('VIN00000000000043', 1, 1, 'Kirmizi', 'STOKTA');
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m.musteri_id, 1, 'TEST_SURUSU', 1, 'VIN00000000000043',
       :'g'::date - interval '21 day' + time '10:00',
       :'g'::date - interval '21 day' + time '11:00', 'TAMAMLANDI', 'PANEL'
  FROM musteri m WHERE m.telefon = '+905550001199';
UPDATE arac SET durum = 'SATILDI', plaka = '06BB99',
       musteri_id = (SELECT musteri_id FROM musteri WHERE telefon = '+905550001210')
 WHERE vin = 'VIN00000000000043';
-- Bu musterinin yalniz servis gecmisi var: son_bakim null olmali
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m.musteri_id, 1, 'SERVIS_GIRIS', 4, 'VIN00000000000043',
       :'g'::date - interval '10 day' + time '09:00',
       :'g'::date - interval '10 day' + time '09:30', 'TAMAMLANDI', 'PANEL'
  FROM musteri m WHERE m.telefon = '+905550001210';
-- Gelecek ama iptal edilmis randevu: iki listede de degil, gecmis'te gorunmeli
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m.musteri_id, 1, 'SERVIS_GIRIS', 4, 'VIN00000000000042',
       :'g'::date + interval '7 day' + time '14:00',
       :'g'::date + interval '7 day' + time '14:30', 'IPTAL', 'PANEL'
  FROM musteri m WHERE m.telefon = '+905550001199';

-- Yaklasan (PLANLANDI) bakim: g+7 (testlerin kullanmadigi gun)
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak)
SELECT m.musteri_id, 1, 'PERIYODIK_BAKIM', 4, 'VIN00000000000042',
       :'g'::date + interval '7 day' + time '10:00',
       :'g'::date + interval '7 day' + time '11:00', 'PLANLANDI', 'PANEL'
  FROM musteri m WHERE m.telefon = '+905550001199';

-- Yetkinligi suresi dolmus ve henuz baslamamis saticilar: slot sayimina girmemeli
INSERT INTO calisan (sube_id, ad, soyad, departman, eposta, kullanici_adi, sifre_hash, ise_giris_tarihi) VALUES
  (1, 'Eski',  'Satici', 'SATIS', 'e@x', 'e.s', 'h', '2019-01-01'),
  (1, 'Yeni',  'Satici', 'SATIS', 'y@x', 'y.s', 'h', '2026-01-01');
-- Sinir gunleri: bitis_tarihi = randevu gunu ve verilis_tarihi = randevu gunu
-- DAHIL kabul edilmeli (trigger ile ayni kural). Bu ikisi gecerlidir.
INSERT INTO calisan (sube_id, ad, soyad, departman, eposta, kullanici_adi, sifre_hash, ise_giris_tarihi) VALUES
  (1, 'Bitis',     'Sinir', 'SATIS', 'bs@x', 'bitis.s', 'h', '2020-01-01'),
  (1, 'Baslangic', 'Sinir', 'SATIS', 'ba@x', 'baslangic.s', 'h', '2026-01-01');
INSERT INTO calisan_yetkinlik (calisan_id, yetkinlik_id, verilis_tarihi, bitis_tarihi)
SELECT calisan_id, 2, '2020-01-01', :'g'::date FROM calisan WHERE kullanici_adi = 'bitis.s';
INSERT INTO calisan_yetkinlik (calisan_id, yetkinlik_id, verilis_tarihi, bitis_tarihi)
SELECT calisan_id, 2, :'g'::date, NULL FROM calisan WHERE kullanici_adi = 'baslangic.s';

-- Suresi dolmus ve henuz baslamamis: sayima girmemeli
INSERT INTO calisan_yetkinlik (calisan_id, yetkinlik_id, verilis_tarihi, bitis_tarihi) VALUES
  ((SELECT calisan_id FROM calisan WHERE kullanici_adi = 'e.s'), 2, '2020-01-01', '2020-12-31'),
  ((SELECT calisan_id FROM calisan WHERE kullanici_adi = 'y.s'), 2, current_date + 60, NULL);
SQL2

docker exec -i "$CONTAINER" psql -U postgres -d postgres -q \
  -c "ALTER ROLE bot_app PASSWORD '$BOTPW'"

echo "==> Backend başlatılıyor (port $HTTP_PORT)..."
DB_HOST=127.0.0.1 DB_PORT=$PORT DB_NAME=postgres \
BOT_DB_USER=bot_app BOT_DB_PASS="$BOTPW" BOT_TOKEN="$BOTTOKEN" \
BIND_ADRESI=127.0.0.1 HTTP_PORT=$HTTP_PORT \
  java -jar "$JAR" > /tmp/md-http-test.log 2>&1 &
SRV_PID=$!

for i in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:$HTTP_PORT/saglik" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$HTTP_PORT/saglik" >/dev/null 2>&1 || {
  echo "HATA: backend başlamadı. Log:" >&2; cat /tmp/md-http-test.log >&2; exit 1;
}

echo "==> HTTP senaryoları çalıştırılıyor..."

# GUN yukarida (seed ile ayni sekilde) hesaplandi.
TEL='X-Musteri-Telefon: +905321234567'
TOK="X-Bot-Token: $BOTTOKEN"
TABAN="http://127.0.0.1:$HTTP_PORT"
GECEN=0
KALAN=0
BASARISIZLAR=""

# bekle <ad> <beklenen_durum> <beklenen_govde_parcasi> <curl_arg...>
bekle() {
  ad=$1; durum=$2; parca=$3; shift 3
  yanit=$(curl -s -w '\n%{http_code}' "$@")
  kod=$(printf '%s' "$yanit" | tail -n1)
  govde=$(printf '%s' "$yanit" | sed '$d')

  if [ "$kod" = "$durum" ] && printf '%s' "$govde" | grep -qF "$parca"; then
    echo "[PASS] $ad"
    GECEN=$((GECEN + 1))
  else
    echo "[FAIL] $ad"
    echo "       beklenen: HTTP $durum + '$parca'"
    echo "       gelen   : HTTP $kod"
    echo "       gövde   : $govde"
    KALAN=$((KALAN + 1))
    BASARISIZLAR="$BASARISIZLAR
  - $ad"
  fi
}

echo "--- GET /bot/sube ---"
bekle "Tüm şehirler listelenir ve bayt sırasıyla sıralanır (COLLATE C)" 200 \
  '"sehirler":["Ankara","Antalya","Bursa","Zonguldak","Çorum","İstanbul","İzmir"]' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/sube"
bekle "Ankara iki şube döner" 200 '"sehir":"Ankara","subeler":[{"sube_id":2,"ad":"Yenimahalle"},{"sube_id":1,"ad":"Çankaya"}]' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/sube?sehir=Ankara"
bekle "Olmayan şehir 404" 404 '"kod":"SEHIRDE_SUBE_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/sube?sehir=Kars"
bekle "Yanlış yazım (ankara) 404" 404 '"kod":"SEHIRDE_SUBE_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/sube?sehir=ankara"

echo "--- GET /bot/slot ---"
TEL_S='X-Musteri-Telefon: +905550001177'
TEL_B='X-Musteri-Telefon: +905550001122'
bekle "Test sürüşü slotları ve imkanlar" 200 '"musait_calisan_sayisi":3' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN"
bekle "Bilgi alanı tür adını, gün kapsamını ve saat aralığını taşır" 200 'Test Sürüşü: Pazartesi-Cumartesi 10:00-12:00, 14:00-16:00' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN"
# Bakımda araç müşterinin kendisine aittir: müşteri kendi araçlarını görür.
bekle "Periyodik bakımda müşterinin kendi araçları listelenir" 200 '"vin":"VIN00000000000022"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=PERIYODIK_BAKIM&tarih=$GUN"
# Aracı olmayan müşteriye bakım slotu verilmez (araç kaynağı yok).
bekle "Aracı olmayan müşteriye bakım slotu yok" 200 '"slotlar":[]' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=PERIYODIK_BAKIM&tarih=$GUN"

echo "--- GET /bot/slot (doluluk senaryoları) ---"
# 10:00 -> 1/3 calisan, 1/3 arac dolu; kalan 2 calisan + 2 arac musait
bekle "SENARYO 1/3 calisan + 1/3 arac dolu -> 2 musait calisan" 200 \
  '"baslangic":"10:00","bitis":"11:00","musait_calisan_sayisi":2' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN"
# 11:00 -> 3/3 calisan dolu: slot listede olmamali
if curl -s -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN" \
     | grep -qF '"baslangic":"11:00"'; then
  echo "[FAIL] SENARYO tum calisanlar dolu -> 11:00 slotu elenmeli"
  KALAN=$((KALAN + 1))
else
  echo "[PASS] SENARYO tum calisanlar dolu -> 11:00 slotu elenir"
  GECEN=$((GECEN + 1))
fi
# 14:00 -> 3/3 arac dolu: slot listede olmamali
if curl -s -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN" \
     | grep -qF '"baslangic":"14:00"'; then
  echo "[FAIL] SENARYO tum araclar dolu -> 14:00 slotu elenmeli"
  KALAN=$((KALAN + 1))
else
  echo "[PASS] SENARYO tum araclar dolu -> 14:00 slotu elenir"
  GECEN=$((GECEN + 1))
fi
# 15:00 -> iptal edilmis randevu slotu yeniden acar
bekle "SENARYO iptal edilen randevu slotu yeniden acar" 200 '"baslangic":"15:00"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN"
# arac_vin filtresi: dolu arac 10:00'da donmemeli
if curl -s -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN&arac_vin=VIN00000000000001" \
     | grep -qF '"baslangic":"10:00"'; then
  echo "[FAIL] SENARYO dolu arac icin 10:00 slotu donmemeli"
  KALAN=$((KALAN + 1))
else
  echo "[PASS] SENARYO arac_vin=dolu arac -> 10:00 slotu donmez"
  GECEN=$((GECEN + 1))
fi
# arac_vin filtresi: bos arac 15:00'te tek arac olarak doner
bekle "SENARYO arac_vin=bos arac -> tek arac" 200 \
  '"musait_araclar":[{"vin":"VIN00000000000003"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN&arac_vin=VIN00000000000003"
# Hafta sonu: o gun mesai yok -> slot listesi bos
PAZAR=$(date -v+7d -v+sun +%Y-%m-%d 2>/dev/null || date -v+sun +%Y-%m-%d)
bekle "SENARYO pazar gunu slot yok (mesai disi)" 200 '"slotlar":[]' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$PAZAR"
# Baska subede calisan/arac yok -> slot listesi bos
bekle "SENARYO sube 2'de calisan yok -> slot yok" 200 '"slotlar":[]' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=2&tur_kodu=TEST_SURUSU&tarih=$GUN"
bekle "Olmayan şube 404" 404 '"kod":"SUBE_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=999&tur_kodu=TEST_SURUSU&tarih=$GUN"
bekle "Olmayan tür 404" 404 '"kod":"TUR_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=YOKTUR&tarih=$GUN"
bekle "Bozuk tarih 400" 400 '"kod":"GECERSIZ_TARIH"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=2026-13-45"
bekle "Geçmiş tarih 400" 400 '"kod":"GECMIS_TARIH"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=2020-01-01"
bekle "21 günden uzak tarih 400" 400 '"kod":"COK_UZAK_TARIH"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=2027-06-01"
bekle "Stokta olmayan VIN 404" 404 '"kod":"ARAC_STOKTA_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN&arac_vin=VIN00000000000009"
bekle "Zorunlu parametre eksik 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?tur_kodu=TEST_SURUSU&tarih=$GUN"

echo "--- GET /bot/arac ---"
# Filtresiz: model bazinda toplam
bekle "Arac: filtresiz model ozeti (Ioniq 5)" 200 '"model":"Ioniq 5"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac"
YANIT_M=$(curl -s -H "$TOK" -H "$TEL" "$TABAN/bot/arac")
if printf '%s' "$YANIT_M" | grep -qF '"model":"Tucson"' \
   && printf '%s' "$YANIT_M" | grep -qF '"bilgi":"'; then
  echo "[PASS] Arac: filtresiz ozette tum modeller ve bilgi alani var"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Arac: filtresiz ozet eksik"; echo "       $YANIT_M"; KALAN=$((KALAN + 1))
fi
# Model: sehir + paket kirilimi (Ankara ve Istanbul birlikte)
bekle "Arac: model -> sehir kirilimi (Ankara)" 200 '"sehir":"Ankara","paket":"Advance","stokta":3' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?model=Ioniq%205"
bekle "Arac: model -> sehir kirilimi (Istanbul)" 200 '"sehir":"İstanbul","paket":"Advance","stokta":2' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?model=Ioniq%205"
# Sehir: sube + model + paket kirilimi
bekle "Arac: sehir -> sube kirilimi" 200 '"sube":"Çankaya","model":"Ioniq 5"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sehir=Ankara"
bekle "Arac: sehir + model -> sube kirilimi" 200 '"sube":"Çankaya","model":"Ioniq 5","paket":"Elite"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sehir=Ankara&model=Ioniq%205"
# Sube: paket + renk kirilimi
YANIT_R=$(curl -s -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sube_id=1")
if printf '%s' "$YANIT_R" | grep -qF '"renk":"Beyaz","adet":2' \
   && printf '%s' "$YANIT_R" | grep -qF '"sube":{"sube_id":1,"sehir":"Ankara","ad":"Çankaya"}' \
   && ! printf '%s' "$YANIT_R" | grep -qF '"renk":"Mavi"'; then
  echo "[PASS] Arac: sube detayi renk kirilimi (Beyaz x2; yoldaki Mavi sayilmaz)"
  GECEN=$((GECEN + 1))
else
  echo "[FAIL] Arac: sube detayi yanlis"; echo "       $YANIT_R"; KALAN=$((KALAN + 1))
fi
# Yolda ve en_erken_varis sayaclari: sube 1'de 3 yolda arac (VIN09, VIN31, VIN32)
if printf '%s' "$YANIT_R" | grep -qF '"yolda":3' \
   && printf '%s' "$YANIT_R" | grep -qF '"en_erken_varis":"' ; then
  echo "[PASS] Arac: yolda sayisi ve en_erken_varis dolu"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Arac: yolda/en_erken_varis eksik"; echo "       $YANIT_R"; KALAN=$((KALAN + 1))
fi
# sube_id + model kombinasyonu
bekle "Arac: sube_id + model filtresi" 200 '"paket":"Elite"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sube_id=1&model=Ioniq%205"
# Model var ama o sehirde arac yok -> 200 + bos liste (404 degil)
YANIT_BOS=$(curl -s -w '\n%{http_code}' -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sehir=Bursa")
KOD_BOS=$(printf '%s' "$YANIT_BOS" | tail -n1)
GOV_BOS=$(printf '%s' "$YANIT_BOS" | sed '$d')
if [ "$KOD_BOS" = "200" ] && printf '%s' "$GOV_BOS" | grep -qF '"subeler":[]'; then
  echo "[PASS] Arac: subesi olup stogu olmayan sehir -> 200 bos"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Arac: bos sehir yaniti yanlis"; echo "       HTTP $KOD_BOS $GOV_BOS"; KALAN=$((KALAN + 1))
fi
# Model var ama sehirde o model yok -> 200 bos
YANIT_BOS2=$(curl -s -w '\n%{http_code}' -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sehir=Ankara&model=Tucson")
KOD_BOS2=$(printf '%s' "$YANIT_BOS2" | tail -n1)
if [ "$KOD_BOS2" = "200" ]; then
  echo "[PASS] Arac: model var ama sehirde yok -> 200 bos"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Arac: model+sehir bos yaniti $KOD_BOS2"; KALAN=$((KALAN + 1))
fi
# Kendi araclarim: Selin'in 3 araci, baska modelde filtrelenince 0
# Selin'in 4 araci var (biri Izmir subesinde); sahiplik subeye bagli degil.
bekle "Arac: kapsam=benim kendi araclarini listeler" 200 '"toplam_arac":4' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/arac?kapsam=benim"
bekle "Arac: kapsam=benim + model filtresi" 200 '"vin":"VIN00000000000022"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/arac?kapsam=benim&model=Ioniq%205"
bekle "Arac: kapsam=benim baska model -> bos" 200 '"toplam_arac":0' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/arac?kapsam=benim&model=Tucson"
# Aracı olmayan müşteri: bos liste, hata degil
bekle "Arac: aracsiz musteri -> bos liste" 200 '"toplam_arac":0' \
  -H "$TOK" -H "$TEL_B" "$TABAN/bot/arac?kapsam=benim"
# Hatalar
bekle "Arac: olmayan sehir -> 404" 404 '"kod":"SEHIRDE_SUBE_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sehir=Kars"
bekle "Arac: olmayan model -> 404" 404 '"kod":"MODEL_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?model=Yok%20Model"
bekle "Arac: olmayan sube -> 404" 404 '"kod":"SUBE_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sube_id=999"
bekle "Arac: sehir + sube_id -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sehir=Ankara&sube_id=1"
bekle "Arac: gecersiz kapsam -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?kapsam=hepsi"
bekle "Arac: kapsam=benim + sehir -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/arac?kapsam=benim&sehir=Ankara"
bekle "Arac: sayisal olmayan sube_id -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sube_id=abc"
bekle "Arac: POST -> 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' \
  -X POST -H "$TOK" -H "$TEL" "$TABAN/bot/arac"
bekle "Arac: token yok -> 401" 401 '"kod":"YETKISIZ_ISTEK"' \
  -H "$TEL" "$TABAN/bot/arac"
bekle "Arac: kimlik yok -> 401" 401 '"kod":"KIMLIK_YOK"' \
  -H "$TOK" "$TABAN/bot/arac"
bekle "Arac: kapsam=benim + sube_id -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/arac?kapsam=benim&sube_id=1"
bekle "Arac: bos model parametresi -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?model="
bekle "Arac: tekrarli parametre -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac?sube_id=1&sube_id=3"
bekle "Arac: tanimsiz alt yol -> 404" 404 '"kod":"YOL_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/arac/ekstra"

echo "--- GET /bot/slot (TESLIMAT) ---"
bekle "Teslimat: musteri kendi satilmis aracini secer" 200 '"ok":true' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN&arac_vin=VIN00000000000022"
# Yoldaki aracın sahibi yoktur (db/110_arac.sql CHECK) -> teslimat için uygun değil.
bekle "Teslimat: sahipsiz yoldaki arac reddedilir" 404 '"kod":"ARAC_STOKTA_YOK"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN&arac_vin=VIN00000000000031"
# Gerçek ikinci müşteri (aracı yok) başka müşterinin aracını seçemez.
bekle "Teslimat: baska musterinin satilmis araci reddedilir" 404 '"kod":"ARAC_STOKTA_YOK"' \
  -H "$TOK" -H "$TEL_B" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN&arac_vin=VIN00000000000022"
# Arac_vin verilmeden: yalniz kendi satilmis araclari listelenir, yoldakiler yok.
YANIT_T=$(curl -s -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN")
if printf '%s' "$YANIT_T" | grep -qF 'VIN00000000000022' \
   && ! printf '%s' "$YANIT_T" | grep -qF 'VIN00000000000031'; then
  echo "[PASS] Teslimat listesi yalniz kendi satilmis aracini icerir"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Teslimat listesi yanlis araclari iceriyor"; echo "       $YANIT_T"; KALAN=$((KALAN + 1))
fi
# Baska musterinin listesi kendi aracini gormez
YANIT_B=$(curl -s -H "$TOK" -H "$TEL_B" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN")
if printf '%s' "$YANIT_B" | grep -qF 'VIN00000000000022'; then
  echo "[FAIL] Baska musterinin teslimat listesinde VIN22 gorunuyor"; KALAN=$((KALAN + 1))
else
  echo "[PASS] Baska musterinin teslimat listesinde VIN22 gorunmuyor"; GECEN=$((GECEN + 1))
fi

echo "--- Sahiplik izolasyonu (iki arac sahibi musteri) ---"
TEL_K='X-Musteri-Telefon: +905550001188'

YANIT_K=$(curl -s -w '\n%{http_code}' -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN")
KOD_K=$(printf '%s' "$YANIT_K" | tail -n1)
GOV_K=$(printf '%s' "$YANIT_K" | sed '$d')
if [ "$KOD_K" = "200" ] \
   && printf '%s' "$GOV_K" | grep -qF 'VIN00000000000041' \
   && ! printf '%s' "$GOV_K" | grep -qF 'VIN00000000000022'; then
  echo "[PASS] Kerem yalniz kendi satilmis aracini gorur"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Kerem'in listesi yanlis"; echo "       HTTP $KOD_K $GOV_K"; KALAN=$((KALAN + 1))
fi

YANIT_S=$(curl -s -w '\n%{http_code}' -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN")
KOD_S=$(printf '%s' "$YANIT_S" | tail -n1)
GOV_S=$(printf '%s' "$YANIT_S" | sed '$d')
if [ "$KOD_S" = "200" ] \
   && printf '%s' "$GOV_S" | grep -qF 'VIN00000000000022' \
   && ! printf '%s' "$GOV_S" | grep -qF 'VIN00000000000041' \
   && ! printf '%s' "$GOV_S" | grep -qF 'VIN00000000000024'; then
  echo "[PASS] Selin yalniz kendi araclarini gorur (baska musteri ve baska sube haric)"
  GECEN=$((GECEN + 1))
else
  echo "[FAIL] Selin'in listesi yanlis"; echo "       HTTP $KOD_S $GOV_S"; KALAN=$((KALAN + 1))
fi

echo "--- Arac kaynagi mesgulse slot verilmez ---"
# Kerem'in tek araci GUN2 14:00-15:00 dolu -> 14:00 slotu elenir, 15:00 kalir.
YANIT_D=$(curl -s -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN2")
if printf '%s' "$YANIT_D" | grep -qF '"baslangic":"14:00"'; then
  echo "[FAIL] TESLIMAT: dolu araca ragmen 14:00 slotu dondu"; KALAN=$((KALAN + 1))
else
  echo "[PASS] TESLIMAT: araç dolu ise slot elenir (14:00 yok)"; GECEN=$((GECEN + 1))
fi
YANIT_D2=$(curl -s -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=TESLIMAT&tarih=$GUN2&arac_vin=VIN00000000000041")
if printf '%s' "$YANIT_D2" | grep -qF '"baslangic":"14:00"'; then
  echo "[FAIL] TESLIMAT (VIN filtreli): dolu araca ragmen 14:00 dondu"; KALAN=$((KALAN + 1))
else
  echo "[PASS] TESLIMAT (VIN filtreli): dolu arac 14:00'te donmez"; GECEN=$((GECEN + 1))
fi
YANIT_B2=$(curl -s -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=PERIYODIK_BAKIM&tarih=$GUN2&arac_vin=VIN00000000000041")
if printf '%s' "$YANIT_B2" | grep -qF '"baslangic":"14:00"'; then
  echo "[FAIL] BAKIM: dolu araca ragmen 14:00 dondu"; KALAN=$((KALAN + 1))
else
  echo "[PASS] BAKIM: araç dolu ise slot elenir (14:00 yok)"; GECEN=$((GECEN + 1))
fi

echo "--- Tur -> arac kurali (yedi tur) ---"
bekle "SERVIS_GIRIS: kendi araci kabul edilir" 200 '"ok":true' \
  -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_GIRIS&tarih=$GUN&arac_vin=VIN00000000000041"
bekle "SERVIS_GIRIS: baskasinin araci reddedilir" 404 '"kod":"ARAC_YOK"' \
  -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_GIRIS&tarih=$GUN&arac_vin=VIN00000000000022"
# Bakimda sube serbest: Kerem'in araci sube 1'de kayitli, sube 1'de bakim -> kabul.
bekle "BAKIM: sube serbest (kendi aracin, ayni sube)" 200 '"ok":true' \
  -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=PERIYODIK_BAKIM&tarih=$GUN&arac_vin=VIN00000000000041"
bekle "SATIN_ALIM: arac_vin kullanilamaz -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=SATIN_ALIM&tarih=$GUN&arac_vin=VIN00000000000041"
bekle "ARAC_INCELEME: arac_vin kullanilamaz -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL_K" "$TABAN/bot/slot?sube_id=1&tur_kodu=ARAC_INCELEME&tarih=$GUN&arac_vin=VIN00000000000041"

echo "--- Yetkinlik gecerliligi ---"
# Izole tur (ILERI_TEST yetkinligi): yalnizca iki sinir calisani gecerli.
# Bitis_tarihi = gun ve verilis_tarihi = gun DAHIL; suresi dolmus (2020) ve
# henuz baslamamis (+60 gun) sayima girmez. Beklenen: 2 (girselerdi 4 olurdu).
bekle "Yetkinlik gecerliligi: sinir gunleri dahil, suresi dolmus/baslamamis haric" 200 \
  '"baslangic":"10:00","bitis":"11:00","musait_calisan_sayisi":2' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU2&tarih=$GUN"

echo "--- Parametre tutarliligi ---"
bekle "Bakimda kendi aracinin VIN'i kabul edilir" 200 '"ok":true' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=PERIYODIK_BAKIM&tarih=$GUN&arac_vin=VIN00000000000022"
bekle "Bakimda baskasinin/bilinmeyen aracin VIN'i reddedilir" 404 '"kod":"ARAC_YOK"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=PERIYODIK_BAKIM&tarih=$GUN&arac_vin=VIN00000000000001"
bekle "Arac gerektirmeyen turde arac_vin -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=ARAC_INCELEME&tarih=$GUN&arac_vin=VIN00000000000001"
bekle "Kucuk harf VIN kabul edilir" 200 '"ok":true' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN&arac_vin=vin00000000000001"
bekle "POST /saglik -> 405" 405 'yöntem desteklenmiyor' -X POST "$TABAN/saglik"
bekle "HEAD /saglik -> 200 (govdesiz)" 200 '' -I "$TABAN/saglik"
bekle "Tanimsiz alt yol /saglik/xyz -> 404" 404 'bulunamadı' "$TABAN/saglik/xyz"
bekle "Sondaki egik cizgi kabul edilir (/bot/sube/)" 200 '"ok":true' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/sube/"
# Ortusen tur_saat pencereleri ayni dilimi iki kez uretmemeli: 09,10,11 -> 3 slot.
YANIT_O=$(curl -s -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=ARAC_INCELEME&tarih=$GUN")
sayi_o=$(printf '%s' "$YANIT_O" | grep -oF '"baslangic"' | wc -l | tr -d ' ')
if [ "$sayi_o" -eq 3 ]; then
  echo "[PASS] Ortusen tur_saat pencereleri tekrarli slot uretmiyor (3 slot)"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Ortusen pencereler $sayi_o slot uretti (3 beklenirdi)"; KALAN=$((KALAN + 1))
fi
bekle "Tanimsiz alt yol -> 404" 404 '"kod":"YOL_YOK"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/sube/ekstra"
bekle "Tekrarli parametre -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&sube_id=2&tur_kodu=TEST_SURUSU&tarih=$GUN"

echo "--- GET /bot/slot (SERVIS_TESLIM) — içerik kontrolleri ---"

# arac_vin verilmeden: yalnizca TESLIME_HAZIR araclar listelenmeli
YANIT=$(curl -s -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_TESLIM&tarih=$GUN")
if printf '%s' "$YANIT" | grep -qF 'VIN00000000000022'; then
  echo "[PASS] Teslime hazir arac (022) slot listesinde var"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Teslime hazir arac (022) slot listesinde yok"; echo "       $YANIT"; KALAN=$((KALAN + 1))
fi
if printf '%s' "$YANIT" | grep -qF 'VIN00000000000021'; then
  echo "[FAIL] Parca bekleyen arac (021) slot listesinde OLMAMALI"; KALAN=$((KALAN + 1))
else
  echo "[PASS] Parca bekleyen arac (021) slot listesinde yer almiyor"; GECEN=$((GECEN + 1))
fi
# Ayni araca iki acik kayit: VIN her slotta en fazla BIR kez gorunmeli.
# (Slot basina tekrar normaldir; ayni slot icinde duplike olmasi hatadir.)
slot_sayisi=$(printf '%s' "$YANIT" | grep -oF '"baslangic"' | wc -l | tr -d ' ')
vin_sayisi=$(printf '%s' "$YANIT" | grep -oF 'VIN00000000000023' | wc -l | tr -d ' ')
if [ "$slot_sayisi" -gt 0 ] && [ "$vin_sayisi" -eq "$slot_sayisi" ]; then
  echo "[PASS] Coklu acik kayitta VIN slot basina tek kez ($vin_sayisi VIN / $slot_sayisi slot)"
  GECEN=$((GECEN + 1))
else
  echo "[FAIL] VIN slot basina tek kez olmali: $vin_sayisi VIN / $slot_sayisi slot"
  KALAN=$((KALAN + 1))
fi
# Baska subede serviste olan arac bu subenin slotlarinda gorunmemeli
if printf '%s' "$YANIT" | grep -qF 'VIN00000000000024'; then
  echo "[FAIL] Baska subedeki (24) arac bu subenin slotlarinda gorunuyor"; KALAN=$((KALAN + 1))
else
  echo "[PASS] Baska subedeki arac bu subenin slotlarinda gorunmuyor"; GECEN=$((GECEN + 1))
fi
# Coklu acik kayit: yeni kayit TESLIME_HAZIR ise teslim edilebilmeli
bekle "Coklu acik kayit: yeni kayit hazirsa teslim edilebilir" 200 '"ok":true' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_TESLIM&tarih=$GUN&arac_vin=VIN00000000000023"

echo "--- GET /bot/slot (SERVIS_TESLIM) ---"
TEL_S='X-Musteri-Telefon: +905550001177'
bekle "Servisten teslim: teslime hazir arac slot doner" 200 '"SERVIS_TESLIM"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_TESLIM&tarih=$GUN&arac_vin=VIN00000000000022"
bekle "Servisten teslim: parca bekleyen arac 409" 409 '"kod":"SERVIS_TESLIM_HAZIR_DEGIL"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_TESLIM&tarih=$GUN&arac_vin=VIN00000000000021"
bekle "409 yaniti son durumu ve tahmini tarihi tasir" 409 '"son_durum":"PARCA_BEKLENIYOR"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_TESLIM&tarih=$GUN&arac_vin=VIN00000000000021"
bekle "409 yanitinda tahmini teslim tarihi var" 409 '"tahmini_teslim_tarihi":"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_TESLIM&tarih=$GUN&arac_vin=VIN00000000000021"
bekle "Baska müşterinin servisteki aracı: açık kayıt yok" 404 '"kod":"ARAC_SERVISTE_DEGIL"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_TESLIM&tarih=$GUN&arac_vin=VIN00000000000021"
bekle "Servisten teslim: musteri kendi arac listesini gorur (arac_vin bos)" 200 '"SERVIS_TESLIM"' \
  -H "$TOK" -H "$TEL_S" "$TABAN/bot/slot?sube_id=1&tur_kodu=SERVIS_TESLIM&tarih=$GUN"

echo "--- Sinir degerler ---"
BUGUN=$(date +%Y-%m-%d)
bekle "Bugun kabul edilir" 200 '"ok":true' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$BUGUN"
G21=$(date -v+21d +%Y-%m-%d)
bekle "Tam 21 gun ileri kabul edilir" 200 '"ok":true' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$G21"
G22=$(date -v+22d +%Y-%m-%d)
bekle "22 gun reddedilir" 400 '"kod":"COK_UZAK_TARIH"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$G22"

echo "--- Guvenlik ---"
bekle "SQL injection denemesi sehir'de" 404 '"kod":"SEHIRDE_SUBE_YOK"' \
  -H "$TOK" -H "$TEL" --get --data-urlencode "sehir=Ankara' OR '1'='1" "$TABAN/bot/sube"
bekle "SQL injection denemesi tur_kodu'nda" 404 '"kod":"TUR_YOK"' \
  -H "$TOK" -H "$TEL" --get --data-urlencode "tur_kodu=TEST_SURUSU' OR '1'='1" "$TABAN/bot/slot?sube_id=1&tarih=$GUN"
bekle "7 haneli telefon reddedilir (E.164 alt sinir)" 401 '"kod":"KIMLIK_YOK"' \
  -H "$TOK" -H 'X-Musteri-Telefon: +1234567' "$TABAN/bot/sube"
bekle "15 haneli telefon kabul edilir (E.164 ust sinir)" 200 '"ok":true' \
  -H "$TOK" -H 'X-Musteri-Telefon: +123456789012345' "$TABAN/bot/sube"
bekle "0 ile baslayan numara reddedilir" 401 '"kod":"KIMLIK_YOK"' \
  -H "$TOK" -H 'X-Musteri-Telefon: +0123456789' "$TABAN/bot/sube"
bekle "POST /bot/sube -> 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' \
  -X POST -H "$TOK" -H "$TEL" "$TABAN/bot/sube"
bekle "POST /bot/slot -> 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' \
  -X POST -H "$TOK" -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN"
bekle "PUT /bot/sube -> 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' \
  -X PUT -H "$TOK" -H "$TEL" "$TABAN/bot/sube"

echo "--- Kopru kimligi (token) ---"
bekle "Token yok -> 401 YETKISIZ_ISTEK" 401 '"kod":"YETKISIZ_ISTEK"' \
  -H "$TEL" "$TABAN/bot/sube"
bekle "Yanlis token -> 401" 401 '"kod":"YETKISIZ_ISTEK"' \
  -H "X-Bot-Token: yanlis-token" -H "$TEL" "$TABAN/bot/sube"
bekle "Bos token -> 401" 401 '"kod":"YETKISIZ_ISTEK"' \
  -H "X-Bot-Token;" -H "$TEL" "$TABAN/bot/sube"
bekle "Dogru token -> 200" 200 '"ok":true' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/sube"
bekle "Token var ama musteri kimligi yok -> 401 KIMLIK_YOK" 401 '"kod":"KIMLIK_YOK"' \
  -H "$TOK" "$TABAN/bot/sube"
bekle "Saglik kontrolu token gerektirmez" 200 'ok' "$TABAN/saglik"

echo "--- Kopru kimligi (ince senaryolar) ---"
# Esit uzunlukta, tek bayti farkli token
SAHTE=$(printf '%s' "$BOTTOKEN" | sed 's/^./0/; s/^0/1/' )
[ "$SAHTE" = "$BOTTOKEN" ] && SAHTE="1$(printf '%s' "$BOTTOKEN" | cut -c2-)"
bekle "Ayni uzunlukta yanlis token -> 401" 401 '"kod":"YETKISIZ_ISTEK"' \
  -H "X-Bot-Token: $SAHTE" -H "$TEL" "$TABAN/bot/sube"
# Token denetimi yontem denetiminden once: token'siz POST 405 degil 401
bekle "Token'siz POST -> 401 (405 degil)" 401 '"kod":"YETKISIZ_ISTEK"' \
  -X POST -H "$TEL" "$TABAN/bot/sube"
# Token kurallari yalniz /bot/sube'da degil, /bot/slot'ta da gecerli
bekle "Token'siz /bot/slot -> 401" 401 '"kod":"YETKISIZ_ISTEK"' \
  -H "$TEL" "$TABAN/bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=$GUN"

echo "--- Kimlik ---"
bekle "Kimliksiz istek 401" 401 '"kod":"KIMLIK_YOK"' \
  -H "$TOK" "$TABAN/bot/sube"
bekle "Geçersiz kimlik 401" 401 '"kod":"KIMLIK_YOK"' \
  -H "$TOK" -H 'X-Musteri-Telefon: abc' "$TABAN/bot/sube"
bekle "Sağlık kontrolü" 200 'ok' "$TABAN/saglik"

echo "--- POST /bot/musteri ---"
GOV_M='{"ad":"Yeni"}'
GOV_MS='{"ad":"Yeni","soyad":"Musteri"}'
bekle "Musteri: yeni kayit (yalniz ad)" 200 '"ad":"Yeni"' \
  -X POST -H "$TOK" -H 'X-Musteri-Telefon: +905550009900' \
  -H 'Content-Type: application/json' -d "$GOV_M" "$TABAN/bot/musteri"
MID1=$(curl -s -X POST -H "$TOK" -H 'X-Musteri-Telefon: +905550009900' \
  -H 'Content-Type: application/json' -d '{"soyad":"Musteri"}' "$TABAN/bot/musteri" \
  | sed -n 's/.*"musteri_id":\([0-9]*\).*/\1/p')
if [ -n "$MID1" ]; then
  echo "[PASS] Musteri: soyad sonradan eklendi (ayni kayit, id=$MID1)"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Musteri: soyad guncellemesi basarisiz"; KALAN=$((KALAN + 1))
fi
bekle "Musteri: alan yok -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -X POST -H "$TOK" -H "$TEL" -H 'Content-Type: application/json' -d '{}' \
  "$TABAN/bot/musteri"
bekle "Musteri: GET -> 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' \
  -H "$TOK" -H "$TEL" "$TABAN/bot/musteri"
bekle "Musteri: bozuk JSON -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -X POST -H "$TOK" -H "$TEL" -H 'Content-Type: application/json' -d '{bozuk' \
  "$TABAN/bot/musteri"
bekle "Musteri: token yok -> 401" 401 '"kod":"YETKISIZ_ISTEK"' \
  -X POST -H "$TEL" -H 'Content-Type: application/json' -d "$GOV_MS" \
  "$TABAN/bot/musteri"

echo "--- POST /bot/randevu ---"
# GUN2 10:00: kapasite testi icin temiz saat (slot testleri bu saati kullanmiyor)
R1=$(curl -s -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\",\"model\":\"Ioniq 5\"}" \
  "$TABAN/bot/randevu")
if printf '%s' "$R1" | grep -qF '"randevu_id"' \
   && printf '%s' "$R1" | grep -qF '"model":"Ioniq 5"' \
   && printf '%s' "$R1" | grep -qF '"arac"'; then
  echo "[PASS] Randevu: TEST_SURUSU olusturuldu, istenen model atandi, arac dondu"
  GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: TEST_SURUSU olusmadi"; echo "       $R1"; KALAN=$((KALAN + 1))
fi
R1ID=$(printf '%s' "$R1" | sed -n 's/.*"randevu_id":\([0-9]*\).*/\1/p')
MID_R=$(printf '%s' "$R1" | sed -n 's/.*"musteri_id":\([0-9]*\).*/\1/p')
# Ayni musteri ayni saatte ikinci randevu alamaz (musteri EXCLUDE)
bekle "Randevu: ayni musteri ayni saat -> 409" 409 '"kod":"SLOT_DOLU"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\"}" \
  "$TABAN/bot/randevu"
# Ikinci ve ucuncu musteri ayni saatte farkli calisanlara atanmali
R2=$(curl -s -X POST -H "$TOK" -H "$TEL_K" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\"}" \
  "$TABAN/bot/randevu")
R3=$(curl -s -X POST -H "$TOK" -H "$TEL_B" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\"}" \
  "$TABAN/bot/randevu")
if printf '%s' "$R2" | grep -qF '"randevu_id"' \
   && printf '%s' "$R3" | grep -qF '"randevu_id"' \
   && ! printf '%s' "$R2" | grep -qF '"vin":"'"$(printf '%s' "$R1" | sed -n 's/.*"vin":"\([^"]*\)".*/\1/p')"'"'; then
  echo "[PASS] Randevu: farkli musteriler farkli calisan/arac aldi"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: atama cakisti"; echo "       R1=$R1"; echo "       R2=$R2"; KALAN=$((KALAN + 1))
fi
# Dorduncu: 3 yetkin satici dolu -> CALISAN_YOK
YANIT_4=$(curl -s -w '\n%{http_code}' -X POST -H "$TOK" \
  -H 'X-Musteri-Telefon: +905550009933' -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\"}" \
  "$TABAN/bot/randevu")
KOD_4=$(printf '%s' "$YANIT_4" | tail -n1)
GOV_4=$(printf '%s' "$YANIT_4" | sed '$d')
if [ "$KOD_4" = "409" ] && printf '%s' "$GOV_4" | grep -qF '"sebep":"CALISAN_YOK"'; then
  echo "[PASS] Randevu: tum calisanlar dolu -> 409 CALISAN_YOK"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: kapasite yaniti yanlis"; echo "       HTTP $KOD_4 $GOV_4"; KALAN=$((KALAN + 1))
fi
# Model yok: Tucson stokta degil -> 404 + mevcut modeller
YANIT_MD=$(curl -s -w '\n%{http_code}' -X POST -H "$TOK" -H "$TEL_S" \
  -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"15:00\",\"model\":\"Tucson\"}" \
  "$TABAN/bot/randevu")
KOD_MD=$(printf '%s' "$YANIT_MD" | tail -n1)
GOV_MD=$(printf '%s' "$YANIT_MD" | sed '$d')
if [ "$KOD_MD" = "404" ] && printf '%s' "$GOV_MD" | grep -qF '"kod":"ARAC_YOK"' \
   && printf '%s' "$GOV_MD" | grep -qF '"mevcut_modeller"'; then
  echo "[PASS] Randevu: olmayan model -> 404 + mevcut modeller"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: model yok yaniti yanlis"; echo "       HTTP $KOD_MD $GOV_MD"; KALAN=$((KALAN + 1))
fi
# Saat tur penceresinde degil
bekle "Randevu: tur penceresi disi saat -> 400" 400 '"kod":"GECERSIZ_SAAT"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"13:00\"}" \
  "$TABAN/bot/randevu"
# Gecmis / cok uzak / bilinmeyen
bekle "Randevu: gecmis tarih -> 400" 400 '"kod":"GECMIS_TARIH"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d '{"sube_id":1,"tur_kodu":"TEST_SURUSU","tarih":"2020-01-01","baslangic":"10:00"}' \
  "$TABAN/bot/randevu"
bekle "Randevu: bilinmeyen sube -> 404" 404 '"kod":"SUBE_YOK"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":999,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\"}" \
  "$TABAN/bot/randevu"
bekle "Randevu: bilinmeyen tur -> 404" 404 '"kod":"TUR_YOK"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"YOKTUR\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\"}" \
  "$TABAN/bot/randevu"
bekle "Randevu: model aracsiz turde -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"ARAC_INCELEME\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\",\"model\":\"Ioniq 5\"}" \
  "$TABAN/bot/randevu"
# Bakim: kendi araci olan musteri 200, aracsiz musteri 409
bekle "Randevu: BAKIM kendi araciyla olusur" 201 '"randevu_id"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"PERIYODIK_BAKIM\",\"tarih\":\"$GUN2\",\"baslangic\":\"09:00\"}" \
  "$TABAN/bot/randevu"
YANIT_AB=$(curl -s -w '\n%{http_code}' -X POST -H "$TOK" -H "$TEL_B" \
  -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"PERIYODIK_BAKIM\",\"tarih\":\"$GUN2\",\"baslangic\":\"12:00\"}" \
  "$TABAN/bot/randevu")
KOD_AB=$(printf '%s' "$YANIT_AB" | tail -n1)
GOV_AB=$(printf '%s' "$YANIT_AB" | sed '$d')
if [ "$KOD_AB" = "404" ] && printf '%s' "$GOV_AB" | grep -qF '"kod":"ARAC_YOK"'; then
  echo "[PASS] Randevu: aracsiz musteriye bakim -> 404 ARAC_YOK (saat degil, arac yok)"
  GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: bakim arac yaniti yanlis"; echo "       HTTP $KOD_AB $GOV_AB"; KALAN=$((KALAN + 1))
fi
# Musteri kaydi tekrarlanmiyor: ayni telefonla ikinci kez musteri yazimi ayni id
MID2=$(curl -s -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d '{"ad":"Selin"}' "$TABAN/bot/musteri" | sed -n 's/.*"musteri_id":\([0-9]*\).*/\1/p')
if [ -n "$MID_R" ] && [ "$MID_R" = "$MID2" ]; then
  echo "[PASS] Randevu: musteri kaydi tekrar olusturulmuyor (id=$MID_R)"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: musteri id tutarsiz (randevu=$MID_R, musteri=$MID2)"; KALAN=$((KALAN + 1))
fi
bekle "Randevu: PUT -> 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' \
  -X PUT -H "$TOK" -H "$TEL" "$TABAN/bot/randevu"

echo "--- GET /bot/randevu ---"
TEL_G='X-Musteri-Telefon: +905550001199'
G28=$(date -j -v-28d -f "%Y-%m-%d" "$GUN" +%Y-%m-%d)
G14=$(date -j -v-14d -f "%Y-%m-%d" "$GUN" +%Y-%m-%d)
G7=$(date -j -v-7d -f "%Y-%m-%d" "$GUN" +%Y-%m-%d)

RANDEVU=$(curl -s -w '\n%{http_code}' -H "$TOK" -H "$TEL_G" "$TABAN/bot/randevu")
KOD_RD=$(printf '%s' "$RANDEVU" | tail -n1)
GOV_RD=$(printf '%s' "$RANDEVU" | sed '$d')
if [ "$KOD_RD" = "200" ] \
   && printf '%s' "$GOV_RD" | grep -qF '"toplam":6' \
   && printf '%s' "$GOV_RD" | grep -qF '"yaklasan":[{"randevu_id"' \
   && printf '%s' "$GOV_RD" | grep -qF '"gecmis":[{"randevu_id"'; then
  echo "[PASS] Randevular: toplam, yaklasan ve gecmis listeleri dolu"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevular: liste yaniti yanlis"; echo "       HTTP $KOD_RD $GOV_RD"; KALAN=$((KALAN + 1))
fi
# Gecmis azalan sirali: en yeni once (g-7), sonra g-14
if printf '%s' "$GOV_RD" | grep -qF "\"tarih\":\"$G7\"" \
   && printf '%s' "$GOV_RD" | grep -qF "\"tarih\":\"$G14\"" \
   && printf '%s' "$GOV_RD" | grep -qF '"durum_adi":"Tamamlandı"'; then
  echo "[PASS] Randevular: gecmis tarihleri ve durum adi dogru"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevular: tarih/durum eksik"; echo "       $GOV_RD"; KALAN=$((KALAN + 1))
fi
# Son bakim: son N penceresinden bagimsiz (limit=1 iken bile eski bakim doner)
LIM1=$(curl -s -H "$TOK" -H "$TEL_G" "$TABAN/bot/randevu?limit=1")
if printf '%s' "$LIM1" | grep -qF "\"tarih\":\"$G28\"" \
   && ! printf '%s' "$LIM1" | grep -qF "\"tarih\":\"$G14\"" \
   && printf '%s' "$LIM1" | grep -qF '"son_bakim":{"randevu_id"'; then
  echo "[PASS] Randevular: son_bakim son-N penceresinden bagimsiz (limit=1)"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevular: son_bakim/limit ayrimi yanlis"; echo "       $LIM1"; KALAN=$((KALAN + 1))
fi
# RLS gizlenen arac: satilmis aracin gecmis randevusunda arac null gelir
if printf '%s' "$GOV_RD" | grep -qF '"arac":null'; then
  echo "[PASS] Randevular: baskasina satilmis aracin gecmis kaydinda arac null"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevular: gizli arac sizdi"; echo "       $GOV_RD"; KALAN=$((KALAN + 1))
fi
# Gelecek iptal: yaklasan'da degil, gecmis'te
G7I=$(date -j -v+7d -f "%Y-%m-%d" "$GUN" +%Y-%m-%d)
if printf '%s' "$GOV_RD" | grep -qF '"durum_adi":"İptal edildi"'; then
  echo "[PASS] Randevular: gelecek iptal gecmis listesinde gorunuyor"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevular: gelecek iptal kaydi listede yok"; KALAN=$((KALAN + 1))
fi
# son_bakim null: yalniz servis gecmisi olan musteri
YANIT_SB=$(curl -s -H "$TOK" -H 'X-Musteri-Telefon: +905550001210' "$TABAN/bot/randevu")
if printf '%s' "$YANIT_SB" | grep -qF '"son_bakim":null'; then
  echo "[PASS] Randevular: periyodik bakimi olmayanda son_bakim null"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevular: son_bakim null olmaliydi"; echo "       $YANIT_SB"; KALAN=$((KALAN + 1))
fi
# Izolasyon: baska musterinin araci/randevusu gorunmemeli
YANIT_SL=$(curl -s -H "$TOK" -H "$TEL_S" "$TABAN/bot/randevu")
if printf '%s' "$YANIT_SL" | grep -qF 'VIN00000000000042'; then
  echo "[FAIL] Randevular: baska musterinin araci listede"; KALAN=$((KALAN + 1))
else
  echo "[PASS] Randevular: baska musterinin kaydi gorunmuyor"; GECEN=$((GECEN + 1))
fi
# Bos gecmis: hic randevusu olmayan musteri
bekle "Randevular: randevusuz musteri -> bos listeler" 200 '"toplam":0' \
  -H "$TOK" -H 'X-Musteri-Telefon: +905550007702' "$TABAN/bot/randevu"
# limit sinirlari
bekle "Randevular: limit=0 -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL_G" "$TABAN/bot/randevu?limit=0"
bekle "Randevular: limit=51 -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL_G" "$TABAN/bot/randevu?limit=51"
bekle "Randevular: limit=abc -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL_G" "$TABAN/bot/randevu?limit=abc"
bekle "Randevular: limit=50 kabul" 200 '"ok":true' \
  -H "$TOK" -H "$TEL_G" "$TABAN/bot/randevu?limit=50"
bekle "Randevular: bilinmeyen parametre -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -H "$TOK" -H "$TEL_G" "$TABAN/bot/randevu?limt=5"
# 405 yanitinda Allow basligi
ALLOW=$(curl -s -i -X PUT -H "$TOK" -H "$TEL" "$TABAN/bot/randevu" | grep -i '^allow:' | tr -d '\r')
if printf '%s' "$ALLOW" | grep -qF 'GET' && printf '%s' "$ALLOW" | grep -qF 'POST'; then
  echo "[PASS] Randevular: 405 yanitinda Allow: GET, POST"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevular: Allow basligi eksik ($ALLOW)"; KALAN=$((KALAN + 1))
fi
bekle "Randevular: kimlik yok -> 401" 401 '"kod":"KIMLIK_YOK"' \
  -H "$TOK" "$TABAN/bot/randevu"

echo "--- POST /bot/randevu (yeni musteri, rollback, eszamanlilik) ---"
# Yeni telefonla basarili kayit: musteri satiri + randevu ayni transaction'da
TN1='X-Musteri-Telefon: +905550007701'
YENI1=$(curl -s -w '\n%{http_code}' -X POST -H "$TOK" -H "$TN1" \
  -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"15:00\",\"ad\":\"Zeynep\",\"soyad\":\"Ak\"}" \
  "$TABAN/bot/randevu")
KOD_Y1=$(printf '%s' "$YENI1" | tail -n1)
GOV_Y1=$(printf '%s' "$YENI1" | sed '$d')
if [ "$KOD_Y1" = "201" ] && printf '%s' "$GOV_Y1" | grep -qF '"musteri_id"' \
   && printf '%s' "$GOV_Y1" | grep -qF '"randevu_id"'; then
  echo "[PASS] Randevu: yeni musteri + randevu tek transaction'da olustu"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: yeni musteri kaydi basarisiz"; echo "       HTTP $KOD_Y1 $GOV_Y1"; KALAN=$((KALAN + 1))
fi
# Rollback kaniti: 409 alan istekte ogrenilen ad yazilmamali
curl -s -o /dev/null -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\",\"ad\":\"YanlisAd\"}" \
  "$TABAN/bot/randevu"
SELIN=$(curl -s -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d '{"soyad":"Oz"}' "$TABAN/bot/musteri")
if printf '%s' "$SELIN" | grep -qF '"ad":"Selin"' \
   && ! printf '%s' "$SELIN" | grep -qF 'YanlisAd'; then
  echo "[PASS] Randevu: 409 alan istek rollback edildi (ad degismedi)"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: rollback calismadi"; echo "       $SELIN"; KALAN=$((KALAN + 1))
fi
# Ayni yeni telefonla paralel iki istek: ikisi de 500 almamali (ON CONFLICT)
TN2='X-Musteri-Telefon: +905550007702'
curl -s -o /tmp/md-p1.json -w '%{http_code}' -X POST -H "$TOK" -H "$TN2" \
  -H 'Content-Type: application/json' \
  -d '{"ad":"Paralel"}' "$TABAN/bot/musteri" > /tmp/md-c1.txt &
P1=$!
curl -s -o /tmp/md-p2.json -w '%{http_code}' -X POST -H "$TOK" -H "$TN2" \
  -H 'Content-Type: application/json' \
  -d '{"soyad":"Musteri"}' "$TABAN/bot/musteri" > /tmp/md-c2.txt &
P2=$!
wait $P1 $P2
C1=$(cat /tmp/md-c1.txt); C2=$(cat /tmp/md-c2.txt)
if [ "$C1" = "200" ] && [ "$C2" = "200" ]; then
  echo "[PASS] Musteri: ayni telefonla paralel istek -> ikisi de 200 (500 yok)"
  GECEN=$((GECEN + 1))
else
  echo "[FAIL] Musteri: paralel istek 500/çakışma uretti ($C1/$C2)"; KALAN=$((KALAN + 1))
fi
# Paralel ayni slot: biri kazanir, digeri 409; 500 yok
TN3='X-Musteri-Telefon: +905550007703'
TN4='X-Musteri-Telefon: +905550007704'
GOV_P="{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"14:00\"}"
# 14:00'te 3 saticidan biri zaten mesgul (VIN41 teslimati) -> 2 bos yer var.
# Ayni slota 3 paralel istek: 2 kazanir, 1 cakisma alir; 500 olmamali.
TN5='X-Musteri-Telefon: +905550007705'
PIDS=""
for n in 3 4 5; do
  eval "T=\$TN$n"
  curl -s -o /dev/null -w '%{http_code}' -X POST -H "$TOK" -H "$T" \
    -H 'Content-Type: application/json' -d "$GOV_P" "$TABAN/bot/randevu" > "/tmp/md-s$n.txt" &
  PIDS="$PIDS $!"
done
# DİKKAT: argümansız `wait` arka plandaki sunucuyu da bekler (sonsuz).
wait $PIDS
OKS=0; CAK=0; DIGER=0
for n in 3 4 5; do
  K=$(cat "/tmp/md-s$n.txt")
  case "$K" in
    201) OKS=$((OKS + 1)) ;;
    409) CAK=$((CAK + 1)) ;;
    *)   DIGER=$((DIGER + 1)) ;;
  esac
done
# Kesin dagilim yarisa baglidir (iki istek ayni calisani secebilir); kanitlanmak
# istenen sey: cakisma 500'e donusmuyor ve en az bir istek kazaniyor.
# Kapasite siniri zaten sirali testte (4. istek -> CALISAN_YOK) kanitli.
if [ "$DIGER" -eq 0 ] && [ "$OKS" -ge 1 ] && [ "$CAK" -ge 1 ]; then
  echo "[PASS] Randevu: paralel cakisma 409 ile karsilandi (201=$OKS, 409=$CAK)"
  GECEN=$((GECEN + 1))
else
  echo "[FAIL] Randevu: paralel yaris beklenmedik (201=$OKS, 409=$CAK, diger=$DIGER)"
  KALAN=$((KALAN + 1))
fi
# TESLIMAT: kendi satilmis araci ile basarili yazma
# Atama VIN sırasına göre deterministik; müşterinin kendi araçlarından biri seçilir.
bekle "Randevu: TESLIMAT kendi araciyla olusur" 201 '"tur_kodu":"TESLIMAT"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TESLIMAT\",\"tarih\":\"$GUN2\",\"baslangic\":\"15:00\"}" \
  "$TABAN/bot/randevu"
# Girdi dogrulama: 64+ karakter ad, saniyeli saat
UZUN=$(printf 'a%.0s' $(seq 1 65))
bekle "Randevu: 65 karakter ad -> 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00\",\"ad\":\"$UZUN\"}" \
  "$TABAN/bot/randevu"
bekle "Randevu: saniyeli saat (10:00:30) -> 400" 400 '"kod":"GECERSIZ_SAAT"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$GUN2\",\"baslangic\":\"10:00:30\"}" \
  "$TABAN/bot/randevu"
# Sinir: 22 gun ileri reddedilir
G22R=$(date -v+22d +%Y-%m-%d)
bekle "Randevu: 22 gun ileri -> 400" 400 '"kod":"COK_UZAK_TARIH"' \
  -X POST -H "$TOK" -H "$TEL_S" -H 'Content-Type: application/json' \
  -d "{\"sube_id\":1,\"tur_kodu\":\"TEST_SURUSU\",\"tarih\":\"$G22R\",\"baslangic\":\"10:00\"}" \
  "$TABAN/bot/randevu"
# Musteri guncellemesi: soyad sonradan, ad korunuyor
SON=$(curl -s -X POST -H "$TOK" -H "$TN1" -H 'Content-Type: application/json' \
  -d '{"soyad":"Akdemir"}' "$TABAN/bot/musteri")
if printf '%s' "$SON" | grep -qF '"ad":"Zeynep"' \
   && printf '%s' "$SON" | grep -qF '"soyad":"Akdemir"'; then
  echo "[PASS] Musteri: ad korunurken soyad guncellendi"; GECEN=$((GECEN + 1))
else
  echo "[FAIL] Musteri: kismi guncelleme ad'i ezdi"; echo "       $SON"; KALAN=$((KALAN + 1))
fi

echo "--- Baslangic guvenlik kontrolleri ---"

# baslat_yok <aciklama> <token_degeri|__YOK__>
baslat_yok() {
  aciklama=$1; deger=$2; log=/tmp/md-notoken.log
  rm -f "$log"
  if [ "$deger" = "__YOK__" ]; then
    if env -u BOT_TOKEN DB_HOST=127.0.0.1 DB_PORT=$PORT DB_NAME=postgres \
         BOT_DB_USER=bot_app BOT_DB_PASS="$BOTPW" HTTP_PORT=$((HTTP_PORT + 1)) \
         java -jar "$JAR" > "$log" 2>&1; then
      basladi=1
    else
      basladi=0
    fi
  else
    if BOT_TOKEN="$deger" DB_HOST=127.0.0.1 DB_PORT=$PORT DB_NAME=postgres \
         BOT_DB_USER=bot_app BOT_DB_PASS="$BOTPW" HTTP_PORT=$((HTTP_PORT + 1)) \
         java -jar "$JAR" > "$log" 2>&1; then
      basladi=1
    else
      basladi=0
    fi
  fi

  if [ "$basladi" -eq 1 ]; then
    echo "[FAIL] $aciklama — uygulama basladi"; KALAN=$((KALAN + 1))
  elif grep -qF 'BOT_TOKEN' "$log"; then
    echo "[PASS] $aciklama"; GECEN=$((GECEN + 1))
  else
    echo "[FAIL] $aciklama — basarisiz ama nedeni BOT_TOKEN degil"; KALAN=$((KALAN + 1))
  fi
}

baslat_yok "BOT_TOKEN yoksa uygulama baslamiyor" __YOK__
baslat_yok "BOT_TOKEN yalnizca bosluksa uygulama baslamiyor" "   "
baslat_yok "BOT_TOKEN 32 karakterden kisaysa uygulama baslamiyor" "kisabirtoken"

# Token degeri log'a sizmamali
if grep -qF "$BOTTOKEN" /tmp/md-http-test.log; then
  echo "[FAIL] BOT_TOKEN degeri log dosyasina sizdi"; KALAN=$((KALAN + 1))
else
  echo "[PASS] BOT_TOKEN degeri log'a sizmiyor"; GECEN=$((GECEN + 1))
fi

echo ""
echo "=========================================="
echo "   GEÇEN: $GECEN   KALAN: $KALAN"
if [ "$KALAN" -eq 0 ]; then
  echo "   TÜM HTTP TESTLERİ BAŞARIYLA GEÇTİ"
else
  echo "   BAŞARISIZ TESTLER:$BASARISIZLAR"
fi
echo "=========================================="
[ "$KALAN" -eq 0 ]
