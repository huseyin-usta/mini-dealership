# Panel API Sözleşmesi

Panel (HTML/JS, tarayıcıda çalışır) ile Java backend arasındaki HTTP sözleşmesi.

> **Durum: kararlar kesinleşti (25 Kasım 2026).** Panel ve panel uçları Şevda'ya
> devredildi; kararlar en sondaki "Kararlar" bölümündedir. Satış akışı ve
> servis açma/teslim uçları bu sözleşmenin kapsamı dışındadır.

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
4. Oturum **8 saat** sonra (`PANEL_OTURUM_SANIYE`, varsayılan 28800) veya
   `POST /panel/cikis` ile düşer. Backend yeniden başlarsa tüm oturumlar düşer
   (kalıcı oturum tablosu yok).

Hatalı/eksik/süresi dolmuş oturum → `401 OTURUM_YOK`; hiçbir sorgu çalışmaz.
Oturum, yol ve yöntem kontrolünden **önce** yapılır: oturumsuz istek tanımsız
bir yola da 401 alır, yolların varlığı sızmaz.
Yanlış kullanıcı adı ile yanlış şifre **aynı** hatayı döner
(`401 GIRIS_HATALI`) — hangi kullanıcı adlarının var olduğu sızmasın.
Bir kullanıcı adında art arda 5 hatalı girişten sonra o ad 1 dakika kilitlenir
(`429 COK_DENEME`; doğru şifre de reddedilir, diğer kullanıcılar etkilenmez).

Bütün yanıtlar `Cache-Control: no-store` taşır (müşteri bilgisi tarayıcı
önbelleğinde kalmasın).

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
| `COK_DENEME` | 429 | Kullanıcı adı geçici olarak kilitli (art arda hatalı giriş) |
| `GECERSIZ_PARAMETRE` | 400 | Eksik/bozuk alan, gövde JSON değil, tekrarlanan veya **bilinmeyen** query parametresi/gövde alanı (yazım hatası filtresiz sonuç vermesin) |
| `GECERSIZ_TARIH` | 400 | Tarih `YYYY-MM-DD` değil ya da takvimde yok (ör. 31 Kasım) |
| `KURAL_IHLALI` | 409 | DB trigger'ının reddettiği, aşağıda ayrıca kodlanmamış bir iş kuralı; `mesaj` trigger'ın Türkçe açıklamasıdır |
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

Açılır listeler için tek seferde: `subeler` (`sube_id, sehir, ad`), `turler`
(`tur_kodu, ad, sure_dakika, departman, arac_gerekli`), `calisanlar` (yalnızca
aktif; `calisan_id, ad, soyad, sube_id, departman, yetkinlikler` — süresi
dolmamış yetkinlik kodları), `modeller` (`model_id, ad`). Panel girişte bir kez
çeker. Şifre hash'i hiçbir zaman dönmez.

## 3. `GET /panel/randevu` — Bugünkü randevular

| Parametre | Zorunlu | Açıklama |
|---|---|---|
| `tarih` | ❌ | Varsayılan bugün |
| `sube_id` | ❌ | Varsayılan oturumdaki çalışanın şubesi |
| `tur_kodu`, `durum`, `calisan_id` | ❌ | Filtre |
| `limit`, `sayfa` | ❌ | Sayfalama |

Yanıt: `{ tarih, sube_id, toplam, randevular: [...] }`.
Satır: `randevu_id, baslangic, bitis, durum, kaynak, tur_kodu, tur_adi, sube_id,
calisan_id, calisan (ad soyad), musteri_id, musteri (ad soyad; bilinmiyorsa
null), telefon, arac_vin, plaka, model_adi, notlar`. Sıralama: `baslangic`.

İndeks: `idx_randevu_sube_baslangic`.

## 4. `POST /panel/randevu` — Randevu ekle

Şubeye gelen veya telefonla arayan müşteri için. `kaynak = 'PANEL'`.

| Alan | Zorunlu | Açıklama |
|---|---|---|
| `telefon` | ✅ | E.164. Müşteri yoksa oluşturulur (`ad`, `soyad` o zaman zorunlu) |
| `ad`, `soyad` | ❌/✅ | Yeni müşteri için zorunlu |
| `sube_id`, `tur_kodu`, `baslangic` | ✅ | `baslangic`: `YYYY-MM-DDTHH:MM` |
| `calisan_id` | ✅ | Çalışanı personel seçer (katalogdan); uygunluğu DB trigger'ı denetler |
| `arac_vin` | ❌/✅ | Araç gerektiren türde (`TEST_SURUSU`, `TESLIMAT`, `PERIYODIK_BAKIM`, `SERVIS_GIRIS`, `SERVIS_TESLIM`) zorunlu, diğerlerinde verilmez |
| `notlar` | ❌ | |

Botla fark: 21 günlük üst sınır yok; çalışan ve araç otomatik atanmaz, personel
seçer (bot'un atama kuralları müşteri adına konuşurken gerekli, şubedeki personel
kimi atadığını bilir). Kontroller
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
`409 GECERSIZ_GECIS` (`detay.mevcut_durum` ile; ör. iptal edilmiş randevuyu
yeniden açmak). Başlamamış randevu `TAMAMLANDI`/`GELMEDI` yapılamaz →
`409 ZAMANI_GELMEDI`; iptal her zaman serbesttir. Satır `FOR UPDATE` ile
kilitlenir. Yanıt: güncellenmiş randevu satırı (3'teki biçim). İptal edilen
saat, EXCLUDE kısıtı iptalleri saymadığı için yeniden verilebilir.

> **Satış akışı** (araç `SATILDI` + stok hareketi + randevu `TAMAMLANDI`, tek
> transaction) ayrı bir uçtur ve transaction sahibi Hüseyin'dir; burada
> yalnızca durum değişikliği var.

## 6. Araçlar

`GET /panel/arac`

| Parametre | Açıklama |
|---|---|
| `sube_id` | Varsayılan oturumdaki şube |
| `durum` | `STOKTA`, `YOLDA`, `SATILDI` |
| `ara` | VIN veya plaka öneki (büyük/küçük harf ve boşluk önemsiz, en fazla 17 karakter). `sube_id` verilmezse **tüm şubelerde** aranır |
| `model_id` | Filtre |
| `limit`, `sayfa` | Sayfalama |

`%` ve `_` joker değildir (önek `left()` ile karşılaştırılır, LIKE yok).

Satır: `vin, plaka, model_id, model_adi, paket_adi, model_yili, renk, durum,
tahmini_varis_tarihi, sube_id, sube_adi, liste_fiyati`.

`{vin}` 17 harf/rakam olmalı, aksi halde `404 YOL_YOK`; küçük harf kabul edilir.
Detayda ayrıca `sahip` (satılmışsa `musteri_id, ad_soyad, telefon`, değilse
`null`); satılmamış araçta `garanti` `null`.

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
| `ara` | VIN veya plaka öneki (araçlardaki gibi; `sube_id` verilmezse tüm şubeler) |
| `limit`, `sayfa` | Sayfalama |

Sıralama: açık kayıtlar önce, sonra tahmini teslim tarihi (boşlar sonda).

Satır: `servis_kaydi_id, sube_id, arac_vin, plaka, model_adi, musteri_id,
musteri, sebep, giris_zamani, giris_kilometresi, son_durum, son_durum_zamani,
tahmini_teslim_tarihi, kalan_gun, kapandi_mi, gecikti_mi, toplam_masraf`.

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

`tahmini_teslim_tarihi` verilirse servis kaydında güncellenir (aynı transaction);
geçmiş tarih `400 GECMIS_TARIH`. Durum `TAMAMLANDI` eklenirse kayıt kapanır.

Her iki güncelleme ucu `201 Created` ile servis detayını (7'deki biçim) döner;
servis kaydı `FOR UPDATE` ile kilitlenir.

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
> (`SERVIS_TESLIM`) bu sözleşmenin kapsamı dışındadır; kuralları bot tarafındaki
> SERVIS_TESLIM akışıyla ortak olduğu için backend sahibiyle birlikte eklenecek.

## 9. Müşteriler

`GET /panel/musteri?ara=` — `ara` `+` veya rakamla başlıyorsa telefon öneki
(boşluklar atılır), değilse ad/soyad içinde geçen metin (büyük/küçük harf
önemsiz, joker yok); en fazla 64 karakter. `limit`, `sayfa` ile sayfalanır,
yeni kayıtlar önce. Satır: `musteri_id, ad, soyad, telefon, kayit_zamani,
son_randevu_zamani, son_randevu_turu, son_randevu_durumu`
(`v_musteri_son_randevu`). Adı henüz öğrenilmemiş müşteride `ad`/`soyad` `null`.

`GET /panel/musteri/{id}` — iletişim bilgileri + randevu geçmişi (yeniden
eskiye, iptaller dahil, durumuyla) + sahip olduğu araçlar.

## 10. `GET /panel/musteri/{id}/mesaj` — Bot konuşmaları

| Parametre | Açıklama |
|---|---|
| `once` | Bu `mesaj_id`'den eski mesajlar (imleç); yoksa en yeniler |
| `limit` | Varsayılan 50, en fazla 200 |

Satır: `mesaj_id, yon (GELEN/GIDEN), zaman, icerik`. Yeniden eskiye;
sıralama ve imleç `(zaman, mesaj_id)` çiftidir (`mesaj_id` zamanla aynı sırada
olmak zorunda değil). Yanıtta `sonraki_once` (daha eski mesaj yoksa `null`).
`once` bu müşterinin bir mesajı değilse `400 GECERSIZ_PARAMETRE`.

İndeks: `idx_mesaj_musteri_zaman` (`musteri_id, zaman DESC`).

Salt-okunur: `personel` rolünün `mesaj` tablosunda yazma yetkisi yok.

## 11. `GET /panel/rapor/ozet` — İstatistikler

`baslangic`, `bitis` (tarih, zorunlu, iki uç dahil), `sube_id` (ops.). Rol:
`rapor`. Aralık en fazla 366 gün; daha uzunsa `400 ARALIK_COK_GENIS`.

Dönen bloklar (hepsi yalnızca `v_rapor_randevu`'dan):

| Blok | İçerik |
|---|---|
| `ozet` | `toplam, planlandi, tamamlandi, iptal, gelmedi, iptal_yuzde, gelmeme_yuzde` (gelmeme oranı TAMAMLANDI+GELMEDI üzerinden; boş aralıkta oranlar `null`) |
| `sube_doluluk` | `sube_id, sehir, sube_adi, randevu, tamamlanan, sira` — iptaller sayılmaz, `RANK()` |
| `tur_dagilimi` | `tur_kodu, tur_adi, departman, adet` |
| `kaynak_dagilimi` | `kaynak, adet, yuzde` (window `sum() OVER ()`) |
| `test_surusu_donusum` | `model_adi, test_surusu, satisa_donen` |

Dönüşüm: tamamlanmış test sürüşünden sonraki 60 gün içinde aynı müşteriye
aynı modelden (iptal edilmemiş) teslimat randevusu verildiyse satışa dönmüş
sayılır. `rapor` rolü stok tablosunu göremediği için satışın izi teslimat
randevusudur (`docs/analiz/sorgular.sql` Sorgu 1'in rapor rolüyle uyumlu hali).

## 12. `GET /panel/rapor/randevu.xlsx` — Excel dışa aktarım

Aynı parametreler. Yanıt bir `.xlsx` dosyasıdır
(`Content-Disposition: attachment; filename="randevular_2026-11-01_2026-11-30.xlsx"`),
zarf yok. Hata olursa normal JSON zarfı döner.

- **Tek yönlü:** yalnızca DB → Excel. Excel'den içe aktarım ucu **yok**.
- Kaynak `v_rapor_randevu`, rol `rapor`: müşteri adı ve telefonu **maskeli**
  çıkar. Excel dosyası paylaşılabilir bir belge olduğu için PII içermemesi
  DB rolüyle garanti edilir, panel koduna güvenilmez.
- Sayfalar: "Randevular" (satır başına bir randevu; başlık satırı sabit,
  zamanlar Excel tarih hücresi) ve "Özet" (11'deki bloklar).
- En fazla 100.000 satır ve 366 gün; aşılırsa `400 ARALIK_COK_GENIS`.
  Satırlar DB'den akışla okunur (fetch size 1000).
- Dosya adı: `randevular_<baslangic>_<bitis>[_sube<id>].xlsx`.
- Üretim: fastexcel kütüphanesi (yalnızca yazar; okuma/içe aktarma kodu yok).

---

## Kararlar

1. **Kimlik: çalışan girişi + oturum** (`PANEL_TOKEN` yok). Panel tarayıcıda
   çalıştığı için paylaşılan bir token gizli kalamaz. Bot sözleşmesindeki
   `PANEL_TOKEN` notunun yerini bu sözleşmedeki oturum alır.
2. **Veritabanı bağlantısı:** backend panel için ayrı bir login rolüyle bağlanır
   (`PANEL_DB_USER` / `PANEL_DB_PASS`). Bu rol `NOINHERIT` ve `personel`,
   `rapor` rollerinin üyesidir: `SET LOCAL ROLE` yapılmadan **hiçbir tabloyu
   okuyamaz** (fail-closed). Ortam değişkenleri yoksa panel uçları ve arayüz
   açılmaz, bot uçları etkilenmez.
3. **Excel'i backend üretir** (fastexcel, `rapor` rolü). Maskeleme DB rolüyle
   garanti edilir, panel koduna kalmaz.
4. **Şube:** tüm personel tüm şubeleri görebilir (RLS `USING (true)` olduğu gibi
   kalır); oturumdaki şube yalnızca varsayılan filtredir. Gerçek bayide
   çalışanlar şubeler arası araç/randevu sorar.
5. **Arayüz:** panel dosyaları (`panel/`) backend JAR'ına gömülür ve aynı
   adresten (`/`) servis edilir; ayrı sunucu ve CORS yok.
6. **Kapsam dışı:** satış akışı (`POST /panel/satis`, transaction), servis
   açma/teslim ve admin ekranları (çalışan ekleme/pasifleştirme).
