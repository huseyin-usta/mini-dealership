# Mini-Dealership — Handoff Notları

BIL372 Veritabanı Sistemleri grup projesi çalışma klasörü. Bu dosya yeni
session'lara ve ekip arkadaşına bağlam aktarımı içindir.

## Kaynak dokümanlar (öncelik sırasıyla)

1. `dokumanlar/Proje_Tanımı.pdf` — hocanın proje rehberi (gereksinimlerin kaynağı)
2. `dokumanlar/BIL372_MiniDealership_AraRapor_duzenlenmis.pdf` — teslim edilmiş
   ara rapor (19 Ekim 2026). **Official tasarım dokümanı; çelişki olursa PDF kazanır.**
3. `mini-dealership.md` — spec; PDF'lerle uyumlu tutulur (ör. mesai kuralı PDF'e
   göre düzeltildi). Değiştirmeden önce kullanıcıya sor.

## Durum (16 Kasım 2026 itibarıyla)

- GitHub reposu: **github.com/huseyin-usta/mini-dealership** (public, `main`).
  Commit yazarı: `h.usta@etu.edu.tr` (gt-arc maili KULLANILMAZ).
  Collaborator: `aslyagm` (Şevda Yağmur ASAL, write yetkisi).
- İlerleme: **Veritabanı katmanı tamamen tamamlandı** (`db/010`–`500`):
  - **20/20 tablo DDL ve doğrulama trigger'ları** (`210_trg_servis_garanti.sql`, `220_trg_randevu_dogrula.sql`).
  - **View'lar** (`300`–`350`): maskeleme fonksiyonları, müşteri son randevu,
    servis durumu, garanti durumu, maskeli rapor view'ları, bot için PII'siz `v_dolu_slot`.
  - **Roller + RLS + GRANT/REVOKE** (`400`–`420`): admin/personel/bot/rapor
    NOLOGIN rolleri; bot kimliği `SET LOCAL app.musteri_telefon` ile (fail-closed);
    hiçbir role DELETE yok. Doğrulama trigger'ları `420`'de SECURITY DEFINER yapıldı.
  - **Sentetik veri üretici** (`veri/uret.py`, `scripts/veri-yukle.sh`): ana işlem
    tablolarında 453.096 satır (toplam 650k+ satır) üretilip doğrulandı.
  - **Analitik sorgular ve indeks analizi** (`db/500_indeksler.sql`,
    `docs/analiz/sorgular.sql`, `docs/analiz/indeks-analizi.md`): 7 sorgu ve 11 indeks
    `EXPLAIN (ANALYZE, BUFFERS)` ile ölçüldü.
- Test: `scripts/test-db.sh` 22 senaryo (trigger, view, rol/RLS, indekslerle), hepsi geçiyor.
- Şema görselleştirme: `scripts/sema-diyagram.sh` (tbls + geçici Docker Postgres)
  → `docs/sema/` çıktısı güncel şemayla (tablolar, view'lar, trigger'lar, indeksler) yenilendi.
- Kalan işler: Java backend (JDBC, ORM yok), panel (HTML/JS), WhatsApp köprüsü, Docker Compose.
- Takvim: son rapor **3 Aralık 2026**, dönem sonunda demo.
- Görev dağılımı: spec'in "Görev dağılımı" bölümünde.

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
- Geliştirme sırası (spec'ten): EER + şema → veri üretici → sorgular/indeks
  analizi → Java backend → panel → köprü entegrasyonu. Yeni işe spec'te
  karşılığı yoksa önce spec'e ekle
- ECC standartları geçerli: TDD (RED→GREEN), güvenlik (secrets env'de),
  immutability. Ama ders projesi — pragmatizm önce gelir, aşırı mühendislik yok
