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
