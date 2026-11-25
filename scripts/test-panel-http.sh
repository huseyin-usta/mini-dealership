#!/bin/sh
# Panel API HTTP Test Paketi (docs/api/panel-sozlesmesi.md)
#
# Her senaryo, tarayıcıdaki panelin yapacağı gibi GERÇEK HTTP isteğiyle denenir:
# geçici PostgreSQL + gerçek backend JAR + gerçek panel login rolü (NOINHERIT,
# personel + rapor üyesi). Yanıt durumu ve gövdesi karşılaştırılır.
#
# Gereksinim: Docker, Java 17, Python 3
# Kullanım:  ./scripts/test-panel-http.sh [--derleme-atla]
set -e
cd "$(dirname "$0")/.."

DERLEME_ATLA=0
[ "$1" = "--derleme-atla" ] && DERLEME_ATLA=1

PW=$(openssl rand -hex 12)
BOTPW=$(openssl rand -hex 12)
PANELPW=$(openssl rand -hex 12)
BOTTOKEN=$(openssl rand -hex 32)
SIFRE='Panel-Test-2026!'
CONTAINER=md-test-panel-http-tmp
PORT=5437
HTTP_PORT=8097
JAR=backend/target/mini-dealership-backend.jar
LOG=/tmp/md-panel-test.log

temizle() {
  for p in ${SRV_PID:-} ${SRV2_PID:-} ${SRV3_PID:-}; do
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
  done
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap temizle EXIT

if [ "$DERLEME_ATLA" = 0 ]; then
  echo "==> Backend derleniyor..."
  ( cd backend && ./mvnw -q clean package -DskipTests )
fi
[ -f "$JAR" ] || { echo "HATA: $JAR yok; önce derleyin" >&2; exit 1; }

# Tarihler (GNU/BSD date farkına takılmamak için Python):
#   GUN  : gelecekteki bir Çarşamba (randevu listeleme/ekleme)
#   GECMIS: geçmişteki bir Salı (servis kayıtlarının açılış randevusu)
GUN=$(python3 -c 'import datetime as d; t=d.date.today()+d.timedelta(days=7); print(t+d.timedelta(days=(2-t.weekday())%7))')
GECMIS=$(python3 -c 'import datetime as d; t=d.date.today()-d.timedelta(days=14); print(t+d.timedelta(days=(1-t.weekday())%7))')

echo "==> PostgreSQL 17 test konteyneri başlatılıyor..."
docker run --rm -d --name "$CONTAINER" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1:$PORT:5432 \
  postgres:17-alpine >/dev/null
hazir=0
while [ "$hazir" -eq 0 ]; do
  if [ "$(docker logs "$CONTAINER" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ] \
     && docker exec "$CONTAINER" psql -U postgres -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
    hazir=1
  else
    sleep 1
  fi
done

PSQL="docker exec -i $CONTAINER psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q"

echo "==> Şema dosyaları (db/*.sql) yükleniyor..."
for f in db/*.sql; do $PSQL < "$f"; done

HASH=$(printf '%s' "$SIFRE" | java -cp "$JAR" tr.edu.etu.dealership.panel.SifreHash)

echo "==> Test verisi yükleniyor (GUN=$GUN, GECMIS=$GECMIS)..."
$PSQL -v hash="$HASH" -v gun="$GUN" -v gecmis="$GECMIS" \
      -v botpw="$BOTPW" -v panelpw="$PANELPW" << 'SQL'
-- Seed'deki saatler İstanbul saatidir (timestamptz kolonları dahil)
SET TIME ZONE 'Europe/Istanbul';
CREATE ROLE bot_app LOGIN PASSWORD :'botpw' IN ROLE bot;
-- Panel login rolü: NOINHERIT, SET ROLE yapmadan hiçbir yetkisi yok (fail-closed)
CREATE ROLE panel_app LOGIN NOINHERIT PASSWORD :'panelpw' IN ROLE personel, rapor;

INSERT INTO sube (sehir, ad) VALUES ('Ankara', 'Çankaya'), ('İstanbul', 'Kadıköy');
INSERT INTO mesai (gun, acilis, kapanis)
SELECT g, '08:00'::time, '18:00'::time FROM generate_series(1, 6) g;
INSERT INTO yetkinlik (kod, ad) VALUES ('TEST_SURUSU', 'Test Sürüşü Yetkisi');
INSERT INTO randevu_turu (tur_kodu, ad, sure_dakika, departman, yetkinlik_id) VALUES
  ('TEST_SURUSU',     'Test Sürüşü',       60, 'SATIS',  1),
  ('ARAC_INCELEME',   'Araç İnceleme',     60, 'SATIS',  NULL),
  ('TESLIMAT',        'Yeni Araç Teslimi', 60, 'SATIS',  NULL),
  ('PERIYODIK_BAKIM', 'Periyodik Bakım',   60, 'SERVIS', NULL),
  ('SERVIS_GIRIS',    'Servise Giriş',     30, 'SERVIS', NULL),
  ('SERVIS_TESLIM',   'Servisten Teslim',  30, 'SERVIS', NULL);
INSERT INTO tur_saat (tur_kodu, gun, baslangic, bitis)
SELECT t.tur_kodu, g, '09:00'::time, '17:00'::time
  FROM randevu_turu t CROSS JOIN generate_series(1, 6) g;

INSERT INTO model (ad, garanti_yil, garanti_km) VALUES ('Ioniq 5', 3, 100000), ('Tucson', 5, 150000);
INSERT INTO versiyon (model_id, paket_adi, model_yili, liste_fiyati) VALUES
  (1, 'Advance', 2024, 2000000), (2, 'Elite', 2024, 2350000);
INSERT INTO versiyon_ozellik VALUES (1, 'Menzil', '480 km'), (1, 'Batarya', '77 kWh');

INSERT INTO calisan (sube_id, ad, soyad, departman, eposta, kullanici_adi, sifre_hash, aktif_mi, ise_giris_tarihi) VALUES
  (1, 'Ayşe',  'Satıcı',  'SATIS',  'ayse@x',   'ayse',    :'hash', true,  '2024-01-01'),
  (1, 'Burak', 'Satıcı',  'SATIS',  'burak@x',  'burak',   :'hash', true,  '2024-01-01'),
  (1, 'Deniz', 'Usta',    'SERVIS', 'deniz@x',  'deniz',   :'hash', true,  '2024-01-01'),
  (1, 'Eski',  'Çalışan', 'SATIS',  'eski@x',   'eski',    :'hash', false, '2020-01-01'),
  (2, 'Kerem', 'Kadıköy', 'SATIS',  'kerem@x',  'kadikoy', :'hash', true,  '2024-01-01'),
  -- Sentetik veride olduğu gibi bcrypt biçiminde olmayan hash: 500 değil 401 dönmeli
  (1, 'Bozuk', 'Hash',    'SATIS',  'bozuk@x',  'bozuk',   'gecersiz-hash', true, '2024-01-01'),
  (1, 'Cansu', 'Satıcı',  'SATIS',  'cansu@x',  'cansu',   :'hash', true,  '2024-01-01');
INSERT INTO calisan_yetkinlik VALUES (1, 1, '2024-01-01', NULL), (7, 1, '2024-01-01', NULL);

INSERT INTO musteri (ad, soyad, telefon) VALUES
  ('Ali', 'Veli', '+905550000001'), ('Zeynep', 'Kaya', '+905550000002'), (NULL, NULL, '+905550000003');

INSERT INTO arac (vin, versiyon_id, sube_id, renk, durum, tahmini_varis_tarihi, plaka, musteri_id) VALUES
  ('PNL00000000000001', 1, 1, 'Beyaz',   'STOKTA',  NULL,              NULL,       NULL),
  ('PNL00000000000002', 1, 1, 'Siyah',   'STOKTA',  NULL,              NULL,       NULL),
  ('PNL00000000000003', 2, 1, 'Gri',     'YOLDA',   current_date + 10, NULL,       NULL),
  ('PNL00000000000004', 1, 1, 'Mavi',    'SATILDI', NULL,              '06ABC123', 1),
  ('PNL00000000000005', 2, 2, 'Kırmızı', 'SATILDI', NULL,              '34XYZ789', 2),
  ('PNL00000000000006', 1, 2, 'Beyaz',   'STOKTA',  NULL,              NULL,       NULL);
INSERT INTO stok_hareketi (arac_vin, hareket_turu, zaman, kaynak_sube_id, hedef_sube_id)
SELECT vin, 'GELIS', now() - interval '400 days', NULL, sube_id FROM arac;
INSERT INTO stok_hareketi (arac_vin, hareket_turu, zaman, kaynak_sube_id, hedef_sube_id) VALUES
  ('PNL00000000000004', 'SATIS', now() - interval '200 days', 1, NULL),
  ('PNL00000000000005', 'SATIS', now() - interval '300 days', 2, NULL);

-- Geçmiş servis girişleri (servis kayıtlarının açılış randevuları)
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak) VALUES
  (1, 1, 'SERVIS_GIRIS', 3, 'PNL00000000000004', (:'gecmis' || ' 10:00')::timestamp, (:'gecmis' || ' 10:30')::timestamp, 'TAMAMLANDI', 'PANEL'),
  (2, 1, 'SERVIS_GIRIS', 3, 'PNL00000000000005', (:'gecmis' || ' 11:00')::timestamp, (:'gecmis' || ' 11:30')::timestamp, 'TAMAMLANDI', 'WHATSAPP');
INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi, tahmini_teslim_tarihi, sikayet_aciklama) VALUES
  (1, 3, 'ARIZA', 12000, :'gecmis'::date + 2, 'Şarj olmuyor'),
  (2, 3, 'KAZA',  30000, current_date + 5,   'Ön tampon');
INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum, zaman, aciklama) VALUES
  (1, 'INCELENIYOR', :'gecmis'::date + time '10:30', NULL),
  (1, 'ISLEMDE',     :'gecmis'::date + time '15:00', 'Parça geldi'),
  (2, 'INCELENIYOR', :'gecmis'::date + time '11:30', NULL),
  (2, 'EKSPERTIZ_BEKLENIYOR', :'gecmis'::date + time '16:00', NULL);
INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi) VALUES
  (1, 'Arıza tespiti', 1500, 'MUSTERI'),
  (2, 'Tampon değişimi', 9000, 'SIGORTA');
INSERT INTO sigorta_sirketi (ad) VALUES ('Test Sigorta');
INSERT INTO servis_sigorta (servis_kaydi_id, sirket_id, dosya_no, onaylanan_tutar) VALUES (2, 1, 'D-1', 9000);

-- Gelecek gün (GUN): şube 1'de iki, şube 2'de bir randevu
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak) VALUES
  (1, 1, 'TEST_SURUSU',   1, 'PNL00000000000001', (:'gun' || ' 10:00')::timestamp, (:'gun' || ' 11:00')::timestamp, 'PLANLANDI', 'WHATSAPP'),
  (2, 1, 'ARAC_INCELEME', 2, NULL,                (:'gun' || ' 11:00')::timestamp, (:'gun' || ' 12:00')::timestamp, 'PLANLANDI', 'PANEL'),
  (3, 2, 'ARAC_INCELEME', 5, NULL,                (:'gun' || ' 10:00')::timestamp, (:'gun' || ' 11:00')::timestamp, 'PLANLANDI', 'WHATSAPP'),
  -- Geçmişte kalmış, hâlâ PLANLANDI: personel TAMAMLANDI/GELMEDI işaretler
  (2, 1, 'ARAC_INCELEME', 2, NULL,                (:'gecmis' || ' 14:00')::timestamp, (:'gecmis' || ' 15:00')::timestamp, 'PLANLANDI', 'PANEL');

-- Bot konuşmaları: müşteri 1'e 60 mesaj (sayfalama), müşteri 2'ye 1 mesaj
INSERT INTO mesaj (musteri_id, yon, zaman, icerik)
SELECT 1, CASE WHEN n % 2 = 0 THEN 'GELEN' ELSE 'GIDEN' END,
       now() - make_interval(mins => n), 'mesaj ' || n
  FROM generate_series(1, 60) n;
INSERT INTO mesaj (musteri_id, yon, icerik) VALUES (2, 'GELEN', 'merhaba');

-- Ek servis kayıtları (yukarıdaki kimlikleri kaydırmamak için sonda):
--   3: garanti km'si aşılmış Tucson'da açık arıza; 4: kapanmış kaza kaydı
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin, baslangic, bitis, durum, kaynak) VALUES
  (2, 1, 'SERVIS_GIRIS', 3, 'PNL00000000000005', (:'gecmis' || ' 12:00')::timestamp, (:'gecmis' || ' 12:30')::timestamp, 'TAMAMLANDI', 'PANEL'),
  (2, 1, 'SERVIS_GIRIS', 3, 'PNL00000000000005', (:'gecmis' || ' 13:00')::timestamp, (:'gecmis' || ' 13:30')::timestamp, 'TAMAMLANDI', 'PANEL');
INSERT INTO servis_kaydi (acilis_randevu_id, sorumlu_calisan_id, sebep, giris_kilometresi, tahmini_teslim_tarihi) VALUES
  (7, 3, 'ARIZA', 160000, NULL),
  (8, 3, 'KAZA',  160500, :'gecmis'::date + 1);
INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum, zaman) VALUES
  (3, 'INCELENIYOR', :'gecmis'::date + time '12:30'),
  (4, 'TESLIME_HAZIR', :'gecmis'::date + time '14:00'),
  (4, 'TAMAMLANDI', :'gecmis'::date + time '17:00');
SQL

echo "==> Backend başlatılıyor (port $HTTP_PORT)..."
# baslat <port> <log> [ek env...]: backend'i arka planda başlatır, PID'i SON_PID'e yazar
baslat() {
  bport=$1; blog=$2; shift 2
  env DB_HOST=127.0.0.1 DB_PORT=$PORT DB_NAME=postgres \
    BOT_DB_USER=bot_app BOT_DB_PASS="$BOTPW" BOT_TOKEN="$BOTTOKEN" \
    BIND_ADRESI=127.0.0.1 HTTP_PORT="$bport" "$@" \
    java -jar "$JAR" > "$blog" 2>&1 &
  SON_PID=$!
  for i in $(seq 1 40); do
    curl -fsS "http://127.0.0.1:$bport/saglik" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "HATA: backend başlamadı. Log:" >&2; cat "$blog" >&2; exit 1
}
baslat "$HTTP_PORT" "$LOG" PANEL_DB_USER=panel_app PANEL_DB_PASS="$PANELPW"
SRV_PID=$SON_PID

echo "==> HTTP senaryoları çalıştırılıyor..."
TABAN="http://127.0.0.1:$HTTP_PORT"
JSON='Content-Type: application/json'
GECEN=0
KALAN=0
BASARISIZLAR=""

gec() { echo "[PASS] $1"; GECEN=$((GECEN + 1)); }
kal() {
  echo "[FAIL] $1"; [ -n "$2" ] && echo "       $2"
  KALAN=$((KALAN + 1)); BASARISIZLAR="$BASARISIZLAR
  - $1"
}

# bekle <ad> <beklenen_durum> <beklenen_govde_parcasi> <curl_arg...>
bekle() {
  ad=$1; durum=$2; parca=$3; shift 3
  yanit=$(curl -s -w '\n%{http_code}' "$@")
  kod=$(printf '%s' "$yanit" | tail -n1)
  govde=$(printf '%s' "$yanit" | sed '$d')
  if [ "$kod" = "$durum" ] && printf '%s' "$govde" | grep -qF -- "$parca"; then
    gec "$ad"
  else
    kal "$ad" "beklenen: HTTP $durum + '$parca' | gelen: HTTP $kod | gövde: $(printf '%s' "$govde" | cut -c1-400)"
  fi
}

# yok <ad> <govdede_olmamasi_gereken> <curl_arg...>
yok() {
  ad=$1; parca=$2; shift 2
  govde=$(curl -s "$@")
  if printf '%s' "$govde" | grep -qF -- "$parca"; then
    kal "$ad" "gövdede olmamalıydı: '$parca'"
  else
    gec "$ad"
  fi
}

# giris <kullanici_adi> [port]: oturum anahtarını yazdırır (başarısızsa boş)
giris() {
  curl -s -X POST -H "$JSON" -d "{\"kullanici_adi\":\"$1\",\"sifre\":\"$SIFRE\"}" \
    "http://127.0.0.1:${2:-$HTTP_PORT}/panel/giris" \
    | sed -n 's/.*"oturum":"\([^"]*\)".*/\1/p'
}

# ============================================================================
echo "--- Giriş / çıkış ---"
bekle "Doğru şifre: oturum ve çalışan bilgisi döner" 200 \
  '"calisan":{"calisan_id":1,"ad":"Ayşe","soyad":"Satıcı","sube_id":1,"departman":"SATIS"}' \
  -X POST -H "$JSON" -d "{\"kullanici_adi\":\"ayse\",\"sifre\":\"$SIFRE\"}" "$TABAN/panel/giris"
bekle "Yanlış şifre 401 GIRIS_HATALI" 401 '"kod":"GIRIS_HATALI"' \
  -X POST -H "$JSON" -d '{"kullanici_adi":"burak","sifre":"yanlis"}' "$TABAN/panel/giris"
bekle "Olmayan kullanıcı da aynı hatayı alır (ad sızmaz)" 401 '"kod":"GIRIS_HATALI"' \
  -X POST -H "$JSON" -d "{\"kullanici_adi\":\"hayalet\",\"sifre\":\"$SIFRE\"}" "$TABAN/panel/giris"
bekle "İşten ayrılmış (aktif_mi=false) çalışan giremez" 401 '"kod":"GIRIS_HATALI"' \
  -X POST -H "$JSON" -d "{\"kullanici_adi\":\"eski\",\"sifre\":\"$SIFRE\"}" "$TABAN/panel/giris"
bekle "bcrypt biçiminde olmayan hash 500 değil 401" 401 '"kod":"GIRIS_HATALI"' \
  -X POST -H "$JSON" -d "{\"kullanici_adi\":\"bozuk\",\"sifre\":\"$SIFRE\"}" "$TABAN/panel/giris"
bekle "Şifre eksik 400" 400 '"kod":"GECERSIZ_PARAMETRE"' \
  -X POST -H "$JSON" -d '{"kullanici_adi":"ayse"}' "$TABAN/panel/giris"
bekle "Bilinmeyen alan 400" 400 'Bilinmeyen alan: rol' \
  -X POST -H "$JSON" -d "{\"kullanici_adi\":\"ayse\",\"sifre\":\"$SIFRE\",\"rol\":\"admin\"}" "$TABAN/panel/giris"
bekle "Gövde JSON değil 400" 400 'geçerli JSON değil' \
  -X POST -H "$JSON" -d 'kullanici_adi=ayse' "$TABAN/panel/giris"
bekle "Boş gövde 400" 400 'gövdesi boş' -X POST "$TABAN/panel/giris"
bekle "Şifre sayı (metin değil) 400" 400 'sifre metin olmalı' \
  -X POST -H "$JSON" -d '{"kullanici_adi":"ayse","sifre":1234}' "$TABAN/panel/giris"
bekle "GET /panel/giris 405 (Allow: POST)" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' "$TABAN/panel/giris"

TOKEN=$(giris ayse)
[ -n "$TOKEN" ] && gec "Oturum anahtarı alındı" || kal "Oturum anahtarı alınamadı"
AUTH="Authorization: Bearer $TOKEN"

bekle "Oturumsuz istek 401 OTURUM_YOK" 401 '"kod":"OTURUM_YOK"' "$TABAN/panel/katalog"
bekle "Uydurma anahtar 401" 401 '"kod":"OTURUM_YOK"' -H 'Authorization: Bearer uydurma' "$TABAN/panel/katalog"
bekle "Bearer öneki olmadan 401" 401 '"kod":"OTURUM_YOK"' -H "Authorization: $TOKEN" "$TABAN/panel/katalog"
bekle "Oturumsuz tanımsız yol da 401 (yol varlığı sızmaz)" 401 '"kod":"OTURUM_YOK"' "$TABAN/panel/gizli-yol"
bekle "Oturumlu tanımsız yol 404 YOL_YOK" 404 '"kod":"YOL_YOK"' -H "$AUTH" "$TABAN/panel/gizli-yol"

if curl -s -D - -o /dev/null -X POST -H "$JSON" -d '{"kullanici_adi":"x","sifre":"y"}' "$TABAN/panel/giris" \
   | grep -qi '^cache-control: no-store'; then
  gec "Yanıtlar önbelleğe alınmaz (Cache-Control: no-store)"
else
  kal "Cache-Control: no-store başlığı yok"
fi

# Kaba kuvvet: 5 hatalı denemeden sonra doğru şifre bile kilitli
for n in 1 2 3 4 5; do
  curl -s -o /dev/null -X POST -H "$JSON" -d '{"kullanici_adi":"kadikoy","sifre":"yanlis"}' "$TABAN/panel/giris"
done
bekle "5 hatalı denemeden sonra hesap kilitli (429 COK_DENEME)" 429 '"kod":"COK_DENEME"' \
  -X POST -H "$JSON" -d "{\"kullanici_adi\":\"kadikoy\",\"sifre\":\"$SIFRE\"}" "$TABAN/panel/giris"
bekle "Kilit yalnızca o kullanıcı adını etkiler" 200 '"oturum"' \
  -X POST -H "$JSON" -d "{\"kullanici_adi\":\"burak\",\"sifre\":\"$SIFRE\"}" "$TABAN/panel/giris"

CIKIS_TOKEN=$(giris burak)
bekle "Çıkış 200" 200 '"cikis":true' -X POST -H "Authorization: Bearer $CIKIS_TOKEN" "$TABAN/panel/cikis"
bekle "Çıkıştan sonra aynı anahtar geçersiz" 401 '"kod":"OTURUM_YOK"' \
  -H "Authorization: Bearer $CIKIS_TOKEN" "$TABAN/panel/katalog"
bekle "Oturumsuz çıkış da 200 (bilgi sızmaz)" 200 '"cikis":true' -X POST "$TABAN/panel/cikis"

# ============================================================================
echo "--- Veritabanı rolü (fail-closed) ---"
if docker exec "$CONTAINER" psql -U panel_app -d postgres -tAc 'SELECT count(*) FROM musteri' >/dev/null 2>&1; then
  kal "panel_app SET ROLE yapmadan musteri okuyabildi (NOINHERIT çalışmıyor)"
else
  gec "panel_app SET ROLE yapmadan hiçbir tabloyu okuyamaz"
fi
if docker exec "$CONTAINER" psql -U panel_app -d postgres -tAc \
     'BEGIN; SET LOCAL ROLE personel; SELECT sifre_hash FROM calisan LIMIT 1' >/dev/null 2>&1; then
  kal "personel rolü şifre hash'ini okuyabildi"
else
  gec "personel rolü şifre hash'ini okuyamaz (yalnızca fn_panel_giris)"
fi
if docker exec "$CONTAINER" psql -U panel_app -d postgres -tAc \
     'BEGIN; SET LOCAL ROLE rapor; SELECT telefon FROM musteri LIMIT 1' >/dev/null 2>&1; then
  kal "rapor rolü ham müşteri tablosunu okuyabildi"
else
  gec "rapor rolü ham müşteri tablosunu okuyamaz (yalnızca maskeli view)"
fi

# ============================================================================
# PANEL_SENARYOLARI (uç bazında bölümler aşağıya eklenir)

# ============================================================================
echo "--- GET /panel/katalog ---"
bekle "Katalog şubeleri listeler" 200 '"subeler":[{"sube_id":1,"sehir":"Ankara","ad":"Çankaya"}' \
  -H "$AUTH" "$TABAN/panel/katalog"
bekle "Tür araç gerektirip gerektirmediğini taşır" 200 \
  '"tur_kodu":"TEST_SURUSU","ad":"Test Sürüşü","sure_dakika":60,"departman":"SATIS","arac_gerekli":true' \
  -H "$AUTH" "$TABAN/panel/katalog"
bekle "Çalışan yetkinlikleriyle döner" 200 \
  '"calisan_id":1,"ad":"Ayşe","soyad":"Satıcı","sube_id":1,"departman":"SATIS","yetkinlikler":["TEST_SURUSU"]' \
  -H "$AUTH" "$TABAN/panel/katalog"
yok "Pasif çalışan katalogda yok" '"Eski"' -H "$AUTH" "$TABAN/panel/katalog"
yok "Katalog şifre hash'i taşımaz" 'sifre' -H "$AUTH" "$TABAN/panel/katalog"
bekle "Katalog modelleri listeler" 200 '"modeller":[{"model_id":1,"ad":"Ioniq 5"},{"model_id":2,"ad":"Tucson"}]' \
  -H "$AUTH" "$TABAN/panel/katalog"
bekle "Katalogda bilinmeyen parametre 400" 400 'Bilinmeyen parametre: x' -H "$AUTH" "$TABAN/panel/katalog?x=1"
bekle "POST /panel/katalog 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' -X POST -H "$AUTH" "$TABAN/panel/katalog"

# ============================================================================
echo "--- GET /panel/randevu ---"
bekle "Varsayılan: bugün + oturumdaki şube (bugün randevu yok)" 200 '"sube_id":1,"toplam":0,"randevular":[]' \
  -H "$AUTH" "$TABAN/panel/randevu"
bekle "Gün filtresi: şube 1'de iki randevu, saate göre sıralı" 200 \
  "\"toplam\":2,\"randevular\":[{\"randevu_id\":3,\"baslangic\":\"${GUN}T10:00\",\"bitis\":\"${GUN}T11:00\",\"durum\":\"PLANLANDI\",\"kaynak\":\"WHATSAPP\",\"tur_kodu\":\"TEST_SURUSU\",\"tur_adi\":\"Test Sürüşü\",\"sube_id\":1,\"calisan_id\":1,\"calisan\":\"Ayşe Satıcı\",\"musteri_id\":1,\"musteri\":\"Ali Veli\",\"telefon\":\"+905550000001\",\"arac_vin\":\"PNL00000000000001\",\"plaka\":null,\"model_adi\":\"Ioniq 5\",\"notlar\":null}" \
  -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN"
bekle "Başka şube seçilebilir" 200 '"toplam":1,"randevular":[{"randevu_id":5' \
  -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN&sube_id=2"
bekle "Adı bilinmeyen müşteri null döner" 200 '"musteri":null,"telefon":"+905550000003"' \
  -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN&sube_id=2"
bekle "Tür filtresi" 200 '"toplam":1,"randevular":[{"randevu_id":4' \
  -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN&tur_kodu=ARAC_INCELEME"
bekle "Çalışan filtresi" 200 '"toplam":1,"randevular":[{"randevu_id":3' \
  -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN&calisan_id=1"
bekle "Durum filtresi" 200 '"toplam":0' -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN&durum=IPTAL"
bekle "Sayfalama: limit=1 sayfa=2 ikinci randevuyu verir, toplam değişmez" 200 \
  '"toplam":2,"randevular":[{"randevu_id":4' -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN&limit=1&sayfa=2"
bekle "Geçersiz durum 400" 400 'durum geçersiz' -H "$AUTH" "$TABAN/panel/randevu?durum=SILINDI"
bekle "limit=0 400" 400 'limit 1 ile 200' -H "$AUTH" "$TABAN/panel/randevu?limit=0"
bekle "limit=201 400" 400 'limit 1 ile 200' -H "$AUTH" "$TABAN/panel/randevu?limit=201"
bekle "sayfa=0 400" 400 'sayfa 1' -H "$AUTH" "$TABAN/panel/randevu?sayfa=0"
bekle "Sayısal olmayan sube_id 400" 400 'sube_id tam sayı' -H "$AUTH" "$TABAN/panel/randevu?sube_id=abc"
bekle "Var olmayan tarih (13. ay) 400 GECERSIZ_TARIH" 400 '"kod":"GECERSIZ_TARIH"' -H "$AUTH" "$TABAN/panel/randevu?tarih=2026-13-01"
bekle "Var olmayan gün (31 Kasım) 400" 400 '"kod":"GECERSIZ_TARIH"' -H "$AUTH" "$TABAN/panel/randevu?tarih=2026-11-31"
bekle "Tekrarlanan parametre 400" 400 'birden çok kez' -H "$AUTH" "$TABAN/panel/randevu?sube_id=1&sube_id=2"
bekle "Bilinmeyen parametre 400 (yazım hatası filtresiz sonuç vermez)" 400 'Bilinmeyen parametre: subeid' \
  -H "$AUTH" "$TABAN/panel/randevu?subeid=2"
bekle "SQL enjeksiyonu denemesi yalnızca filtre değeri olarak kalır" 200 '"toplam":0' \
  -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN&tur_kodu=x%27%20OR%20%271%27%3D%271"
bekle "Benzer önekli yol 404 (/panel/randevular)" 404 '"kod":"YOL_YOK"' -H "$AUTH" "$TABAN/panel/randevular"

# ============================================================================
echo "--- POST /panel/randevu ---"
# randevu_ekle <ad> <beklenen_durum> <beklenen_parca> <json>
randevu_ekle() { bekle "$1" "$2" "$3" -X POST -H "$AUTH" -H "$JSON" -d "$4" "$TABAN/panel/randevu"; }
# govde <telefon> <tur> <calisan> <saat> [ek alanlar]
govde() { printf '{"telefon":"%s","sube_id":1,"tur_kodu":"%s","calisan_id":%s,"baslangic":"%sT%s"%s}' "$1" "$2" "$3" "$GUN" "$4" "$5"; }

randevu_ekle "Kayıtlı müşteriye randevu: 201, kaynak PANEL, bitiş tür süresinden" 201 \
  "\"bitis\":\"${GUN}T15:00\",\"durum\":\"PLANLANDI\",\"kaynak\":\"PANEL\",\"tur_kodu\":\"ARAC_INCELEME\",\"tur_adi\":\"Araç İnceleme\",\"sube_id\":1,\"calisan_id\":2,\"calisan\":\"Burak Satıcı\",\"musteri_id\":2,\"musteri\":\"Zeynep Kaya\"" \
  "$(govde +905550000002 ARAC_INCELEME 2 14:00 ',"notlar":"Kapıdan geldi"')"
randevu_ekle "Yeni müşteri telefonla oluşturulur" 201 '"musteri":"Selin Ak","telefon":"+905550000099"' \
  "$(govde +905550000099 ARAC_INCELEME 2 16:00 ',"ad":"Selin","soyad":"Ak"')"
randevu_ekle "Test sürüşü (araçlı) randevusu" 201 '"tur_kodu":"TEST_SURUSU","tur_adi":"Test Sürüşü","sube_id":1,"calisan_id":7' \
  "$(govde +905550000099 TEST_SURUSU 7 09:00 ',"arac_vin":"PNL00000000000002"')"
randevu_ekle "Yeni müşteride ad/soyad eksik 400" 400 'ad ve soyad zorunlu' \
  "$(govde +905550000098 ARAC_INCELEME 2 13:00)"
randevu_ekle "Telefon E.164 değil 400" 400 'E.164' "$(govde 05550000002 ARAC_INCELEME 2 13:00)"
randevu_ekle "Geçmiş saat 400 GECMIS_TARIH" 400 '"kod":"GECMIS_TARIH"' \
  '{"telefon":"+905550000002","sube_id":1,"tur_kodu":"ARAC_INCELEME","calisan_id":2,"baslangic":"2020-01-07T10:00"}'
randevu_ekle "Bozuk zaman biçimi 400" 400 'YYYY-MM-DDTHH:MM' \
  '{"telefon":"+905550000002","sube_id":1,"tur_kodu":"ARAC_INCELEME","calisan_id":2,"baslangic":"yarin"}'
randevu_ekle "Bilinmeyen tür 404" 404 'Randevu türü bulunamadı' "$(govde +905550000002 MASAJ 2 13:00)"
randevu_ekle "Bilinmeyen şube 404" 404 'Şube bulunamadı' \
  "$(govde +905550000002 ARAC_INCELEME 2 13:00 | sed 's/"sube_id":1/"sube_id":99/')"
randevu_ekle "Bilinmeyen çalışan 404" 404 'Çalışan bulunamadı' "$(govde +905550000002 ARAC_INCELEME 99 13:00)"
randevu_ekle "Bilinmeyen araç 404" 404 'Araç bulunamadı' \
  "$(govde +905550000002 TEST_SURUSU 7 13:00 ',"arac_vin":"YOKYOKYOKYOKYOK00"')"
randevu_ekle "Araçlı türde araç eksik 400" 400 'arac_vin zorunlu' "$(govde +905550000002 TEST_SURUSU 7 13:00)"
randevu_ekle "Araçsız türde araç verilirse 400" 400 'araç seçilmez' \
  "$(govde +905550000002 ARAC_INCELEME 2 13:00 ',"arac_vin":"PNL00000000000002"')"
randevu_ekle "calisan_id metin 400" 400 'calisan_id tam sayı' "$(govde +905550000002 ARAC_INCELEME '"2"' 13:00)"
randevu_ekle "Bilinmeyen alan 400 (kaynak elle verilemez)" 400 'Bilinmeyen alan: kaynak' \
  "$(govde +905550000002 ARAC_INCELEME 2 13:00 ',"kaynak":"WHATSAPP"')"
randevu_ekle "Çalışan dolu 409 SLOT_DOLU/CALISAN_DOLU" 409 '"sebep":"CALISAN_DOLU"' \
  "$(govde +905550000077 TEST_SURUSU 1 10:30 ',"ad":"Can","soyad":"Er","arac_vin":"PNL00000000000002"')"
randevu_ekle "Araç dolu 409 ARAC_DOLU" 409 '"sebep":"ARAC_DOLU"' \
  "$(govde +905550000077 TEST_SURUSU 7 10:30 ',"ad":"Can","soyad":"Er","arac_vin":"PNL00000000000001"')"
randevu_ekle "Müşteri aynı saatte başka randevuda 409 MUSTERI_DOLU" 409 '"sebep":"MUSTERI_DOLU"' \
  "$(govde +905550000001 ARAC_INCELEME 2 10:00)"
randevu_ekle "Yetkinliği olmayan çalışana test sürüşü 409" 409 '"sebep":"YETKINLIK_YOK"' \
  "$(govde +905550000002 TEST_SURUSU 2 15:00 ',"arac_vin":"PNL00000000000002"')"
randevu_ekle "Servis çalışanına satış randevusu 409 DEPARTMAN" 409 '"sebep":"DEPARTMAN"' \
  "$(govde +905550000002 ARAC_INCELEME 3 13:00)"
randevu_ekle "Başka şubenin çalışanı 409 BASKA_SUBE" 409 '"sebep":"BASKA_SUBE"' \
  "$(govde +905550000002 ARAC_INCELEME 5 13:00)"
randevu_ekle "Pasif çalışana randevu 409 PASIF" 409 '"sebep":"PASIF"' \
  "$(govde +905550000002 ARAC_INCELEME 4 13:00)"
randevu_ekle "Tür saat penceresi dışı (17:30) 400 GECERSIZ_SAAT" 400 '"kod":"GECERSIZ_SAAT"' \
  "$(govde +905550000002 ARAC_INCELEME 2 17:30)"
PAZAR=$(python3 -c 'import datetime as d; t=d.date.today()+d.timedelta(days=1); print(t+d.timedelta(days=(6-t.weekday())%7))')
randevu_ekle "Pazar günü (mesai yok) 400 GECERSIZ_SAAT" 400 '"kod":"GECERSIZ_SAAT"' \
  "{\"telefon\":\"+905550000002\",\"sube_id\":1,\"tur_kodu\":\"ARAC_INCELEME\",\"calisan_id\":2,\"baslangic\":\"${PAZAR}T10:00\"}"
randevu_ekle "Yoldaki araçla test sürüşü 409 ARAC_UYGUN_DEGIL" 409 '"kod":"ARAC_UYGUN_DEGIL"' \
  "$(govde +905550000002 TEST_SURUSU 7 15:00 ',"arac_vin":"PNL00000000000003"')"
yok "Reddedilen istekte yeni müşteri oluşmaz (rollback)" '+905550000077' \
  -H "$AUTH" "$TABAN/panel/randevu?tarih=$GUN"

# Eşzamanlılık: aynı çalışan + aynı saat için iki paralel istek → biri 201, biri 409
curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H "$JSON" \
  -d "$(govde +905550000002 ARAC_INCELEME 2 09:00)" "$TABAN/panel/randevu" > /tmp/md-esz1 &
P1=$!
curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H "$JSON" \
  -d "$(govde +905550000099 ARAC_INCELEME 2 09:00)" "$TABAN/panel/randevu" > /tmp/md-esz2 &
P2=$!
wait "$P1"; wait "$P2"
SONUC="$(cat /tmp/md-esz1) $(cat /tmp/md-esz2)"
case "$SONUC" in
  "201 409"|"409 201") gec "Eşzamanlı iki istekten yalnızca biri yer alır ($SONUC)" ;;
  *) kal "Eşzamanlı istek sonucu beklenmedik: $SONUC" ;;
esac

# ============================================================================
echo "--- POST /panel/randevu/{id}/durum ---"
# durum <ad> <beklenen_durum> <parca> <id> <hedef>
durum() { bekle "$1" "$2" "$3" -X POST -H "$AUTH" -H "$JSON" -d "{\"durum\":\"$5\"}" "$TABAN/panel/randevu/$4/durum"; }
durum "Geçmiş planlı randevu TAMAMLANDI yapılır" 200 '"durum":"TAMAMLANDI"' 6 TAMAMLANDI
durum "Tamamlanmış randevunun durumu değişmez 409" 409 '"kod":"GECERSIZ_GECIS"' 6 IPTAL
durum "Gelecekteki randevu TAMAMLANDI yapılamaz 409" 409 '"kod":"ZAMANI_GELMEDI"' 4 TAMAMLANDI
durum "Gelecekteki randevu GELMEDI yapılamaz 409" 409 '"kod":"ZAMANI_GELMEDI"' 4 GELMEDI
durum "Gelecekteki randevu iptal edilir" 200 "\"randevu_id\":4,\"baslangic\":\"${GUN}T11:00\",\"bitis\":\"${GUN}T12:00\",\"durum\":\"IPTAL\"" 4 IPTAL
durum "PLANLANDI hedef durum olamaz 400" 400 'TAMAMLANDI, GELMEDI veya IPTAL' 4 PLANLANDI
durum "İptal edilmiş randevu tekrar iptal edilemez 409" 409 '"mevcut_durum":"IPTAL"' 4 IPTAL
durum "Olmayan randevu 404" 404 'Randevu bulunamadı' 9999 IPTAL
durum "int sınırını aşan id 404" 404 '"kod":"BULUNAMADI"' 99999999999 IPTAL
bekle "Sayısal olmayan id 404 YOL_YOK" 404 '"kod":"YOL_YOK"' -X POST -H "$AUTH" -H "$JSON" -d '{"durum":"IPTAL"}' "$TABAN/panel/randevu/abc/durum"
bekle "GET /durum 405" 405 'Bu yöntem desteklenmiyor' -H "$AUTH" "$TABAN/panel/randevu/4/durum"
randevu_ekle "İptal edilen saat yeniden verilebilir (EXCLUDE iptali saymaz)" 201 "\"baslangic\":\"${GUN}T11:00\"" \
  "$(govde +905550000099 ARAC_INCELEME 2 11:00)"

# ============================================================================
echo "--- GET /panel/arac ---"
bekle "Varsayılan: oturumdaki şubenin araçları" 200 '"sube_id":1,"toplam":4' -H "$AUTH" "$TABAN/panel/arac"
bekle "Araç satırı model, paket, fiyat ve şube adını taşır" 200 \
  '{"vin":"PNL00000000000001","plaka":null,"model_id":1,"model_adi":"Ioniq 5","paket_adi":"Advance","model_yili":2024,"renk":"Beyaz","durum":"STOKTA","tahmini_varis_tarihi":null,"sube_id":1,"sube_adi":"Çankaya","liste_fiyati":2000000}' \
  -H "$AUTH" "$TABAN/panel/arac"
bekle "Durum filtresi (YOLDA) varış tarihiyle" 200 '"toplam":1,"araclar":[{"vin":"PNL00000000000003"' \
  -H "$AUTH" "$TABAN/panel/arac?durum=YOLDA"
bekle "Model filtresi" 200 '"toplam":3' -H "$AUTH" "$TABAN/panel/arac?model_id=1"
bekle "Başka şube" 200 '"sube_id":2,"toplam":2' -H "$AUTH" "$TABAN/panel/arac?sube_id=2"
bekle "Plaka ile arama tüm şubelerde (boşluk/küçük harf önemsiz)" 200 '"toplam":1,"araclar":[{"vin":"PNL00000000000005","plaka":"34XYZ789"' \
  -H "$AUTH" "$TABAN/panel/arac?ara=34%20xyz"
bekle "VIN öneki ile arama" 200 '"toplam":6' -H "$AUTH" "$TABAN/panel/arac?ara=pnl"
bekle "Arama + şube birlikte" 200 '"toplam":0' -H "$AUTH" "$TABAN/panel/arac?ara=34XYZ&sube_id=1"
bekle "% joker karakter değildir" 200 '"toplam":0' -H "$AUTH" "$TABAN/panel/arac?ara=%25"
bekle "_ joker karakter değildir" 200 '"toplam":0' -H "$AUTH" "$TABAN/panel/arac?ara=PNL_"
bekle "17 karakterden uzun arama 400" 400 'en fazla 17' -H "$AUTH" "$TABAN/panel/arac?ara=PNL000000000000011"
bekle "Geçersiz durum 400" 400 'durum geçersiz' -H "$AUTH" "$TABAN/panel/arac?durum=HURDA"

echo "--- GET /panel/arac/{vin} ---"
bekle "Satılmış araç: sahip bilgisi" 200 '"sahip":{"musteri_id":1,"ad_soyad":"Ali Veli","telefon":"+905550000001"}' \
  -H "$AUTH" "$TABAN/panel/arac/PNL00000000000004"
bekle "Versiyon özellikleri" 200 '"ozellikler":[{"ozellik_adi":"Batarya","deger":"77 kWh"},{"ozellik_adi":"Menzil","deger":"480 km"}]' \
  -H "$AUTH" "$TABAN/panel/arac/PNL00000000000004"
GBAS=$(python3 -c 'import datetime as d; print(d.date.today()-d.timedelta(days=200))')
GBIT=$(python3 -c 'import datetime as d; t=d.date.today()-d.timedelta(days=200); print(t.replace(year=t.year+3))')
bekle "Garanti: satıştan başlar, model süresi kadar (3 yıl)" 200 "\"garanti_baslangic\":\"$GBAS\",\"garanti_bitis\":\"$GBIT\",\"garanti_km\":100000,\"son_bilinen_km\":12000" \
  -H "$AUTH" "$TABAN/panel/arac/PNL00000000000004"
bekle "Stok hareketleri zaman sırasıyla (geliş, satış)" 200 '"stok_hareketleri":[{"hareket_turu":"GELIS"' \
  -H "$AUTH" "$TABAN/panel/arac/PNL00000000000004"
bekle "Servis geçmişi araç detayında" 200 '"servis_kayitlari":[{"servis_kaydi_id":1,"sebep":"ARIZA"' \
  -H "$AUTH" "$TABAN/panel/arac/PNL00000000000004"
bekle "Stoktaki araçta sahip ve garanti yok" 200 '"sahip":null' -H "$AUTH" "$TABAN/panel/arac/PNL00000000000001"
bekle "Stoktaki araçta garanti null" 200 '"garanti":null' -H "$AUTH" "$TABAN/panel/arac/PNL00000000000001"
bekle "VIN küçük harfle de bulunur" 200 '"vin":"PNL00000000000001"' -H "$AUTH" "$TABAN/panel/arac/pnl00000000000001"
bekle "Olmayan VIN 404" 404 'Araç bulunamadı' -H "$AUTH" "$TABAN/panel/arac/XXX00000000000001"
bekle "17 karakter olmayan VIN 404 YOL_YOK" 404 '"kod":"YOL_YOK"' -H "$AUTH" "$TABAN/panel/arac/PNL1"
bekle "VIN'de özel karakter 404 YOL_YOK" 404 '"kod":"YOL_YOK"' -H "$AUTH" "$TABAN/panel/arac/PNL0000000000000%27"
bekle "POST /panel/arac 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' -X POST -H "$AUTH" "$TABAN/panel/arac"

# ============================================================================
echo "--- GET /panel/servis ---"
bekle "Varsayılan: oturumdaki şubenin servis kayıtları" 200 '"sube_id":1,"toplam":4' -H "$AUTH" "$TABAN/panel/servis"
bekle "Açık kayıtlar önce, tahmini teslim tarihine göre" 200 '"servisler":[{"servis_kaydi_id":1,' -H "$AUTH" "$TABAN/panel/servis"
bekle "Satır araç, model, müşteri ve masrafı taşır" 200 \
  '"servis_kaydi_id":1,"sube_id":1,"arac_vin":"PNL00000000000004","plaka":"06ABC123","model_adi":"Ioniq 5","musteri_id":1,"musteri":"Ali Veli","sebep":"ARIZA"' \
  -H "$AUTH" "$TABAN/panel/servis"
bekle "Yalnızca açık kayıtlar" 200 '"toplam":3' -H "$AUTH" "$TABAN/panel/servis?acik=true"
bekle "Yalnızca kapanmış kayıtlar" 200 '"toplam":1,"servisler":[{"servis_kaydi_id":4' -H "$AUTH" "$TABAN/panel/servis?acik=false"
bekle "Gecikenler (tahmini tarih geçmiş, açık)" 200 '"toplam":1,"servisler":[{"servis_kaydi_id":1' -H "$AUTH" "$TABAN/panel/servis?gecikti=true"
bekle "Plaka ile arama tüm şubelerde" 200 '"toplam":3' -H "$AUTH" "$TABAN/panel/servis?ara=34xyz789"
bekle "Başka şubede servis yok" 200 '"toplam":0' -H "$AUTH" "$TABAN/panel/servis?sube_id=2"
bekle "acik=evet 400 (true/false)" 400 'true veya false' -H "$AUTH" "$TABAN/panel/servis?acik=evet"

echo "--- GET /panel/servis/{id} ---"
bekle "Detay: sorumlu çalışan, şikâyet ve masraf kırılımı" 200 '"sorumlu_calisan":"Deniz Usta","sikayet_aciklama":"Şarj olmuyor"' \
  -H "$AUTH" "$TABAN/panel/servis/1"
bekle "Detay: durum geçmişi zaman sırasıyla" 200 '"durum_gecmisi":[{"durum":"INCELENIYOR","zaman":"'"$GECMIS"'T10:30","aciklama":null},{"durum":"ISLEMDE"' \
  -H "$AUTH" "$TABAN/panel/servis/1"
bekle "Detay: işlemler" 200 '"islemler":[{"islem_id":1,"islem_adi":"Arıza tespiti","ucret":1500,"odeme_kaynagi":"MUSTERI","aciklama":null}]' \
  -H "$AUTH" "$TABAN/panel/servis/1"
bekle "Kaza kaydında sigorta bilgisi" 200 '"sigorta":{"sirket_id":1,"sirket":"Test Sigorta","dosya_no":"D-1","eksper":null,"onaylanan_tutar":9000}' \
  -H "$AUTH" "$TABAN/panel/servis/2"
bekle "Sigortasız kayıtta sigorta null" 200 '"sigorta":null' -H "$AUTH" "$TABAN/panel/servis/1"
bekle "Masraf kırılımı (sigorta payı)" 200 '"toplam_masraf":9000,"musteri_payi":0,"garanti_payi":0,"sigorta_payi":9000' \
  -H "$AUTH" "$TABAN/panel/servis/2"
bekle "Olmayan servis 404" 404 'Servis kaydı bulunamadı' -H "$AUTH" "$TABAN/panel/servis/999"

echo "--- POST /panel/servis/{id}/durum ---"
SDURUM() { bekle "$1" "$2" "$3" -X POST -H "$AUTH" -H "$JSON" -d "$5" "$TABAN/panel/servis/$4/durum"; }
YARIN=$(python3 -c 'import datetime as d; print(d.date.today()+d.timedelta(days=3))')
SDURUM "Durum eklenir, tahmini teslim güncellenir (201)" 201 "\"son_durum\":\"PARCA_BEKLENIYOR\"" 1 \
  "{\"durum\":\"PARCA_BEKLENIYOR\",\"aciklama\":\"Şarj ünitesi sipariş edildi\",\"tahmini_teslim_tarihi\":\"$YARIN\"}"
bekle "Tahmin güncellendi, artık gecikmede değil" 200 "\"kapandi_mi\":false,\"tahmini_teslim_tarihi\":\"$YARIN\",\"kalan_gun\":3,\"gecikti_mi\":false" \
  -H "$AUTH" "$TABAN/panel/servis/1"
bekle "Geçmiş silinmez: eski durumlar duruyor" 200 '{"durum":"ISLEMDE"' -H "$AUTH" "$TABAN/panel/servis/1"
SDURUM "Geçersiz durum 400" 400 'durum geçersiz' 1 '{"durum":"HURDA"}'
SDURUM "Geçmiş tahmini teslim tarihi 400" 400 '"kod":"GECMIS_TARIH"' 1 '{"durum":"ISLEMDE","tahmini_teslim_tarihi":"2020-01-01"}'
SDURUM "Bozuk tarih 400" 400 '"kod":"GECERSIZ_TARIH"' 1 '{"durum":"ISLEMDE","tahmini_teslim_tarihi":"01.01.2027"}'
SDURUM "Kapanmış kayda durum eklenemez 409" 409 '"kod":"KAPALI_KAYIT"' 4 '{"durum":"ISLEMDE"}'
SDURUM "Olmayan servis 404" 404 'Servis kaydı bulunamadı' 999 '{"durum":"ISLEMDE"}'
SDURUM "Bilinmeyen alan 400" 400 'Bilinmeyen alan: zaman' 1 '{"durum":"ISLEMDE","zaman":"2020-01-01T00:00"}'

echo "--- POST /panel/servis/{id}/islem ---"
SISLEM() { bekle "$1" "$2" "$3" -X POST -H "$AUTH" -H "$JSON" -d "$5" "$TABAN/panel/servis/$4/islem"; }
SISLEM "Garantisi geçerli arızada garanti ödemesi kabul" 201 '"islem_adi":"Şarj ünitesi","ucret":42000,"odeme_kaynagi":"GARANTI"' 1 \
  '{"islem_adi":"Şarj ünitesi","ucret":42000,"odeme_kaynagi":"GARANTI"}'
bekle "Masraf kırılımı güncellendi" 200 '"toplam_masraf":43500,"musteri_payi":1500,"garanti_payi":42000,"sigorta_payi":0' \
  -H "$AUTH" "$TABAN/panel/servis/1"
SISLEM "Arızada sigorta ödemesi 409 ODEME_KAYNAGI_GECERSIZ" 409 '"kod":"ODEME_KAYNAGI_GECERSIZ"' 1 \
  '{"islem_adi":"X","ucret":10,"odeme_kaynagi":"SIGORTA"}'
SISLEM "Garanti km'si aşılmış araçta garanti 409 KM_ASILDI" 409 '"sebep":"KM_ASILDI"' 3 \
  '{"islem_adi":"Motor","ucret":5000,"odeme_kaynagi":"GARANTI"}'
SISLEM "Aynı kayda müşteri ödemesi kabul" 201 '"odeme_kaynagi":"MUSTERI"' 3 \
  '{"islem_adi":"Motor","ucret":5000,"odeme_kaynagi":"MUSTERI"}'
SISLEM "Kapanmış kayda işlem eklenemez 409" 409 '"kod":"KAPALI_KAYIT"' 4 '{"islem_adi":"X","ucret":10,"odeme_kaynagi":"MUSTERI"}'
SISLEM "Negatif ücret 400" 400 'negatif' 1 '{"islem_adi":"X","ucret":-5,"odeme_kaynagi":"MUSTERI"}'
SISLEM "Kesirli ücret 400 (tam sayı TL)" 400 'ucret tam sayı' 1 '{"islem_adi":"X","ucret":10.5,"odeme_kaynagi":"MUSTERI"}'
SISLEM "Geçersiz ödeme kaynağı 400" 400 'odeme_kaynagi' 1 '{"islem_adi":"X","ucret":10,"odeme_kaynagi":"NAKIT"}'
SISLEM "İşlem adı eksik 400" 400 'islem_adi zorunlu' 1 '{"ucret":10,"odeme_kaynagi":"MUSTERI"}'
SISLEM "Olmayan servis 404" 404 'Servis kaydı bulunamadı' 999 '{"islem_adi":"X","ucret":10,"odeme_kaynagi":"MUSTERI"}'
yok "Reddedilen garanti işlemi kaydedilmedi (rollback)" '"islem_adi":"X"' -H "$AUTH" "$TABAN/panel/servis/1"
bekle "GET /islem 405" 405 '"kod":"YONTEM_DESTEKLENMIYOR"' -H "$AUTH" "$TABAN/panel/servis/1/islem"

# ============================================================================
echo "--- GET /panel/musteri ---"
bekle "Müşteri listesi toplamla döner" 200 '"toplam":' -H "$AUTH" "$TABAN/panel/musteri"
bekle "Telefon önekiyle arama" 200 '"toplam":1,"musteriler":[{"musteri_id":1,"ad":"Ali","soyad":"Veli","telefon":"+905550000001"' \
  -H "$AUTH" "$TABAN/panel/musteri?ara=%2B905550000001"
bekle "Telefonda boşluk önemsiz" 200 '"toplam":1' -H "$AUTH" "$TABAN/panel/musteri?ara=%2B90%20555%20000%200001"
bekle "Ad/soyad içinde arama (büyük/küçük harf önemsiz)" 200 '"toplam":1,"musteriler":[{"musteri_id":2,"ad":"Zeynep","soyad":"Kaya"' \
  -H "$AUTH" "$TABAN/panel/musteri?ara=kAyA"
bekle "Son randevu bilgisi listede" 200 '"son_randevu_turu":"Test Sürüşü","son_randevu_durumu":"PLANLANDI"' \
  -H "$AUTH" "$TABAN/panel/musteri?ara=%2B905550000001"
bekle "% joker değil" 200 '"toplam":0' -H "$AUTH" "$TABAN/panel/musteri?ara=%25"
bekle "Adı bilinmeyen müşteri telefonla bulunur" 200 '"ad":null,"soyad":null,"telefon":"+905550000003"' \
  -H "$AUTH" "$TABAN/panel/musteri?ara=%2B905550000003"
bekle "Çok uzun arama 400" 400 'en fazla 64' -H "$AUTH" "$TABAN/panel/musteri?ara=$(printf 'a%.0s' $(seq 1 65))"

echo "--- GET /panel/musteri/{id} ---"
bekle "Müşteri kartı: iletişim bilgisi" 200 '"musteri_id":1,"ad":"Ali","soyad":"Veli","telefon":"+905550000001"' \
  -H "$AUTH" "$TABAN/panel/musteri/1"
bekle "Randevu geçmişi yeniden eskiye" 200 '"randevular":[{"randevu_id":3,' -H "$AUTH" "$TABAN/panel/musteri/1"
bekle "Sahip olunan araçlar" 200 '"araclar":[{"vin":"PNL00000000000004","plaka":"06ABC123","model_adi":"Ioniq 5"' \
  -H "$AUTH" "$TABAN/panel/musteri/1"
bekle "Olmayan müşteri 404" 404 'Müşteri bulunamadı' -H "$AUTH" "$TABAN/panel/musteri/999"

# ============================================================================
echo "--- Başlangıç ve yapılandırma ---"
baslat $((HTTP_PORT + 1)) /tmp/md-panel-kisa.log \
  PANEL_DB_USER=panel_app PANEL_DB_PASS="$PANELPW" PANEL_OTURUM_SANIYE=2
SRV2_PID=$SON_PID
KISA=$(giris ayse $((HTTP_PORT + 1)))
# Geçerli oturum tanımsız yolda 404 alır (401 değil): oturum kabul edildi demektir
bekle "Oturum süresi içinde geçerli" 404 '"kod":"YOL_YOK"' \
  -H "Authorization: Bearer $KISA" "http://127.0.0.1:$((HTTP_PORT + 1))/panel/gizli-yol"
# Süre dolunca 401. Duvar saati (JVM Instant) ile sleep'in monoton saati WSL2 gibi
# ortamlarda birkaç saniye kayabildiği için tek bir sabit beklemeye bağlanmaz:
# 2 sn'lik oturumun en geç 10 sn içinde düşmesi beklenir.
sleep 2
dustu=0
for n in 1 2 3 4 5 6 7 8; do
  kod=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KISA" \
    "http://127.0.0.1:$((HTTP_PORT + 1))/panel/gizli-yol")
  [ "$kod" = "401" ] && { dustu=1; break; }
  sleep 1
done
[ "$dustu" = 1 ] && gec "Süresi dolan oturum 401" || kal "Süresi dolan oturum 10 sn sonra hâlâ geçerli"
kill "$SRV2_PID" 2>/dev/null || true; wait "$SRV2_PID" 2>/dev/null || true; SRV2_PID=

baslat $((HTTP_PORT + 2)) /tmp/md-panel-kapali.log
SRV3_PID=$SON_PID
bekle "PANEL_DB_USER yoksa panel kapalı, bot/sağlık çalışır" 200 'ok' "http://127.0.0.1:$((HTTP_PORT + 2))/saglik"
kod=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$JSON" \
  -d "{\"kullanici_adi\":\"ayse\",\"sifre\":\"$SIFRE\"}" "http://127.0.0.1:$((HTTP_PORT + 2))/panel/giris")
[ "$kod" = "404" ] && gec "PANEL_DB_USER yoksa /panel/giris yok (404)" || kal "Panel kapalıyken /panel/giris $kod döndü"
kill "$SRV3_PID" 2>/dev/null || true; wait "$SRV3_PID" 2>/dev/null || true; SRV3_PID=

if env -u PANEL_DB_PASS DB_HOST=127.0.0.1 DB_PORT=$PORT DB_NAME=postgres \
     BOT_DB_USER=bot_app BOT_DB_PASS="$BOTPW" BOT_TOKEN="$BOTTOKEN" \
     HTTP_PORT=$((HTTP_PORT + 3)) PANEL_DB_USER=panel_app \
     java -jar "$JAR" > /tmp/md-panel-sifresiz.log 2>&1; then
  kal "PANEL_DB_USER verilip şifre verilmeyince uygulama başladı"
elif grep -qF 'PANEL_DB_PASS' /tmp/md-panel-sifresiz.log; then
  gec "PANEL_DB_USER var, PANEL_DB_PASS yoksa uygulama başlamaz"
else
  kal "Şifresiz panel başlangıcı başka bir nedenle düştü"
fi

for sir in "$SIFRE" "$PANELPW"; do
  if grep -qF -- "$sir" "$LOG"; then kal "Gizli değer log'a sızdı"; else gec "Gizli değer log'a sızmıyor"; fi
done

echo ""
echo "=========================================="
echo "   GEÇEN: $GECEN   KALAN: $KALAN"
if [ "$KALAN" -eq 0 ]; then
  echo "   TÜM PANEL HTTP TESTLERİ BAŞARIYLA GEÇTİ"
else
  echo "   BAŞARISIZ TESTLER:$BASARISIZLAR"
fi
echo "=========================================="
[ "$KALAN" -eq 0 ]
