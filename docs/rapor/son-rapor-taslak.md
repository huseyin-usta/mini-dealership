# TOBB EKONOMİ VE TEKNOLOJİ ÜNİVERSİTESİ
## BİLGİSAYAR MÜHENDİSLİĞİ BÖLÜMÜ — BIL372 Veritabanı Sistemleri

# Mini-Dealership
### Çok Şubeli Otomobil Bayisi için WhatsApp Randevu Asistanı ve Yönetim Paneli

**PROJE SON RAPORU**

| | |
|---|---|
| Hüseyin Yiğit USTA | 231101041 |
| Şevda Yağmur ASAL | 221104100 |

27 Kasım 2026

---

## İçindekiler

1. Gerçek dünya probleminin tanımı
2. Gereksinim analizi
3. Kavramsal tasarım (EER)
4. Mantıksal tasarım ve şema
5. Tasarımın uyarlanması
6. Uygulama programı tanıtımı ve örnek kullanım
7. Sonuç
8. Referanslar

---

## 1. Gerçek Dünya Probleminin Tanımı

Çok şubeli bir otomobil bayisinde randevu yönetimi telefon, elle yazılan WhatsApp
mesajları ve şube bazında tutulan Excel dosyalarıyla yürütülmektedir. Bu düzenin
ölçülebilir sonuçları şunlardır:

- Mesai dışında gelen mesajlar cevapsız kalır; müşteri başka bir kanala yönelir.
- Şubeler birbirinin müsaitliğini görmediği için aynı çalışana veya araca çakışan
  randevu verilebilir.
- Yetkisi olmayan bir çalışana test sürüşü yazılabilir; stokta olmayan ya da
  müşterinin kendi aracı olmayan bir araç için servis randevusu açılabilir.
- Veri dağınık olduğu için “hangi model çok test ediliyor ama satılmıyor?”, “hangi
  şube serviste gecikiyor?” gibi sorular cevaplanamaz.
- Randevu, mesaj ve stok hareketi kayıtları yüz binlere ulaştığından, tutarlılığı
  uygulama koduna bırakmak sürdürülebilir değildir.

Projenin amacı, müşterinin tek bir WhatsApp hattından randevu alabildiği, bayinin
aynı veriyi bir web panelinden yönettiği ve tüm iş kurallarının **veritabanında**
garanti edildiği bir sistemi uçtan uca kurmaktır.

### 1.1 Sistemin kapsamı

Sistem dört parçadan oluşur:

| Parça | Teknoloji | Görev |
|---|---|---|
| WhatsApp köprüsü | Node.js + Baileys | Mesajı backend'e iletir, cevabı müşteriye gönderir; DB'ye dokunmaz |
| Backend | Java 17, JDBC (ORM yok) | Bot API, panel API, iş kuralları, transaction, LLM araç döngüsü |
| Panel | HTML/CSS/JS (düz) | Personel arayüzü; backend tarafından aynı kökenden sunulur |
| Veritabanı | PostgreSQL 17 | 20 tablo, 7 view, roller/RLS, trigger ve EXCLUDE kısıtları |

Dil modeli yalnızca **doğal dil anlama ve yönlendirme** için kullanılır. Randevu
kuralları (mesai, tür saat penceresi, yetkinlik, çakışma, sahiplik) modele
bırakılmaz; `CHECK`, `EXCLUDE`, trigger ve rol/RLS ile veritabanında uygulanır.

---

## 2. Gereksinim Analizi

### 2.1 Aktörler

| Aktör | Temsil | Yetki |
|---|---|---|
| Müşteri | WhatsApp telefonu | Stok sorgular, kendi randevularını görme/iptal, randevu alma |
| Satış personeli | Panel oturumu (`personel`) | Randevu, araç, müşteri, rapor okuma; randevu ekleme/durum |
| Servis personeli | Panel oturumu (`personel`) | Servis kaydı, durum ve masraf işlemleri |
| Rapor kullanıcısı | Panel oturumu (`rapor`) | Yalnızca maskeli view'lar ve Excel |
| Bot | `bot` DB rolü + `X-Bot-Token` | Yalnız konuştuğu müşterinin satırları (RLS) |
| Yönetici | `admin` (şema sahibi) | Şema ve rol yönetimi |

### 2.2 İşlevsel gereksinimler

| # | Gereksinim | Gerçekleme |
|---|---|---|
| G1 | Müşteri telefonla tanınır, yeni müşteri açılır | `musteri.telefon UNIQUE`; bot `POST /bot/musteri` |
| G2 | Şehir/şube ve tür bazında boş saat önerilir | `v_dolu_slot`, `GET /bot/slot` |
| G3 | Randevu oluşturma; çakışma, mesai, yetkinlik denetimi | `220_trg_randevu_dogrula`, EXCLUDE |
| G4 | Müşteri kendi randevularını görür/iptal eder | RLS + `GET /bot/randevu`, `POST …/iptal` |
| G5 | Stok ve yoldaki araçlar bildirilir | `GET /bot/arac`, `v_arac_garanti_durumu` |
| G6 | Panelden randevu eklenir, durum değiştirilir | `POST /panel/randevu`, `POST …/durum` |
| G7 | Araç, müşteri, servis kaydı izlenir | `GET /panel/arac`, `/musteri`, `/servis` |
| G8 | Servis durum geçmişi ve masraf/ödeme kaynağı | `servis_durum_gecmisi`, `servis_islem`, `210` trigger |
| G9 | Garanti saklanmaz, hesaplanır | `v_arac_garanti_durumu` (1 yıl / 15.000 km) |
| G10 | Rapor özeti ve tek yönlü Excel | `GET /panel/rapor/ozet`, `…/randevu.xlsx` (`rapor` rolü) |
| G11 | Bot konuşmaları panelde görünür | `GET /panel/musteri/{id}/mesaj` |
| G12 | WhatsApp'tan doğal dilde randevu | `POST /bot/mesaj` + LLM araç döngüsü |

### 2.3 İşlevsel olmayan gereksinimler

| # | Gereksinim | Karşılanma |
|---|---|---|
| N1 | Veri tutarlılığı uygulama hatasından bağımsız | Kısıt + trigger + EXCLUDE; panel/bot ayrıca erken 4xx |
| N2 | PII minimizasyonu | TC/kimlik yok; bot yalnız kendi müşterisi; rapor maskeli view |
| N3 | Yetki ayrımı | `admin/personel/bot/rapor`; hiçbir rolde DELETE yok |
| N4 | Eşzamanlılık | EXCLUDE + transaction; müşteri upsert; oturum kilidi |
| N5 | Ölçek | 660.433 satır sentetik veri; 13 indeks; ölçülen planlar |
| N6 | Güvenlik | Parametreli SQL, token, bcrypt, CSP, path traversal savunması |
| N7 | Tekrarlanabilirlik | `db/*.sql` numaralı, `veri/uret.py`, test betikleri |
| N8 | Bakım | ORM yok; SQL dosyaları ve handler'lar ayrı sorumluluklar |

### 2.4 Varsayımlar ve kapsam dışı

- Bayi tek markalıdır; markanın bütün araçları bayi ağından satılır, servise gelen
  her araç sistemde kayıtlıdır.
- Mesai ve randevu türü saat pencereleri tüm şubelerde ortaktır.
- Ödeme şubede yüz yüze alınır; sistem yalnızca masraf/ödeme kaynağını kaydeder.
- **Kapsam dışı bırakılanlar:** panelden satış transaction'ı (`POST /panel/satis`),
  servis kaydı açma/teslim uçları. Bunlar tasarımda yer alır; demo kapsamında
  randevu ve servis takibi üzerinden gösterilir.

---

## 3. Kavramsal Tasarım (EER)

Kavramsal model ara raporda ayrıntılı verilmiştir (Şekil 1, EER diyagramı).
Son uygulamada değişmeyen ana kararlar:

- **Kalıtım:** Randevu alt sınıfları tek tabloda, ayırt edici `tur_kodu` ile
  tutulur. Böylece çalışan/araç/müşteri çakışması bütün randevu türleri için tek
  EXCLUDE kısıtıyla engellenir. Alt sınıfa özgü `arac_vin`/`versiyon_id`
  zorunluluğu `CHECK` ile türe bağlanır.
- **Çoka-çok:** `calisan_yetkinlik` (çalışan × yetkinlik), veriliş/bitiş tarihiyle.
- **Türetilmiş nitelikler:** Garanti durumu, son bakım, doluluk ve kalan gün
  saklanmaz; view'larda hesaplanır.
- **Zayıf varlık:** `servis_durum_gecmisi` servis kaydına bağlıdır; kimliği
  `(servis_kaydi_id, zaman)` benzersizliğiyle desteklenir.
- **Silmeli tasarım yok:** İptal, durum değişikliğidir; çalışan ayrılırsa
  `aktif_mi=false` olur. Hiçbir uygulama rolünde DELETE yetkisi yoktur.

> **Şekil 1** — EER diyagramı: ara rapor, Şekil 1.
> **Şekil 2** — Güncel şema: `docs/sema/README.md` ve `docs/sema/*.svg`.

---

## 4. Mantıksal Tasarım ve Şema

### 4.1 Tablolar

Şema 20 tablodan oluşur. Özet:

| Tablo | PK | Önemli kısıt |
|---|---|---|
| `sube` | `sube_id` | `UNIQUE (sehir, ad)` |
| `mesai` | `gun` | `acilis < kapanis` |
| `yetkinlik` | `yetkinlik_id` | `UNIQUE kod` |
| `calisan` | `calisan_id` | `UNIQUE eposta`, `UNIQUE kullanici_adi`; `departman ∈ {SATIS,SERVIS}` |
| `calisan_yetkinlik` | `(calisan_id, yetkinlik_id)` | Veriliş/bitiş tarihi |
| `model` | `model_id` | `UNIQUE ad`; garanti yıl/km |
| `versiyon` | `versiyon_id` | `UNIQUE (model_id, paket_adi, model_yili)` |
| `versiyon_ozellik` | `(versiyon_id, ozellik_adi)` | `CASCADE` |
| `musteri` | `musteri_id` | `UNIQUE telefon`; `ad/soyad` NULL olabilir |
| `mesaj` | `mesaj_id` | `yon ∈ {GELEN,GIDEN}`; `kaynak_id` idempotency |
| `arac` | `vin` | `UNIQUE plaka`; `durum ∈ {YOLDA,STOKTA,SATILDI}` |
| `stok_hareketi` | `hareket_id` | `tur ∈ {SIPARIS,GELIS,TRANSFER,SATIS}` |
| `randevu_turu` | `tur_kodu` | Süre, departman, yetkinlik |
| `tur_saat` | `(tur_kodu, gun, baslangic)` | Aralık mesai içinde |
| `randevu` | `randevu_id` | EXCLUDE: çalışan/araç/müşteri çakışması |
| `servis_kaydi` | `servis_kaydi_id` | Açılış/teslim randevusu UNIQUE; sebep |
| `servis_durum_gecmisi` | `gecmis_id` | `UNIQUE (servis_kaydi_id, zaman)` |
| `servis_islem` | `islem_id` | Ödeme kaynağı sebebe göre |
| `sigorta_sirketi` | `sirket_id` | `UNIQUE ad` |
| `servis_sigorta` | `servis_kaydi_id` | `UNIQUE (sirket_id, dosya_no)` |

### 4.2 Bütünlük kuralları

- **EXCLUDE (GiST):** Aynı çalışan, araç veya müşteri için örtüşen `tsrange`
  aralığı yasaktır. `btree_gist` uzantısı eşitlik + aralık için kullanılır.
- **`220_trg_randevu_dogrula`:** Mesai/tür saat penceresi, çalışanın şubesi,
  departmanı, yetkinliği ve aktifliği; araç türüne göre durum.
- **`460_trg_randevu_sahiplik`:** Araç müşterinin kendi aracı olmalı; servisten
  teslimde açık ve `TESLIME_HAZIR` servis kaydı bulunmalı. `CONSTRAINT TRIGGER
  DEFERRABLE` olarak tanımlıdır: sentetik veri tek transaction'da önce randevuları
  yazabilsin, kural commit'te doğrulansın. Yalnız durum güncelleyen UPDATE'ler
  yeniden doğrulanmaz (araç sonradan satılabilir).
- **`210_trg_servis_garanti`:** Garantisi düşmüş araca “garanti” ödemesi
  girilemez; ödeme kaynağı sebebe göre sınırlıdır.
- **CHECK'ler:** Para kolonları `bigint` tam TL; durum kolonları `varchar + CHECK`;
  `arac` durumuna göre plaka/sahip zorunluluğu.

### 4.3 View'lar

| View | Amaç |
|---|---|
| `v_musteri_son_randevu` | Müşterinin iptaller hariç son randevusu |
| `v_servis_durumu` | Servis kaydının son durumu, kalan gün, gecikme, toplam masraf |
| `v_arac_garanti_durumu` | Satıştan itibaren garanti ve son bakım (hesaplanır) |
| `v_rapor_randevu` | `rapor` rolü için maskeli randevu satırları |
| `v_rapor_musteri` | `rapor` rolü için maskeli müşteri satırları |
| `v_dolu_slot` | Bot için PII'siz dolu saatler |
| `v_musteri_servis_durumu` | Bot için müşteriye özel, masrafsız servis durumu |

### 4.4 Normalizasyon

Şema BCNF'ye kadar normalleştirilmiştir. Öne çıkan ayrıştırmalar:

- `model` ↔ `versiyon` ↔ `versiyon_ozellik`: Donanım paketi ve özellikler
  tekrar etmez.
- `randevu_turu` ↔ `tur_saat`: Türün süresi ve gün bazlı saat pencereleri ayrı
  tutulur; `tur_saat` yalnızca geçerli gün/aralık çiftlerini taşır.
- `servis_kaydi` ↔ `servis_durum_gecmisi` ↔ `servis_islem`: Olay geçmişi ve
  masraf kalemleri ayrı; geçmiş yalnızca eklenir.
- `sigorta_sirketi` ↔ `servis_sigorta`: Şirket bilgisi tekrar etmez.
- Türetilmiş alanlar (garanti, son bakım, doluluk) saklanmaz; view'da hesaplanır.

---

## 5. Tasarımın Uyarlanması

### 5.1 Mimari

```
WhatsApp ──► köprü (Node.js + Baileys) ──HTTP──► backend (Java 17, JDK HttpServer)
                                                   │  JDBC (HikariCP, ORM yok)
                                                   ▼
                                             PostgreSQL 17
                                                   ▲
Panel (tarayıcı) ──HTTP (Bearer oturum)────────────┘
```

- **Köprü DB'ye dokunmaz.** Mesajı `POST /bot/mesaj`'a bırakır; backend LLM'i ve
  araçları çalıştırır, cevabı döner.
- **Backend** bot ve panel uçlarını aynı süreçte sunar. Panel için ayrı,
  `NOINHERIT` bir login rolü kullanılır; her istek `SET LOCAL ROLE` ile
  yetkilendirilir.
- **Panel** aynı kökenden sunulur: CORS yok, oturum anahtarı başka kökene
  gitmez.

### 5.2 Yazılım, donanım ve VTYS ortamı

| Bileşen | Sürüm / seçim |
|---|---|
| İşletim sistemi (geliştirme) | macOS (Apple Silicon) |
| Java | OpenJDK 17, Maven Wrapper |
| PostgreSQL | 17 (Docker `postgres:17-alpine`) |
| Node.js | 22 (köprü) |
| Baileys | 7.0.0-rc13 |
| HTTP | JDK `com.sun.net.httpserver` (ek çatı yok) |
| JDBC | PostgreSQL JDBC + HikariCP |
| JSON | Jackson |
| Şifre | jBCrypt (cost 10) |
| Excel | fastexcel (tek yönlü üretim) |
| LLM | Mistral (demo: `deepseek-v4-1-flash-1017`) / Gemini (yedek) |

### 5.3 Tabloların oluşturulması

DDL, `db/` altında sayı önekli dosyalarla sırayla uygulanır:

| Aralık | İçerik |
|---|---|
| `010`–`100` | Şema, uzantılar, ortak tipler, 20 tablo |
| `150`–`210` | Randevu türleri, servis/garanti trigger'ları |
| `220` | Randevu doğrulama trigger'ı |
| `300`–`350` | View'lar ve maskeleme fonksiyonları |
| `400`–`430` | Roller, RLS, GRANT/REVOKE, bot kimliği |
| `440` | Müşteri ad/soyad NULL gevşetmesi + bot UPDATE |
| `450` | Mesaj idempotency (`kaynak_id`) |
| `460` | Randevu–araç sahipliği ve servis hazırlığı |
| `500` | 13 indeks |

Tablolar `GENERATED ALWAYS AS IDENTITY` birincil anahtar kullanır; silme yerine
durum/aktiflik tercih edilir.

### 5.4 View'lar ve maskeleme

- `v_rapor_randevu`, `v_rapor_musteri`: `fn_maskele_ad`, `fn_maskele_telefon`
  ile PII maskelenir; `rapor` rolü ham tabloları okuyamaz.
- `v_dolu_slot`: yalnızca `arac_vin`, `baslangic`, `bitis`; müşteri/çalışan
  bilgisi yok.
- `v_musteri_servis_durumu`: `fn_aktif_musteri_id()` ile yalnız konuşulan
  müşterinin satırları; masraf ve çalışan bilgisi yok (fail-closed).

### 5.5 Veri yükleme

`veri/uret.py` ile üretilen CSV'ler `veri/uretilen/` altına yazılır;
`scripts/veri-yukle.sh` tek transaction'da `\copy` ile yükler:

| Tablo | Satır |
|---|---:|
| `mesaj` | 216.782 |
| `servis_islem` | 139.005 |
| `servis_durum_gecmisi` | 134.549 |
| `randevu` | 77.961 |
| `servis_kaydi` | 32.989 |
| `musteri` | 25.339 |
| `stok_hareketi` | 23.804 |
| `arac` | 8.064 |
| Diğer 12 tablo | 2.940 |
| **Toplam** | **660.433** |

Ana işlem tablolarındaki satır sayısı **453.096**'dır (≥ 250.000 koşulu).
Kimlik sayaçları yükleme öncesi sıfırlanır; yükleme tek transaction olduğu için
kurala uymayan tek satır tüm işlemi geri alır. `460` trigger'ı DEFERRABLE olduğu
için randevular servis kayıtlarından önce yazılabilir; kural commit'te doğrulanır.

### 5.6 İndeksler

`db/500_indeksler.sql` 13 indeks tanımlar:

- `randevu`: şube+tarih, çalışan+tarih, müşteri, araç (kısmi), GiST EXCLUDE.
- `mesaj`: müşteri+zaman, kaynak id (kısmi UNIQUE).
- `servis_kaydi` / `servis_islem` / `servis_durum_gecmisi`: kayıt ve zaman.
- `stok_hareketi`: araç+zaman.
- `musteri`: telefon (UNIQUE zaten), kayıt zamanı.
- `v_dolu_slot` ve rapor sorguları için yardımcı indeksler.

Ölçüm: `docs/analiz/indeks-analizi.md`, `docs/analiz/sorgular.sql`.

### 5.7 Sorgu tasarımları ve maliyet analizi

Yedi analitik sorgu (en az 3 tablo JOIN, alt sorgu, GROUP BY/HAVING veya pencere
fonksiyonu) ve bir view ölçümü `EXPLAIN (ANALYZE, BUFFERS)` ile ölçüldü. Özet:

| Sorgu | Amaç | İndekssiz | İndeksli | Kazanç |
|---|---|---:|---:|---|
| 1 | Test sürüşü → satış dönüşümü | 14,92 ms | 8,52 ms | 1,75× |
| 2 | Şube/departman aylık performans | 3,04 ms | 0,35 ms | 8,7× |
| 3 | 216k mesajda müşteri geçmişi | 4,82 ms | 0,50 ms | 9,6× |
| 4 | Şube/sebep masraf kırılımı | 7,94 ms | 2,91 ms | 2,7× |
| 5 | Servis teslim gecikmesi | — | 22,44 ms | Hash Join |
| 6 | Garanti karşılama oranı | 111,40 ms | 108,81 ms | CPU-bound (LAG) |
| 7 | Erken garanti bozulması | — | 97,18 ms | Pencere fonksiyonu |
| 8 | Müşteri servis durumu view'ı | 416,88 ms | 0,58 ms | 722× |

Sorgu 8'in 722× kazancı, `v_musteri_servis_durumu` için `idx_randevu_musteri`
kullanımından gelir: 77.957 satırlık Seq Scan yerine Index Scan.

### 5.8 Roller, RLS ve güvenlik

- **Roller:** `admin`, `personel`, `bot`, `rapor`. Hiçbirinde DELETE yok.
- **RLS:** `musteri`, `randevu`, `mesaj`, `arac` üzerinde etkin. Bot yalnızca
  `app.musteri_telefon` ile eşleşen satırları görür; değişken yoksa hiçbir satır
  görünmez (fail-closed).
- **Panel:** `NOINHERIT` login rolü + her transaction'da `SET LOCAL ROLE
  personel|rapor`. Rol seçilmezse sorgu yetki hatası alır.
- **Kimlik:** Panelde bcrypt + bellek içi opak oturum; `Authorization: Bearer`.
  Girişte IP başına dakikada 60 deneme, kullanıcı adı başına 5 hata/1 dk kilidi,
  4 KB gövde sınırı; bcrypt bağlantı havuzu dışında çalışır. Her istekte
  `aktif_mi` yeniden denetlenir.
- **Bot:** `X-Bot-Token` (≥32 karakter) zorunlu; PII LLM'e gitmez.
- **Panel arayüzü:** Katı CSP, `nosniff`, yalnızca beyaz listedeki statik
  uzantılar; `..` ile classpath gezinmesi engellenir.
- **SQL:** Bütün sorgular `PreparedStatement`; `ORDER BY`/LIMIT parametreleri
  beyaz liste veya sayısal doğrulama ile.
- **Excel:** Tek yönlü, `rapor` rolü, maskeli view; ham ad/telefon sızmaz.

### 5.9 Transaction ve eşzamanlılık

- Her panel isteği tek transaction: iş biter → `commit`, hata → `rollback`.
- Randevu çakışması DB'de EXCLUDE ile; iki paralel istekten biri 201, diğeri 409.
- Aynı yeni telefonla eşzamanlı iki randevu: müşteri `INSERT … ON CONFLICT
  (telefon) DO UPDATE` ile tek satıra indirgenir; iki istek de 201 alır.
- Bot mesaj idempotency: `mesaj.kaynak_id` kısmi UNIQUE; aynı wamid ikinci kez
  işlenmez.
- Oturumlar bellekte; backend yeniden başlarsa düşer (bilinçli tasarım).

### 5.10 LLM ve WhatsApp köprüsü

- `LlmIstemci` arayüzü; `MistralIstemci` (OpenAI uyumlu) ve `GeminiIstemci`.
- Demo: `LLM_SAGLAYICI=mistral`, `MISTRAL_MODEL=deepseek-v4-1-flash-1017`.
- Araç döngüsü Java'da: model araç çağırır → backend kendi HTTP ucuna gider →
  sonuç modele döner. Müşteriye yalnızca nihai metin gider.
- Gemini adaptörü Gemma'nın `role:"function"` kısıtını ve `thought` parçalarını
  özel olarak işler; 429/5xx'te iki kez yeniden dener.
- Köprü Baileys ile bağlanır; mesajı backend'e iletir, cevabı gönderir. DB'ye
  erişmez.

### 5.11 Test stratejisi ve sonuçlar

Testler gerçek HTTP + gerçek PostgreSQL + gerçek JAR üzerinden koşar; manuel SQL
kanıt sayılmaz.

| Paket | Senaryo | Kapsam |
|---|---:|---|
| `scripts/test-db.sh` | 24 | Trigger, view, rol/RLS, müşteri izolasyonu, sahiplik |
| `scripts/test-bot-http.sh` | 198 | Token, kimlik, müsaitlik, stok, randevu, LLM döngüsü, idempotency, eşzamanlılık |
| `scripts/test-panel-http.sh` | 256 | Giriş/kilit/IP sınırı, oturum, rol yetkileri, DB hata çevrimi, eşzamanlılık, Excel PII, statik dosya |
| `backend/src/test` (JUnit) | 3 | Oturum süresi, hesap kilidi, IP penceresi (enjekte Clock) |
| **Toplam** | **481** | Hepsi geçiyor |

Ek olarak `scripts/sema-diyagram.sh` (tbls) şemayı, `docs/analiz` ise indeks
ölçümlerini üretir.

---

## 6. Uygulama Programı Tanıtımı ve Örnek Kullanım

### 6.1 Panel menüleri

| Menü | İşlev |
|---|---|
| Giriş | Kullanıcı adı/şifre; bcrypt + oturum |
| Bugünkü randevular | Şube/tür/durum filtresi; tamamlandı/gelmedi/iptal |
| Randevu ekle | Müşteri bul/ekle, tür/şube/çalışan/saat; sahiplik ve hazırlık denetimi |
| Araçlar | Stok/yolda/satıldı, VIN/plaka arama, garanti, hareketler |
| Servis kayıtları | Durum geçmişi, tahmini teslim, işlem/masraf, sigorta |
| Müşteriler | İletişim, araçlar, randevu geçmişi |
| Bot konuşmaları | Müşteri bazında mesaj geçmişi |
| Raporlar | Özet istatistikler + tek yönlü Excel |

### 6.2 Bot akışı (örnek)

1. Müşteri: “Merhaba, Ioniq 5 için test sürüşü randevusu almak istiyorum.”
2. Bot: Şehir/şube ve gün sorar; `GET /bot/slot` ile boş saatleri listeler.
3. Müşteri saati seçer; bot `POST /bot/randevu` ile kaydeder.
4. Onay mesajı: tarih, saat, şube, çalışan.
5. “Randevularım” → `GET /bot/randevu`; iptal → `POST …/iptal`.

Randevu kuralları modele bırakılmaz: model yalnızca aracı çağırır; DB kuralı
reddederse bot bunu kullanıcıya anlaşılır biçimde söyler.

### 6.3 API sözleşmeleri

- Bot: `docs/api/bot-sozlesmesi.md` — 8 uç.
- Panel: `docs/api/panel-sozlesmesi.md` — 19 uç.
- Ortak zarf: `{ "ok": true, "veri": … }` / `{ "ok": false, "hata": { … } }`.
- Panel hataları: `GIRIS_HATALI`, `COK_DENEME`, `OTURUM_YOK`, `GECERSIZ_PARAMETRE`,
  `SLOT_DOLU`, `ARAC_UYGUN_DEGIL`, `BULUNAMADI`, `SISTEM_HATASI` …

### 6.4 Çalıştırma

Yerel geliştirme:

```sh
# 1) Şema + veri
scripts/test-db.sh            # geçici PostgreSQL ile doğrulama
scripts/veri-yukle.sh         # sentetik veri (ayrı DB)

# 2) Backend
cd backend && ./mvnw package -DskipTests
scripts/backend-calistir.sh

# 3) Panel demosu (sentetik veri + demo hesapları)
scripts/panel-demo.sh
```

Köprü:

```sh
cd kopru && npm install && npm start   # QR ile WhatsApp eşleştirme
```

> **Not:** Docker Compose ile tek komut demo hedefi sonraki adımdır; bu raporda
> yerel betiklerle çalıştırma doğrulanmıştır.

### 6.5 Ekran görüntüleri

> **Şekil 3** — Panel giriş ekranı.
> **Şekil 4** — Bugünkü randevular ve filtreler.
> **Şekil 5** — Araç detayı ve garanti durumu.
> **Şekil 6** — Servis kaydı durum geçmişi ve masraf.
> **Şekil 7** — Rapor özeti ve Excel çıktısı.
> **Şekil 8** — WhatsApp bot konuşması.

*(Ekran görüntüleri demo provasında eklenecektir.)*

---

## 7. Sonuç

### 7.1 Elde edilenler

- 20 tablo, 7 view, 3 trigger ve 13 indeksten oluşan, BCNF'ye normalleştirilmiş
  şema; 660.433 satır sentetik veri.
- Bot API (8 uç), panel API (19 uç), WhatsApp köprüsü ve LLM araç döngüsü.
- Veritabanında garanti edilen iş kuralları: çakışma, mesai/yetkinlik, sahiplik,
  servis hazırlığı, garanti/ödeme kaynağı, rol/RLS.
- 481 otomatik senaryo; üç ayrı HTTP paketi ve zaman tabanlı birim testleri.
- Ölçülmüş indeks kazançları: 722×'e varan iyileşme; `EXPLAIN (ANALYZE, BUFFERS)`
  çıktıları tekrarlanabilir.

### 7.2 Sınırlar ve gelecek işler

- Panelden satış transaction'ı ve servis kaydı açma/teslim uçları kapsam dışı.
- Oturumlar bellekte; çok örnekli dağıtımda paylaşılan oturum deposu gerekir.
- Docker Compose ile tek komut demo henüz yok; yerel betikler kullanılıyor.
- Sistem promptu demo öncesi gözden geçirilecek.
- `personel` rolünün bazı tablolarda kolon bazlı yetkisi genişletilebilir
  (şu an tablo bazlı UPDATE).

### 7.3 Öğrenilenler

- İş kurallarını uygulama koduna değil veritabanına yazmak, yeni bir yazma yolu
  (panel) eklendiğinde bile tutarlılığı korur.
- DEFERRABLE constraint trigger, toplu veri yükleme sırası ile katı bütünlük
  arasındaki gerilimi çözer.
- `EXCLUDE` + `btree_gist`, çakışma denetimini yarış koşullarından bağımsız kılar.
- Gerçek HTTP üzerinden test etmek, “SQL'i elle çalıştırdım”dan çok daha güçlü
  kanıt üretir.

---

## 8. Referanslar

1. BIL372 Veritabanı Sistemleri, Proje Tanımı ve Ara Rapor (TOBB ETÜ, 2026).
2. PostgreSQL 17 Documentation — Constraints, Triggers, Row Security Policies,
   `EXPLAIN`.
3. PostgreSQL `btree_gist` extension.
4. JDK 17 `com.sun.net.httpserver` documentation.
5. HikariCP, Jackson, jBCrypt, fastexcel proje belgeleri.
6. Baileys (WhatsApp Web API) 7.0.0-rc13 belgeleri.
7. Mistral AI / Google Gemini API belgeleri.
8. Proje deposu: `github.com/huseyin-usta/mini-dealership`
   (`db/`, `backend/`, `panel/`, `kopru/`, `scripts/`, `docs/`).
