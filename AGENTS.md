# Mini-Dealership — Handoff Notları

BIL372 Veritabanı Sistemleri grup projesi çalışma klasörü. Bu dosya yeni
session'lara ve ekip arkadaşına bağlam aktarımı içindir.

## Kaynak dokümanlar (öncelik sırasıyla)

1. `dokumanlar/Proje_Tanımı.pdf` — hocanın proje rehberi (gereksinimlerin kaynağı)
2. `dokumanlar/BIL372_MiniDealership_AraRapor_duzenlenmis.pdf` — teslim edilmiş
   ara rapor (19 Ekim 2026). **Official tasarım dokümanı; çelişki olursa PDF kazanır.**
3. `mini-dealership.md` — spec; PDF'lerle uyumlu tutulur (ör. mesai kuralı PDF'e
   göre düzeltildi). Değiştirmeden önce kullanıcıya sor.

## Durum (21 Kasım 2026 itibarıyla)

- GitHub reposu: **github.com/huseyin-usta/mini-dealership** (public, `main`).
  Commit yazarı: `h.usta@etu.edu.tr` (gt-arc maili KULLANILMAZ).
  Collaborator: `aslyagm` (Şevda Yağmur ASAL, write yetkisi).
- İlerleme: **Veritabanı katmanı tamamen tamamlandı** (`db/010`–`500`):
  - **20/20 tablo DDL ve doğrulama trigger'ları** (`210_trg_servis_garanti.sql`, `220_trg_randevu_dogrula.sql`).
  - **View'lar** (`300`–`350`, `430`): maskeleme fonksiyonları, müşteri son randevu,
    servis durumu, garanti durumu, maskeli rapor view'ları, bot için PII'siz `v_dolu_slot`,
    bot için müşteriye özel masrafsız `v_musteri_servis_durumu` (`430`, `fn_aktif_musteri_id()` ile süzülür).
  - **Roller + RLS + GRANT/REVOKE** (`400`–`420`): admin/personel/bot/rapor
    NOLOGIN rolleri; bot kimliği `SET LOCAL app.musteri_telefon` ile (fail-closed);
    hiçbir role DELETE yok. Doğrulama trigger'ları `420`'de SECURITY DEFINER yapıldı.
  - **Sentetik veri üretici** (`veri/uret.py`, `scripts/veri-yukle.sh`): ana işlem
    tablolarında 453.096 satır (toplam 650k+ satır) üretilip doğrulandı.
  - **Analitik sorgular ve indeks analizi** (`db/500_indeksler.sql`,
    `docs/analiz/sorgular.sql`, `docs/analiz/indeks-analizi.md`): 7 sorgu ve 13 indeks
    `EXPLAIN (ANALYZE, BUFFERS)` ile ölçüldü.
- **Bot API (backend) — tamamlandı.** `docs/api/bot-sozlesmesi.md`: `GET /bot/sube`,
  `GET /bot/slot`, `GET /bot/arac`, `POST /bot/randevu`, `GET /bot/randevu`,
  `POST /bot/randevu/{id}/iptal`, `POST /bot/musteri` ve `POST /bot/mesaj`
  (LLM giriş noktası). Köprü↔backend arasında `X-Bot-Token` (BOT_TOKEN, ≥32 karakter)
  zorunlu; varsayılan bind `127.0.0.1` (`BIND_ADRESI`).
- **Panel API + arayüz (Şevda) — tamamlandı (25 Kasım).** `docs/api/panel-sozlesmesi.md`:
  giriş/çıkış (bcrypt + bellek içi oturum, kaba kuvvet kilidi), katalog, randevu
  (liste/ekle/durum), araç, servis (liste/detay/durum/işlem), müşteri + bot konuşmaları,
  rapor özeti ve tek yönlü Excel (`rapor` rolü, maskeli). Backend panel için ayrı bir
  **NOINHERIT** login rolüyle bağlanır (`PANEL_DB_USER`/`PANEL_DB_PASS`, `personel` +
  `rapor` üyesi; her rota `SET LOCAL ROLE`). Ortam değişkeni yoksa panel kapalı, bot
  etkilenmez. Arayüz `panel/` (düz HTML/JS) JAR'a gömülü, backend `/` adresinden sunar.
  Yerel deneme: `scripts/panel-demo.sh` (sentetik veri + demo hesapları).
  Kapsam dışı (backend sahibine): satış transaction'ı, servis açma/teslim.
- Test: `scripts/test-db.sh` 23 senaryo (trigger, view, rol/RLS, müşteri izolasyonu);
  `scripts/test-bot-http.sh` 195 HTTP senaryosu (gerçek Postgres + gerçek JAR + sahte Gemini
  stub'ı; token/kimlik/müsaitlik/stok/randevu/LLM döngüsü/idempotency/hatalar, eşzamanlılık
  dahil); `scripts/test-panel-http.sh` 236 HTTP senaryosu (gerçek panel rolü; giriş/kilit/
  oturum, rol yetkileri, DB kural hatalarının çevrimi, eşzamanlılık, Excel'de PII
  sızıntısı, statik dosya güvenliği). Hepsi geçiyor.
- Şema görselleştirme: `scripts/sema-diyagram.sh` (tbls + geçici Docker Postgres)
  → `docs/sema/` çıktısı güncel şemayla (tablolar, view'lar, trigger'lar, indeksler) yenilendi.
- Kalan işler: WhatsApp köprüsü entegrasyonu, Docker Compose (panel login rolü ve
  `PANEL_DB_*` dahil), satış transaction ucu, son rapor.
- **Açık takip (DB invariant):** `fn_randevu_dogrula` trigger'ı TESLIMAT/bakım/
  servise girişte aracın müşteriye ait olduğunu **denetlemiyor**; tek savunma
  Java tarafı (`RandevuHandler` + `SlotHandler`). DDL mühürlü olduğu için bu turda
  dokunulmadı; trigger'a sahiplik + şube kuralı eklenmesi final rapor öncesi
  değerlendirilecek (mevcut 195 test API'yi koruyor).
- **LLM backend'de** (`POST /bot/mesaj`): Gemini + araç döngüsü Java'da; araçlar kendi
  HTTP uçlarına `KENDI_URL` üzerinden çağrılır. `GEMINI_API_KEY` yoksa yalnız bu uç 503
  döner. Sistem promptu `backend/src/main/resources/sistem-promptu.md`.
  Idempotency `mesaj.kaynak_id` (`db/450`) ile; köprü wamid göndermeli.
  **LLM sağlayıcısı değiştirilebilir** (`LLM_SAGLAYICI=gemini|mistral`, `LlmIstemci`):
  - **Demo: `mistral` + `deepseek-v4-1-flash-1017`** (Mistral platformu, OpenAI uyumlu).
    Google ücretsiz katmanı 503 "high demand" ve 429 kota verdi; demo için güvenilir değil.
  - Yedek: `gemini` + `gemma-4-26b-a4b-it`.
  İki adaptör de 429/5xx'te iki kez yeniden dener. Gemini adaptörü Gemma'nın
  `role:"function"` kısıtını (araç sonuçları `user` turunda) ve `thought`
  parçalarını (müşteriye gitmez) özel olarak ele alır.
- **`musteri.ad/soyad` artık NULL olabilir** (`db/440_musteri_bilgisi.sql`):
  kimlik telefondur, isim sonradan öğrenilir. Bu dosya ayrıca bot'a
  `UPDATE (ad, soyad)` yetkisi ve RLS UPDATE politikası ekler. `v_rapor_randevu`
  bu nedenle `concat_ws` + `nullif` ile NULL-güvenli hale getirildi.
- Takvim: son rapor **3 Aralık 2026**, dönem sonunda demo.
- Görev dağılımı: `mini-dealership.md`'deki taslak + bu dosyadaki "İş bölümü" bölümü.

## Kilit mimari kararlar (değiştirme, tartışmak için sor)

- **4 parça:** WhatsApp köprüsü (Node.js+Baileys) · backend (Java, JDBC,
  ORM yok) · panel (HTML/JS) · PostgreSQL
- **SQL elle yazılır** — Hibernate/JPA yasak; dersin amacı bu
- **DB rolleri:** admin / personel / bot / rapor — GRANT/REVOKE ile yetki,
  hiçbir role DELETE yok (iptal = durum değişikliği, soft olarak)
- **RLS:** bot yalnızca konuştuğu müşterinin satırlarını görür; müşteri PII'si
  LLM'e ulaşmaz, rapor rolü maskeli view kullanır
- **Excel raporu tek yönlü** (DB → Excel). Excel'den geri yazım yok, import yok
- **Garanti saklanmaz, hesaplanır** — trigger yalnızca "garanti ödemesi"
  girilmesini engeller; bakım aralığı sabit (bkz. aşağıda)
- **Veri:** ana işlem tablolarında toplam ≥ 250.000 satır, script ile üretilir
  (Mockaroo 1.000 satır limitli, yetersiz), üretilen veri kısıtlara uymak zorunda
- **Normalizasyon BCNF'ye kadar**; EER'de kalıtım, çoka-çok, türetilmiş
  nitelikler spec'in "EER'de doğal adaylar" bölümünde
- Demo hedefi: tek komut (Docker Compose) ayağa kalkmalı

### 31 Ekim DDL turunda eklenen kararlar

- **Resmi tasarım = ara rapor (PDF).** Mesai tüm şubelerde ortak (şube bazlı
  değil); periyodik bakım aralığı sabit: 1 yıl / 15.000 km (kolon yok, trigger
  sabiti kullanır); bayi tek markalı (marka kolonu yok)
- **Silmeli design yok:** ayrılan çalışan `aktif_mi=false` (istihdam durumu,
  online durum değil). FK silme kuralları raporda geçenler hariç default
  (NO ACTION): model→versiyon→özellik ve servis kaydına bağlı kayıtlar CASCADE
- **Para kolonları bigint tam sayı (TL)** — kuruş hassasiyeti yok, float yok
- **PII minimum:** TC/kimlik numarası tutulmaz; `calisan_id` yeterli
- **Stil:** PK'lar `GENERATED ALWAYS AS IDENTITY`; `db/` dosyaları sayı önekli
  (10'ar adım, araya 015 gibi dosya girebilir); durum kolonları varchar+CHECK
  (boolean değil); aracın kilometresi tutulmaz — servis kayıtlarından izlenir
- **Karar verildi:** bayi tek markalı olduğu için markanın bütün araçları bayi
  ağı üzerinden satılır; servise gelen her araç sistemde kayıtlıdır. Eski
  "bizden alınmamış araç servise ilk geldiğinde kaydedilir" kuralı spec'ten
  çıkarıldı, ayrı bir araç-kayıt akışı yok

## Referans repo (salt-okunur, DOKUNMA)

`~/TOBB` — github.com/huseyin-usta/TOBB. **Private repo**; 31 Ekim'de diskten
silinmişti, gh ile yeniden klonlandı. Eski B2B projesi (KOBİ AI Platform).
Mimari özeti: `~/TOBB/CLAUDE.md` — okumadan port işine başlama.

Yollar `poc/whatsapp/` altında (handoff'un eski hali yanlış yerden veriyordu).

**Port edilecek (WhatsApp köprüsü + PII desenleri):**

- `poc/whatsapp/index.js` — Baileys 7.0.0-rc13 kurulum deseni, pairing,
  JID→telefon normalizasyonu, mesaj döngüsü (642 satır)
- `poc/whatsapp/lib/tools.js` — config-driven tool framework + PII masking
  (841 satır): `maskRows`, `visibility:"private"`, `mask_fields`,
  `REDACTED="[gizli]"` sentinel, **fail-closed** (caller yoksa her şey maskeli),
  membership-oracle guard (maskeli alan aranamaz), `redactKeys` ile tool log
  redaksiyonu
- `poc/whatsapp/lib/capacity.js` + `lib/pricing.js` — soft-rules mantığı
- **Kimlik deseni:** caller = auth'lı WhatsApp JID'sinden (`ctx.callerPhone`),
  LLM argümanından ASLA — bizde bot rolü + RLS ile aynı ilke
- **Overbook gate / check→write TTL:** write-lock altında kapasite kontrolü,
  TOCTOU kapanışı — bizde son savunma DB'deki EXCLUDE kısıtı; bot bu deseni
  transaction içinde kullanır
- Test yapısı: `node --test tests/*.test.js` (470 test), tmp temizliği `after()`

**Alınmayacak:** `lib/gdrive*.js`, `lib/excel*.js`, `lib/sqlite-adapter.js`,
`lib/storage.js`, `lib/store.js` (multi-tenant SQLite katmanı), Google OAuth,
`dashboard/`, `homepage/`, `poc/cv-analyzer`

- Spec'e göre köprü DB'ye hiç dokunmaz: mesajı backend'e (Java) iletir,
  cevabı müşteriye gönderir. Hard invariant'lar TOBB'da koddaydı; bizde
  PostgreSQL'de (EXCLUDE, RLS, roller) — köprü port edilirken bu ayrım korunur.

## Ortam

- macOS, zsh. Docker Desktop kurulu (daemon gerektiğinde `open -a Docker` ile
  başlatılır). tbls: `brew install tbls`.
- GitHub CLI bağlı: `huseyin-usta` (HTTPS, keyring).
  Email `h.usta@etu.edu.tr` olduğu doğrulanamadı — token'da `user` scope yok;
  gerekiyorsa `gh auth refresh -h github.com -s user`
- Collaborator ekleme: `gh api -X PUT repos/huseyin-usta/mini-dealership/collaborators/{user}`

## İş bölümü (geliştirme düzeni)

Sahiplik ikiye ayrıldı; `mini-dealership.md`'deki "Görev dağılımı" bölümü
değiştirilmedi (o örnek taslaktı). Gerçek iş bölümü final raporda commit
geçmişinden çıkarılacak.

- **Hüseyin — backend tarafı:** API sözleşmesi, Java backend (JDBC, bot mantığı,
  panel API'leri), WhatsApp köprüsü, transaction yönetimi, Docker Compose.
- **Şevda — panel tarafı:** panel (HTML/JS) + panel menüleri, Excel raporu.
- **Ortak ve bitti:** EER/şema/DDL, view'lar, roller/RLS, analitik sorgular ve
  indeks analizi, veri üretici.

Sıra: API sözleşmesi → backend iskeleti → WhatsApp köprüsü → panel API'leri →
Docker Compose. Panel, sözleşme dondurulduktan sonra mock ile paralel başlayabilir.

## Kullanıcı ile çalışma

- İletişim Türkçe. Yanıtlar kısa ve öz olsun; gevezelik yok. Kod, commit ve
  doküman normal dilde (dokümanlar Türkçe — spec Türkçe)
- Kullanıcı her teknik kararı biliyor; gerekçesiz öneri sunma, net trade-off göster
- **Review akışı:** dosyalar parça parça yazılır (agent yazar → kullanıcı
  review eder → onaydan sonra commit). Tablo başına commit yok; DDL mantıklı
  bloklar halinde, doküman değişiklikleri ayrı commit

### Kalite kuralları (ihlal edilemez)

1. **Test etmeden commit yok.** Yazılan her davranış, commit'ten önce kanıtlanır.
2. **Manuel test yok.** Testler, gerçek kullanıcının eriştiği arayüzden geçmeli:
   bot için HTTP endpoint'e gerçek istek (LLM/köprü gibi), panel için HTTP,
   DB davranışı için aynı rol ve aynı oturum değişkenleriyle bağlantı.
   "SQL'i ben elle çalıştırdım, çalışıyor" kanıt sayılmaz.
3. **Testler derin ve anlamlı olmalı.** Mutlu yol testi yeterli değil; sınır
   değerler, yetki reddi, fail-closed davranışı, eşzamanlılık/çakışma,
   yanlış girdi ve regresyon senaryoları kapsanır. Test, implementasyon
   detayını değil sözleşmedeki davranışı doğrular.
4. **Bir adım bitmeden ve review edilmeden sonrakine geçilmez.** Bitmiş sayılmak
   için: sözleşme + kod + testler + canlı doğrulama. Küçük görevler
   `code-reviewer` subagent'ı ile (deepseek modeli) review edilir; kapsamlı
   turda güçlü model kullanılır. Review bulgusu kapatılmadan adım kapanmaz.

- Geliştirme sırası (spec'ten): EER + şema → veri üretici → sorgular/indeks
  analizi → Java backend → panel → köprü entegrasyonu. Yeni işe spec'te
  karşılığı yoksa önce spec'e ekle
- ECC standartları geçerli: TDD (RED→GREEN), güvenlik (secrets env'de),
  immutability. Ama ders projesi — pragmatizm önce gelir, aşırı mühendislik yok
