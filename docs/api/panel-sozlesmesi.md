# Panel API Sözleşmesi (TASLAK)

Panel (HTML/JS, tarayıcıda çalışır) ile Java backend arasındaki HTTP sözleşmesi.

> **Durum: taslak.** Panel tarafının ihtiyaç listesidir; backend sahibiyle
> (Hüseyin) üzerinde anlaşılıp dondurulduktan sonra panel bu sözleşmeye karşı
> mock ile geliştirilir. Açık kararlar en sonda listelenmiştir.

Menüler spec'teki "Panel menüleri" bölümünden gelir. Panel veritabanına
**hiç dokunmaz**; bütün kısıtlar PostgreSQL'de (EXCLUDE, trigger, CHECK) kalır,
backend DB hatasını aşağıdaki hata kodlarına çevirir.

## Genel kurallar

### Kimlik ve oturum

Panel tarayıcıda çalıştığı için içine gömülen hiçbir sır gizli kalamaz. Bu yüzden
panelin kimliği paylaşılan bir token değil, **çalışanın kendi girişidir**:

1. `POST /panel/giris` kullanıcı adı + şifre alır. Backend `fn_panel_giris()` ile
   (yalnızca `aktif_mi = true` çalışanlar) hash'i okur, bcrypt ile doğrular.
2. Başarılıysa rastgele, opak bir oturum anahtarı döner (en az 128 bit). Backend
   oturumu bellekte tutar: `calisan_id`, `sube_id`, `departman`, son kullanma.
3. Sonraki her istekte: `Authorization: Bearer <oturum>`.
4. Oturum **8 saat** sonra veya `POST /panel/cikis` ile düşer. Backend yeniden
   başlarsa tüm oturumlar düşer (kalıcı oturum tablosu yok).

Hatalı/eksik/süresi dolmuş oturum → `401 OTURUM_YOK`; hiçbir sorgu çalışmaz.
Yanlış kullanıcı adı ile yanlış şifre **aynı** hatayı döner
(`401 GIRIS_HATALI`) — hangi kullanıcı adlarının var olduğu sızmasın.

### Veritabanı rolü

| Uç grubu | DB rolü | Neden |
|---|---|---|
| `/panel/*` (raporlar hariç) | `personel` | Operasyon: tam ad/telefon görür, randevu/servis yazar, DELETE yok |
| `/panel/rapor/*` | `rapor` | Yalnızca maskeli view'lar (`v_rapor_*`); Excel'e PII çıkmaz |

Backend her istekte transaction açıp `SET LOCAL ROLE` ile rolü seçer. Panel
kullanıcısının yetkisi DB'de de sınırlıdır: backend'de bir hata olsa bile
`personel` rolü silme yapamaz, şifre hash'ini okuyamaz.

### Yanıt zarfı ve hatalar

Bot sözleşmesindeki zarf aynen kullanılır (`ok`, `veri`, `hata.kod`,
`hata.mesaj`, `hata.detay`). `kullaniciya_goster` panelde kullanılmaz:
panel `mesaj`ı her zaman çalışana gösterir.

Ortak hata kodları:

| Kod | HTTP | Anlamı |
|---|---|---|
| `OTURUM_YOK` | 401 | `Authorization` eksik, oturum bilinmiyor veya süresi dolmuş |
| `GIRIS_HATALI` | 401 | Kullanıcı adı veya şifre yanlış (ya da çalışan pasif) |
| `GECERSIZ_PARAMETRE` | 400 | Eksik/bozuk alan, gövde JSON değil, tekrarlanan query parametresi |
| `BULUNAMADI` | 404 | İstenen kayıt (randevu, araç, müşteri, servis) yok |
| `YOL_YOK` | 404 | Sözleşmede olmayan yol |
| `YONTEM_DESTEKLENMIYOR` | 405 | Yanlış HTTP yöntemi (`Allow` başlığı döner) |
| `SISTEM_HATASI` | 500 | Beklenmedik hata; detay loglanır, panele dönmez |

### Listeleme

Liste uçları `limit` (varsayılan 50, en fazla 200) ve `sayfa` (1'den başlar)
alır, yanıtta `toplam` döner. İstisna: mesajlar zamana göre geriye doğru
sayfalanır (`once` imleci), çünkü 216k satırlık tabloda OFFSET pahalıdır.

Tarih: `YYYY-MM-DD`; zaman: `YYYY-MM-DDTHH:MM` (Europe/Istanbul, saat dilimsiz).
Para: tam sayı TL.

## Endpoint'ler

| # | Endpoint | Menü | Rol |
|---|---|---|---|
| 1 | `POST /panel/giris`, `POST /panel/cikis` | Giriş | — |
| 2 | `GET /panel/katalog` | (açılır listeler) | personel |
| 3 | `GET /panel/randevu` | Bugünkü randevular | personel |
| 4 | `POST /panel/randevu` | Randevu ekle | personel |
| 5 | `POST /panel/randevu/{id}/durum` | Bugünkü randevular | personel |
| 6 | `GET /panel/arac`, `GET /panel/arac/{vin}` | Araçlar | personel |
| 7 | `GET /panel/servis`, `GET /panel/servis/{id}` | Servis kayıtları | personel |
| 8 | `POST /panel/servis/{id}/durum`, `POST /panel/servis/{id}/islem` | Servis kayıtları | personel |
| 9 | `GET /panel/musteri`, `GET /panel/musteri/{id}` | Müşteriler | personel |
| 10 | `GET /panel/musteri/{id}/mesaj` | Bot konuşmaları | personel |
| 11 | `GET /panel/rapor/ozet` | Raporlar | rapor |
| 12 | `GET /panel/rapor/randevu.xlsx` | Raporlar (Excel) | rapor |

---

## 1. Giriş / çıkış

`POST /panel/giris`

```json
{ "kullanici_adi": "ayilmaz", "sifre": "..." }
```

`200 OK`:

```json
{ "ok": true, "veri": {
    "oturum": "c2b7…",
    "son_kullanma": "2026-11-21T18:30",
    "calisan": { "calisan_id": 12, "ad": "Ayşe", "soyad": "Yılmaz",
                 "sube_id": 1, "departman": "SATIS" } } }
```

`POST /panel/cikis` — gövde yok, oturumu düşürür, her zaman `200`.

## 2. `GET /panel/katalog`

Açılır listeler için tek seferde: şubeler, randevu türleri (süre, departman),
aktif çalışanlar (şube, departman, yetkinlikler), modeller. Panel girişte bir kez
çeker.

## 3. `GET /panel/randevu` — Bugünkü randevular

| Parametre | Zorunlu | Açıklama |
|---|---|---|
| `tarih` | ❌ | Varsayılan bugün |
| `sube_id` | ❌ | Varsayılan oturumdaki çalışanın şubesi |
| `tur_kodu`, `durum`, `calisan_id` | ❌ | Filtre |

Satır: `randevu_id, baslangic, bitis, durum, kaynak, tur_kodu, tur_adi,
calisan (ad soyad), musteri_id, musteri (ad soyad), telefon, arac_vin, plaka,
model_adi, notlar`. Sıralama: `baslangic`.

İndeks: `idx_randevu_sube_baslangic`.

## 4. `POST /panel/randevu` — Randevu ekle

Şubeye gelen veya telefonla arayan müşteri için. `kaynak = 'PANEL'`.

| Alan | Zorunlu | Açıklama |
|---|---|---|
| `telefon` | ✅ | E.164. Müşteri yoksa oluşturulur (`ad`, `soyad` o zaman zorunlu) |
| `ad`, `soyad` | ❌/✅ | Yeni müşteri için zorunlu |
| `sube_id`, `tur_kodu`, `baslangic` | ✅ | `baslangic`: `YYYY-MM-DDTHH:MM` |
| `calisan_id` | ❌ | Verilmezse backend uygun çalışanı atar (bot ile aynı kural) |
| `arac_vin` | ❌ | Araç gerektiren türde verilmezse bot ile aynı atama kuralı |
| `notlar` | ❌ | |

Botla fark: 21 günlük üst sınır yok, çalışan elle seçilebilir. Kontroller
(mesai, tür saat penceresi, yetkinlik, çakışma) DB trigger'ları ve EXCLUDE
kısıtlarında olduğu için **aynen geçerlidir**.

`201 Created` → oluşan randevu satırı (3'teki biçim).

Hatalar: `GECMIS_TARIH 400`, `GECERSIZ_SAAT 400` (mesai/tür penceresi dışı),
`SLOT_DOLU 409` (`detay.sebep`: `CALISAN_DOLU` | `ARAC_DOLU` | `MUSTERI_DOLU` —
hangi EXCLUDE kısıtına takıldığı), `CALISAN_UYGUN_DEGIL 409` (elle seçilen
çalışan; `220_trg_randevu_dogrula`'dan, `detay.sebep`: `PASIF` | `BASKA_SUBE` |
`DEPARTMAN` | `YETKINLIK_YOK`), `ARAC_UYGUN_DEGIL 409` (test sürüşü aracı
şubede `STOKTA` değil, yoldaki aracın teslimi varıştan önce),
`BULUNAMADI 404` (şube/tür/çalışan/araç).

## 5. `POST /panel/randevu/{id}/durum`

```json
{ "durum": "TAMAMLANDI" }
```

İzinli geçişler: `PLANLANDI → TAMAMLANDI | GELMEDI | IPTAL`. Diğerleri
`409 GECERSIZ_GECIS` (ör. iptal edilmiş randevuyu yeniden açmak — trigger zaten
engelliyor).

> **Satış akışı** (araç `SATILDI` + stok hareketi + randevu `TAMAMLANDI`, tek
> transaction) ayrı bir uçtur ve transaction sahibi Hüseyin'dir; burada
> yalnızca durum değişikliği var. Bkz. açık kararlar.

## 6. Araçlar

`GET /panel/arac`

| Parametre | Açıklama |
|---|---|
| `sube_id` | Varsayılan oturumdaki şube |
| `durum` | `STOKTA`, `YOLDA`, `SATILDI` |
| `ara` | VIN veya plaka (tam ya da önek eşleşme) |
| `model_id` | Filtre |

Satır: `vin, plaka, model_adi, paket_adi, renk, durum, tahmini_varis_tarihi, sube_id`.

`GET /panel/arac/{vin}` — detay:

- araç + versiyon özellikleri (`versiyon_ozellik`)
- garanti: `v_arac_garanti_durumu` satırı (`garanti_durumu`, `garanti_bitis`,
  `sonraki_bakim_son_tarih`, `sonraki_bakim_son_km`, …) — yalnızca satılmış araçta
- stok hareketleri (zaman sırasıyla)
- servis kayıtları özeti (`v_servis_durumu`)

> Not: `v_arac_garanti_durumu` tek araç için ~135 ms sürüyor
> (`docs/analiz/indeks-analizi.md` §7). Panel için kabul edilebilir; view
> düzeltilirse bu uç kendiliğinden hızlanır.

## 7. Servis kayıtları

`GET /panel/servis` — `v_servis_durumu` üzerinden.

| Parametre | Açıklama |
|---|---|
| `sube_id` | Varsayılan oturumdaki şube |
| `acik` | `true`: `kapandi_mi = false` |
| `gecikti` | `true`: `gecikti_mi = true` |
| `ara` | VIN veya plaka |

Satır: `servis_kaydi_id, arac_vin, plaka, model_adi, musteri, sebep, son_durum,
son_durum_zamani, tahmini_teslim_tarihi, kalan_gun, gecikti_mi, toplam_masraf`.

`GET /panel/servis/{id}` — detay: kayıt + `servis_durum_gecmisi` (zaman
sırasıyla) + `servis_islem` satırları + masraf kırılımı (`musteri_payi`,
`garanti_payi`, `sigorta_payi`) + sigorta bilgisi.

## 8. Servis güncelleme

`POST /panel/servis/{id}/durum` — durum geçmişine **yeni satır ekler**
(geçmiş değiştirilmez; `personel` rolünde bu tabloda yalnızca INSERT var).

```json
{ "durum": "PARCA_BEKLENIYOR", "aciklama": "Fren diski sipariş edildi",
  "tahmini_teslim_tarihi": "2026-11-28" }
```

`tahmini_teslim_tarihi` verilirse servis kaydında güncellenir (aynı transaction).

`POST /panel/servis/{id}/islem`

```json
{ "islem_adi": "Fren diski değişimi", "ucret": 4500,
  "odeme_kaynagi": "GARANTI", "aciklama": null }
```

Hatalar (`210_trg_servis_garanti` trigger'ından çevrilir):

- `ODEME_KAYNAGI_GECERSIZ 409` — servis sebebine uymayan ödeme kaynağı
  (bakım yalnızca müşteri; kaza müşteri/sigorta; arıza müşteri/garanti).
- `GARANTI_GECERSIZ 409` — garanti uygulanamaz; `detay.sebep`: `SATIS_YOK` |
  `KM_ASILDI` | `SURE_DOLDU` | `BAKIM_AKSATILDI`. Panel bu durumda formu
  "müşteri öder" seçeneğine çevirmeyi önerir.
- `KAPALI_KAYIT 409` — kapanmış servis kaydına işlem/durum eklenemez
  (backend kuralı; DB'de kısıt yok).

> Servis kaydı **açma** (`SERVIS_GIRIS` randevusundan) ve **teslim**
> (`SERVIS_TESLIM`) de panelden yapılacak; kuralları bot tarafındaki
> SERVIS_TESLIM akışıyla ortak olduğu için Hüseyin'le birlikte eklenecek.

## 9. Müşteriler

`GET /panel/musteri?ara=` — telefon (önek) veya ad/soyad (içerir) ile arama.
Satır: `musteri_id, ad, soyad, telefon, kayit_zamani, son_randevu`
(`v_musteri_son_randevu`).

`GET /panel/musteri/{id}` — iletişim bilgileri + randevu geçmişi (yeniden
eskiye, iptaller dahil, durumuyla) + sahip olduğu araçlar.

## 10. `GET /panel/musteri/{id}/mesaj` — Bot konuşmaları

| Parametre | Açıklama |
|---|---|
| `once` | Bu `mesaj_id`'den eski mesajlar (imleç); yoksa en yeniler |
| `limit` | Varsayılan 50, en fazla 200 |

Satır: `mesaj_id, yon (GELEN/GIDEN), zaman, icerik`. Yeniden eskiye.
Yanıtta `sonraki_once` (daha eski mesaj yoksa `null`).

İndeks: `idx_mesaj_musteri_zaman` (`musteri_id, zaman DESC`).

Salt-okunur: `personel` rolünün `mesaj` tablosunda yazma yetkisi yok.

---

## Açık kararlar (backend sahibiyle konuşulacak)

1. **Oturum mu, `PANEL_TOKEN` mı?** Bot sözleşmesi panelin kendi token'ını
   (`PANEL_TOKEN`) alacağını söylüyor. Panel tarayıcıda çalıştığı için paylaşılan
   bir token gizli kalamaz; bu taslak bunun yerine çalışan girişiyle oturum
   öneriyor. Alternatif: panel kendi küçük sunucusundan servis edilir ve token'ı
   o sunucu ekler — bir bileşen daha demek.
2. **Excel'i kim üretir?** Taslak: backend (Java, Apache POI) — `rapor` rolüyle
   maskeleme DB'de garanti. Alternatif: panel JS'te (SheetJS) üretir; o zaman veri
   `personel` rolüyle gelir ve maskeleme panel koduna kalır. Ders gereksinimi
   (maskeli rapor rolü) açısından backend daha doğru, ama backend'e bağımlılık
   ekliyor.
3. **Şube kısıtı:** `personel` RLS politikası tüm şubeleri gösteriyor (`USING (true)`).
   Taslakta şube yalnızca varsayılan filtre. Çalışan yalnızca kendi şubesini mi
   görmeli? Görmeliyse RLS'e `sube_id` koşulu eklenir (DB değişikliği).
4. **Satış akışı ucu** (`POST /panel/satis`): spec'teki transaction örneği; ucun
   biçimi transaction sahibine bırakıldı.
5. **Servis açma/teslim uçları:** bot tarafındaki `SERVIS_TESLIM` kurallarıyla
   ortak; ayrı bölüm olarak eklenecek.
6. **Admin ekranı yok:** `admin` rolü şema sahibi (migration); panelde çalışan
   ekleme/pasifleştirme menüsü spec'te yok. Gerekirse sonradan eklenir.
