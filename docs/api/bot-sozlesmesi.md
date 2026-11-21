# Bot API Sözleşmesi

WhatsApp köprüsü (Node.js) ile Java backend arasındaki HTTP sözleşmesi.

Köprü veritabanına **hiç dokunmaz**; bütün iş mantığı backend'de, bütün kısıtlar
PostgreSQL'de. Köprü yalnızca mesajı taşır.

## Genel kurallar

### Kimlik: iki ayrı katman

Her istekte **iki** başlık zorunludur ve birbirine karıştırılmamalıdır:

```
X-Bot-Token: <paylaşılan sır>          ← "istek gerçekten köprüden mi geliyor"
X-Musteri-Telefon: +905321234567       ← "hangi müşteri adına" (RLS için)
```

**Köprü kimliği (`X-Bot-Token`).** Köprü ile backend arasında paylaşılan sırdır;
`BOT_TOKEN` ortam değişkeninden okunur ve varsayılanı **yoktur** — eksikse
uygulama başlamaz. Müşteriye, LLM'e ve panele ulaşmaz; yalnızca köprü ekler.
Karşılaştırma sabit zamanlıdır. Hatalı/eksik token → `401 YETKISIZ_ISTEK`;
bu durumda **hiçbir sorgu çalıştırılmaz**.

**Müşteri kimliği (`X-Musteri-Telefon`).** Köprü bu değeri WhatsApp JID'sinden
çıkarır (`resolveSender`); LLM argümanlarından **asla**. Backend bunu transaction
içinde `SET LOCAL app.musteri_telefon` değişkenine yazar; satır bazlı güvenlik
(RLS) devreye girer ve bot yalnızca o müşterinin satırlarını görür. Değişken yoksa
RLS hiçbir satır göstermez (fail-closed).

**Ağ katmanı.** Backend varsayılan olarak yalnızca `127.0.0.1` dinler
(`BIND_ADRESI`). Docker'da köprü ayrı konteynerde olduğu için `0.0.0.0` verilir;
o durumda port dışarı **publish edilmez** ve token korunur. Panel API'si
eklendiğinde panel kendi token'ını (`PANEL_TOKEN`) alacaktır — iki bileşen birbirinin
yetkisiyle konuşamaz.

### Yanıt zarfı

Başarılı:

```json
{ "ok": true, "veri": { ... } }
```

Hatalı:

```json
{
  "ok": false,
  "hata": {
    "kod": "MAKINE_KODU",
    "mesaj": "Türkçe, LLM'in doğrudan kullanabileceği metin",
    "kullaniciya_goster": true,
    "detay": { ... }
  }
}
```

| Alan | Tip | Açıklama |
|---|---|---|
| `kod` | string | Makine tarafından okunur, LLM buna göre dallanır |
| `mesaj` | string | Türkçe; LLM'in müşteriye aktarabileceği metin |
| `kullaniciya_goster` | boolean | `false` ise LLM bu hatayı müşteriye **söylemez**, kendi içinde alternatif arar |
| `detay` | object | Opsiyonel; LLM'in karar vermesine yardım eden ek veri |

`kullaniciya_goster` bir **sinyaldir**, sistem promptu ise **yönlendirmedir**;
ikisi birlikte kullanılır.

### Hata kodlarının sınıfları

| Sınıf | Örnek | Davranış |
|---|---|---|
| Kullanıcıya gösterilir | `SEHIRDE_SUBE_YOK`, `SLOT_DOLU`, `ARAC_YOK`, `RANDEVU_YOK`, `GECMIS_TARIH` | LLM müşteriyle diyalog kurar, alternatif önerir |
| LLM içi | `YETKI_YOK` | LLM müşteriye söylemez, başka çalışan/şube/gün arar |
| Sistem | `SISTEM_HATASI` | Tüm beklenmedik hatalar (HTTP 500); LLM genel özür mesajı verir |

Her endpoint'te ayrıca dönebilen ortak kodlar:

| Kod | HTTP | Anlamı |
|---|---|---|
| `YETKISIZ_ISTEK` | 401 | `X-Bot-Token` eksik veya yanlış (istek köprüden gelmiyor) |
| `KIMLIK_YOK` | 401 | `X-Musteri-Telefon` eksik veya E.164 biçiminde değil |
| `YONTEM_DESTEKLENMIYOR` | 405 | Endpoint'in beklediği HTTP yöntemi dışında istek (`Allow` başlığı döner) |
| `YOL_YOK` | 404 | Sözleşmede tanımlı olmayan yol (ör. `/bot/sube/ekstra`) |

Query parametreleri bir kez gönderilir; aynı ad iki kez gelirse
`400 GECERSIZ_PARAMETRE` döner (hangi değerin kullanıldığı belirsiz kalmasın).

Endpoint yolları tam eşleşir; sondaki eğik çizgi kabul edilir (`/bot/sube/`),
daha derin yollar reddedilir (`/bot/sube/ekstra` → `404 YOL_YOK`).

### Sağlık kontrolü

`GET /saglik` ve `HEAD /saglik` kimlik doğrulaması istemez (konteyner sağlık
kontrolü içindir) ve yalnızca `ok` / `db erişilemiyor` döndürür. Diğer yöntemler
`405`, tanımsız alt yollar `404` alır.

## Endpoint'ler

| # | Endpoint | LLM tool adı | Amaç |
|---|---|---|---|
| 1 | `GET /bot/sube` | `sube_listele` | Şehir ve şube listesi |
| 2 | `GET /bot/slot` | `musait_slotlar` | Müsait randevu saatleri ve o saatteki imkanlar |
| 3 | `GET /bot/arac` | `arac_listele` | Stoktaki/yoldaki araçlar veya müşterinin araçları |
| 4 | `POST /bot/randevu` | `randevu_olustur` | Randevu oluşturma |
| 5 | `GET /bot/randevu` | `randevularim` | Müşterinin randevuları: yaklaşan + geçmiş + son bakım |
| 6 | `POST /bot/randevu/{id}/iptal` | `randevu_iptal` | Randevu iptali |
| 7 | `POST /bot/mesaj` | — | Köprünün giriş noktası (LLM tool'u değil) |
| 8 | `POST /bot/musteri` | `musteri_bilgisi` | Müşterinin ad/soyadını yazar (öğrendikçe) |

---

## 1. `GET /bot/sube`

Hizmet verilen şehirleri veya bir şehirdeki şubeleri listeler.

### İstek

```
GET /bot/sube
GET /bot/sube?sehir=Ankara
```

| Header | Zorunlu | Değer |
|---|---|---|
| `X-Musteri-Telefon` | ✅ | `+905321234567` |

| Query | Tip | Zorunlu | Açıklama |
|---|---|---|---|
| `sehir` | string | ❌ | Şehir adı. Verilmezse yalnızca şehir adları döner |

Şehir adı **tam eşleşme** ile aranır (`Ankara` ✅, `ankara` ❌). LLM şehir
listesini parametresiz çağrıyla öğrenip doğru yazımı kopyalar; yanlış yazımda
hata yanıtındaki `detay.mevcut_sehirler` alanından düzeltir.

### Başarılı yanıt — `200 OK`

**Şehir verilmeden:**

```json
{
  "ok": true,
  "veri": {
    "sehirler": ["Ankara", "Antalya", "Bursa", "İstanbul", "İzmir"]
  }
}
```

**Şehir verilerek:**

```json
{
  "ok": true,
  "veri": {
    "sehir": "Ankara",
    "subeler": [
      { "sube_id": 1, "ad": "Çankaya" },
      { "sube_id": 2, "ad": "Yenimahalle" }
    ]
  }
}
```

### Hata yanıtları

**`404 Not Found` — `SEHIRDE_SUBE_YOK`**

```json
{
  "ok": false,
  "hata": {
    "kod": "SEHIRDE_SUBE_YOK",
    "mesaj": "Bu şehirde şubemiz bulunmuyor.",
    "kullaniciya_goster": true,
    "detay": {
      "mevcut_sehirler": ["Ankara", "Antalya", "Bursa", "İstanbul", "İzmir"]
    }
  }
}
```

LLM: "Maalesef Kars'ta şubemiz yok. Ankara, Antalya, Bursa, İstanbul ve
İzmir'de hizmet veriyoruz." gibi bir yanıt üretir.

**`500 Internal Server Error` — `SISTEM_HATASI`**

```json
{
  "ok": false,
  "hata": {
    "kod": "SISTEM_HATASI",
    "mesaj": "Şu an hizmet veremiyorum.",
    "kullaniciya_goster": true
  }
}
```

### Veritabanı

```sql
-- Parametresiz: şehir listesi
SELECT DISTINCT sehir FROM sube ORDER BY sehir;

-- Şehir verilerek: o şehirdeki şubeler
SELECT sube_id, ad FROM sube WHERE sehir = $1 ORDER BY ad;
```

- Tablo: `sube` (`sube_id`, `sehir`, `ad`)
- Rol: `bot` — `sube` tablosunda `SELECT` yetkisi var
- RLS: `sube` tablosunda RLS yok (şube bilgisi kişisel veri değil)

### LLM tool tanımı (köprüde)

```json
{
  "name": "sube_listele",
  "description": "Hizmet verilen şubeleri listeler. Parametre verilmezse yalnızca şehir adlarını döner (müşteri hangi şehirlerde şubemiz olduğunu sorduğunda kullan). Şehir adı verilirse o şehirdeki şubeleri döner; o şehirde şube yoksa hata döner. Şubelere ulaşmak için şehir adı mutlaka girilmelidir.",
  "parameters": {
    "type": "object",
    "properties": {
      "sehir": {
        "type": "string",
        "description": "Şehir adı (ör. Ankara). Boş bırakılırsa yalnızca şehir adları listelenir."
      }
    }
  }
}
```

---

## 2. `GET /bot/slot`

Bir şube, randevu türü ve gün için **müsait saat dilimlerini** ve her dilimdeki
**imkanları** (müsait çalışan sayısı, müsait araçlar) döner.

### İmkan modeli

Bir saat dilimi ancak o türün gerektirdiği bütün kaynaklar hazırsa müsait sayılır:

| Tür | Çalışan | Araç (kaynak tüketir) |
|---|---|---|
| `TEST_SURUSU` | yetkinlik şartı var | o şubede `STOKTA` ve o saat boş |
| `TESLIMAT` | departman: `SATIS` | müşterinin **kendi** `SATILDI` aracı, o şubede |
| `PERIYODIK_BAKIM`, `SERVIS_GIRIS` | departman: `SERVIS` | müşterinin **kendi** `SATILDI` aracı (şube serbest) |
| `SERVIS_TESLIM` | departman: `SERVIS` | müşterinin açık ve **teslime hazır** servis kaydındaki araç |
| `ARAC_INCELEME`, `SATIN_ALIM` | departman: `SATIS` | gerekmez |

Araç gerektiren beş tür, **araç kaynağını tüketir**: aynı araç aynı anda iki
randevuda olamaz (`randevu` tablosundaki EXCLUDE kısıtı). Bu yüzden slot
hesabı aracın o saatte boş olmasını da arar; aksi halde önerilen saat
kaydedilirken veritabanı reddederdi.

**Yoldaki araçların sahibi yoktur** (`arac` tablosundaki
`(durum = 'SATILDI') = (musteri_id IS NOT NULL)` kısıtı). Bu nedenle
"müşterinin yoldaki aracı" diye bir kavram yoktur; teslimat yalnızca
müşterinin satın aldığı araç için verilir.

Sorgu bu nedenle **sol birleştirme** ile kurulur: araç gerektirmeyen türlerde araç
tarafı boş kalır ve slot elenmez.

Hesaplama sırası:

1. `tur_saat` ve `mesai` kesişiminden o güne ait **olası dilimler** üretilir
2. Bu dilimlerden o tür için **uygun ve boş** çalışanlar bulunur
3. Araç gerektiren türlerde **uygun ve boş** araçlar bulunur
4. Çalışanı olmayan (veya araç gerekiyorsa aracı da olmayan) dilimler elenir

### İstek

```
GET /bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=2026-11-20
GET /bot/slot?sube_id=1&tur_kodu=TEST_SURUSU&tarih=2026-11-20&arac_vin=VIN12345678901234
```

| Header | Zorunlu | Değer |
|---|---|---|
| `X-Musteri-Telefon` | ✅ | `+905321234567` |

| Query | Tip | Zorunlu | Açıklama |
|---|---|---|---|
| `sube_id` | integer | ✅ | Şube kimliği |
| `tur_kodu` | string | ✅ | `randevu_turu.tur_kodu` |
| `tarih` | date | ✅ | `YYYY-MM-DD`; bugünden itibaren en fazla 21 gün ileri |
| `arac_vin` | string | ❌ | Verilirse yalnızca o araç boş olan dilimler döner. Yalnızca araç gerektiren beş türde kullanılabilir; `ARAC_INCELEME`/`SATIN_ALIM` türlerinde 400 döner. Küçük harf kabul edilir, büyük harfe çevrilir |

### Başarılı yanıt — `200 OK`

```json
{
  "ok": true,
  "veri": {
    "tarih": "2026-11-20",
    "tur_kodu": "TEST_SURUSU",
    "bilgi": "Test Sürüşü: Pazartesi-Cumartesi 10:00-12:00, 14:00-16:00",
    "slotlar": [
      {
        "baslangic": "10:00",
        "bitis": "11:00",
        "musait_calisan_sayisi": 2,
        "musait_araclar": [
          { "vin": "VIN12345678901234", "model": "Ioniq 5", "paket": "Advance", "renk": "Beyaz" },
          { "vin": "VIN56789012345678", "model": "Tucson",  "paket": "Elite",   "renk": "Gri" }
        ]
      },
      {
        "baslangic": "14:00",
        "bitis": "15:00",
        "musait_calisan_sayisi": 1,
        "musait_araclar": [
          { "vin": "VIN12345678901234", "model": "Ioniq 5", "paket": "Advance", "renk": "Beyaz" }
        ]
      }
    ]
  }
}
```

- `slotlar` **yalnızca müsait** dilimleri içerir; dolu dilim listeye girmez.
- `bilgi` **her zaman** döner; boş listede de LLM'in neden boş olduğunu anlamasını sağlar.
- `musait_araclar` yalnızca araç gerektiren türlerde doludur; diğerlerinde `[]`.
- Çalışan kimliği ve adı **dönmez**; atamayı backend yapar (bkz. `POST /bot/randevu`).

Boş liste örneği:

```json
{
  "ok": true,
  "veri": {
    "tarih": "2026-11-22",
    "tur_kodu": "TEST_SURUSU",
    "bilgi": "Test Sürüşü: Pazartesi-Cumartesi 10:00-12:00, 14:00-16:00",
    "slotlar": []
  }
}
```

### Hata yanıtları

| Kod | HTTP | `kullaniciya_goster` | Koşul |
|---|---|---|---|
| `SUBE_YOK` | 404 | true | `sube_id` bulunamadı |
| `TUR_YOK` | 404 | true | `tur_kodu` bulunamadı |
| `GECERSIZ_TARIH` | 400 | true | Tarih `YYYY-MM-DD` biçiminde değil |
| `GECMIS_TARIH` | 400 | true | Tarih bugünden önce |
| `COK_UZAK_TARIH` | 400 | true | Bugünden 21 günden fazla ileri |
| `ARAC_YOK` | 404 | true | `arac_vin` verildi; bakım/servise girişte araç müşterinin kayıtlı araçları arasında değil |
| `ARAC_STOKTA_YOK` | 404 | true | `arac_vin` verildi; test sürüşü için araç o şubede `STOKTA` değil, ya da teslimat için araç müşterinin kendi satılmış aracı değil |
| `ARAC_SERVISTE_DEGIL` | 404 | true | `arac_vin` verildi; servisten teslim için açık servis kaydı yok |
| `SERVIS_TESLIM_HAZIR_DEGIL` | 409 | true | Araç serviste ama teslime hazır değil; `detay` son durumu ve tahmini teslim tarihini taşır |
| `GECERSIZ_PARAMETRE` | 400 | true | Parametre kullanımı geçersiz: zorunlu parametre eksik/sayısal değil, `arac_vin` araç gerektirmeyen bir türde verilmiş, ya da `kapsam=benim` + `arac_vin` birlikte |

**Not:** O gün o tür için hiç saat tanımlı değilse (hafta sonu, mesai dışı veya
türün penceresi yok) bu bir hata değildir: `slotlar: []` ve açıklayıcı `bilgi`
döner. LLM alternatif gün önerir.

`SERVIS_TESLIM_HAZIR_DEGIL` örneği:

```json
{
  "ok": false,
  "hata": {
    "kod": "SERVIS_TESLIM_HAZIR_DEGIL",
    "mesaj": "Aracınız serviste; mevcut durumu: Parça bekleniyor.",
    "kullaniciya_goster": true,
    "detay": {
      "son_durum": "PARCA_BEKLENIYOR",
      "tahmini_teslim_tarihi": "2026-11-25"
    }
  }
}
```

### Veritabanı

Aşağıdaki sorgu doğrulanmıştır (bkz. `scripts/test-bot-http.sh`). Parametreler:
`$1` tarih, `$2` tur_kodu, `$3` sube_id, `$4` arac_vin (NULL olabilir).

```sql
WITH olası_ham AS (
    -- 1) O güne ait olası dilimler: tur_saat penceresi içinde süre kadar adım
    SELECT gs AS baslangic,
           gs + (rt.sure_dakika * interval '1 minute') AS bitis
      FROM randevu_turu rt
      JOIN tur_saat ts ON ts.tur_kodu = rt.tur_kodu
      JOIN mesai    m  ON m.gun = ts.gun
     CROSS JOIN generate_series(
           $1::date + ts.baslangic,
           $1::date + ts.bitis - (rt.sure_dakika * interval '1 minute'),
           (rt.sure_dakika * interval '1 minute')
     ) AS gs
     WHERE rt.tur_kodu = $2
       AND extract(isodow FROM $1::date) = ts.gun
       AND m.acilis <= ts.baslangic AND ts.bitis <= m.kapanis
),
olası AS (SELECT DISTINCT baslangic, bitis FROM olası_ham),  -- örtüşen pencereler
tur AS (
    SELECT rt.tur_kodu, rt.yetkinlik_id, rt.departman,
           rt.tur_kodu IN ('TEST_SURUSU','TESLIMAT','SERVIS_TESLIM',
                           'PERIYODIK_BAKIM','SERVIS_GIRIS') AS arac_gerekli
      FROM randevu_turu rt WHERE rt.tur_kodu = $2
),
uygun_calisan AS (
    -- Yetkinliğin randevu günü geçerli olması şart (trigger ile aynı kural)
    SELECT c.calisan_id
      FROM calisan c, tur t
     WHERE c.sube_id = $3 AND c.aktif_mi AND c.departman = t.departman
       AND (t.yetkinlik_id IS NULL OR EXISTS (
             SELECT 1 FROM calisan_yetkinlik cy
              WHERE cy.calisan_id = c.calisan_id
                AND cy.yetkinlik_id = t.yetkinlik_id
                AND cy.verilis_tarihi <= $1::date
                AND (cy.bitis_tarihi IS NULL OR cy.bitis_tarihi >= $1::date)))
),
uygun_arac AS (
    -- Test sürüşü: şubede stokta
    SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
      FROM arac a JOIN versiyon v ON v.versiyon_id = a.versiyon_id
      JOIN model md ON md.model_id = v.model_id
     WHERE (SELECT tur_kodu FROM tur) = 'TEST_SURUSU'
       AND a.sube_id = $3 AND a.durum = 'STOKTA'
    UNION ALL
    -- Yeni araç teslimi: müşterinin kendi satılmış aracı, o şubede
    SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
      FROM arac a JOIN versiyon v ON v.versiyon_id = a.versiyon_id
      JOIN model md ON md.model_id = v.model_id
     WHERE (SELECT tur_kodu FROM tur) = 'TESLIMAT'
       AND a.sube_id = $3 AND a.durum = 'SATILDI'
       AND a.musteri_id = fn_aktif_musteri_id()
    UNION ALL
    -- Servisten teslim: bu şubede açık ve TESLİME HAZIR kayıt
    SELECT DISTINCT a.vin, v.paket_adi, md.ad AS model, a.renk
      FROM arac a JOIN versiyon v ON v.versiyon_id = a.versiyon_id
      JOIN model md ON md.model_id = v.model_id
      JOIN v_musteri_servis_durumu msd ON msd.arac_vin = a.vin
     WHERE (SELECT tur_kodu FROM tur) = 'SERVIS_TESLIM'
       AND msd.kapandi_mi = false AND msd.son_durum = 'TESLIME_HAZIR'
       AND msd.sube_id = $3
    UNION ALL
    -- Bakım / servise giriş: müşterinin kendi aracı (şube serbest)
    SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
      FROM arac a JOIN versiyon v ON v.versiyon_id = a.versiyon_id
      JOIN model md ON md.model_id = v.model_id
     WHERE (SELECT tur_kodu FROM tur) IN ('PERIYODIK_BAKIM','SERVIS_GIRIS')
       AND a.durum = 'SATILDI' AND a.musteri_id = fn_aktif_musteri_id()
)
SELECT o.baslangic::time, o.bitis::time,
       (SELECT count(*) FROM uygun_calisan uc
         WHERE NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                            WHERE d.calisan_id = uc.calisan_id
                              AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))),
       CASE WHEN t.arac_gerekli THEN
         COALESCE((SELECT json_agg(json_build_object('vin', ua.vin, 'model', ua.model,
                                                     'paket', ua.paket_adi, 'renk', ua.renk)
                                            ORDER BY ua.vin)
                     FROM uygun_arac ua
                    WHERE ($4::varchar IS NULL OR ua.vin = $4)
                      AND NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                                       WHERE d.arac_vin = ua.vin
                                         AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))),
                  '[]'::json)
       ELSE '[]'::json END
  FROM olası o, tur t
 WHERE (SELECT count(*) FROM uygun_calisan uc
         WHERE NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                            WHERE d.calisan_id = uc.calisan_id
                              AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))) > 0
   AND (NOT t.arac_gerekli OR EXISTS (
         SELECT 1 FROM uygun_arac ua
          WHERE ($4::varchar IS NULL OR ua.vin = $4)
            AND NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                             WHERE d.arac_vin = ua.vin
                               AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))))
 ORDER BY o.baslangic
```

- Tablolar: `tur_saat`, `mesai`, `randevu_turu`, `calisan`, `calisan_yetkinlik`, `arac`
- View: `v_dolu_slot` — iptal edilmemiş randevuların **zaman/kaynak** bilgisi (PII yok)
- Rol: `bot`
- RLS: `v_dolu_slot` `security_barrier` ile tanımlı ve başka müşterilerin
  randevularını **yalnızca zaman/kaynak olarak** gösterir; kimlik bilgisi taşımaz

### LLM tool tanımı

```json
{
  "name": "musait_slotlar",
  "description": "Bir şubede belirli bir gün için müsait randevu saatlerini listeler. Her saat dilimiyle birlikte o saatte müsait araçları döner. Boş liste dönerse o gün uygun saat yoktur; bilgi alanındaki saat aralığını müşteriye söyleyip başka gün öner.",
  "parameters": {
    "type": "object",
    "properties": {
      "sube_id":   { "type": "integer", "description": "Şube kimliği" },
      "tur_kodu":  { "type": "string",  "description": "Randevu türü kodu (ör. TEST_SURUSU)" },
      "tarih":     { "type": "string",  "description": "Tarih, YYYY-MM-DD. Bugünden en fazla 21 gün ileri." },
      "arac_vin":  { "type": "string",  "description": "Yalnızca belirli bir araç için müsaitlik soruluyorsa araç VIN'i." }
    },
    "required": ["sube_id", "tur_kodu", "tarih"]
  }
}
```

---

## 3. `GET /bot/arac`

Stoktaki ve yoldaki araçları model / şehir / şube kırılımında sayar; ayrıca
müşterinin kendi araçlarını listeler.

**Stok tanımı:** `STOKTA` ve `YOLDA` durumları. `SATILDI` araçlar stok sayılmaz
(onlar müşterilerin araçlarıdır ve yalnız sahibine görünür).

**Fiyat dönmez.** Güncel liste fiyatları için bot web sitesine yönlendirir;
böylece eski fiyat söyleme riski doğmaz.

**Paket (donanım) aracın kimliğinin parçasıdır.** `versiyon` tablosu model +
paket + model yılı + liste fiyatını taşır; her fiziksel araç üretimde sabitlenmiş
bir versiyona sahiptir. Bayide sonradan paket takılmaz.

### Kademeli daralma

Filtre verilmezse en geniş grup, filtre verdikçe bir seviye daralan grup döner:

| Filtre | Gruplama | Cevapladığı soru |
|---|---|---|
| *(yok)* | model | "Hangi modeller var?" |
| `model` | şehir + paket | "İzmir'de 5, Ankara'da 3, İstanbul'da 10" |
| `sehir` | şube + model + paket | "Ankara'da hangi şubede?" |
| `sube_id` | model + paket + **renkler** | "Kadıköy'de hangi paket/renk?" |
| `kapsam=benim` | araç (VIN'li) | "Arabalarım neler?" |

### İstek

```
GET /bot/arac
GET /bot/arac?model=Ioniq%205
GET /bot/arac?sehir=Ankara
GET /bot/arac?sube_id=1
GET /bot/arac?kapsam=benim&model=Ioniq%205
```

| Query | Tip | Zorunlu | Açıklama |
|---|---|---|---|
| `model` | string | ❌ | Model adı, tam eşleşme (`Ioniq 5`) |
| `sehir` | string | ❌ | Şehir, tam eşleşme; `sube_id` ile birlikte kullanılamaz |
| `sube_id` | integer | ❌ | Şube; `sehir` ile birlikte kullanılamaz |
| `kapsam` | string | ❌ | Yalnızca `benim`: müşterinin kendi araçları. `sehir`/`sube_id` ile kullanılamaz |

### Başarılı yanıt — `200 OK`

**Filtresiz (model özeti):**

```json
{
  "ok": true,
  "veri": {
    "toplam": { "stokta": 34, "yolda": 9 },
    "modeller": [
      { "model": "Ioniq 5", "stokta": 18, "yolda": 3, "en_erken_varis": "2026-12-05" },
      { "model": "Tucson",  "stokta": 16, "yolda": 6, "en_erken_varis": "2026-12-12" }
    ],
    "bilgi": "34 araç stokta, 9 araç yolda."
  }
}
```

**`?model=Ioniq 5` (şehir + paket):**

```json
{
  "ok": true,
  "veri": {
    "model": "Ioniq 5",
    "toplam": { "stokta": 13, "yolda": 3 },
    "sehirler": [
      { "sehir": "Ankara",   "paket": "Advance", "stokta": 3, "yolda": 1, "en_erken_varis": "2026-12-12" },
      { "sehir": "İstanbul", "paket": "Advance", "stokta": 10, "yolda": 2, "en_erken_varis": "2026-12-05" }
    ],
    "bilgi": "13 araç stokta, 3 araç yolda."
  }
}
```

**`?sehir=Ankara` (şube + model + paket):**

```json
{
  "ok": true,
  "veri": {
    "sehir": "Ankara",
    "toplam": { "stokta": 3, "yolda": 1 },
    "subeler": [
      { "sube_id": 1, "sube": "Çankaya", "model": "Ioniq 5", "paket": "Advance",
        "stokta": 3, "yolda": 1, "en_erken_varis": "2026-12-12" }
    ],
    "bilgi": "Ankara: 3 araç stokta, 1 araç yolda."
  }
}
```

**`?sube_id=1` (paket + renk):**

```json
{
  "ok": true,
  "veri": {
    "sube": { "sube_id": 1, "sehir": "Ankara", "ad": "Çankaya" },
    "toplam": { "stokta": 3, "yolda": 1 },
    "paketler": [
      {
        "model": "Ioniq 5", "paket": "Advance", "stokta": 3, "yolda": 1,
        "en_erken_varis": "2026-12-12",
        "renkler": [ { "renk": "Beyaz", "adet": 2 }, { "renk": "Siyah", "adet": 1 } ]
      }
    ],
    "bilgi": "Çankaya (Ankara): 3 araç stokta, 1 araç yolda."
  }
}
```

`renkler` yalnız **stoktaki** araçları sayar (yoldaki araçların rengi sayılmaz).

`en_erken_varis` yalnız `yolda > 0` iken doludur; aksi halde `null` döner.
Grubun tamamı stoktaysa bu alan `null` olur — hata değildir.

Kriterlere uyan araç yoksa `200` ve boş liste döner (`subeler: []`, `sehirler: []`
veya `paketler: []`) ve `bilgi` "Bu kriterlerde araç bulunmuyor." olur. Bilinmeyen
model/şehir/şube ile boş sonuç ayrıdır: bilinmeyen değer `404` alır.

**`?kapsam=benim` (müşterinin araçları):**

```json
{
  "ok": true,
  "veri": {
    "toplam_arac": 2,
    "araclar": [
      { "vin": "VIN00000000000022", "model": "Ioniq 5", "paket": "Advance",
        "renk": "Beyaz", "plaka": "06AA01" },
      { "vin": "VIN00000000000024", "model": "Ioniq 5", "paket": "Advance",
        "renk": "Mor", "plaka": "35BB01" }
    ],
    "bilgi": "Kayıtlı 2 aracınız var."
  }
}
```

Araç yoksa `araclar: []`, `toplam_arac: 0` ve `bilgi: "Kayıtlı aracınız bulunmuyor."`
döner — bu bir hata değildir. VIN yalnız bu modda döner (servis/teslim randevusu için).

### Hata yanıtları

| Kod | HTTP | `kullaniciya_goster` | Koşul |
|---|---|---|---|
| `SEHIRDE_SUBE_YOK` | 404 | true | `sehir` verildi, o şehirde şube yok |
| `SUBE_YOK` | 404 | true | `sube_id` bulunamadı |
| `MODEL_YOK` | 404 | true | `model` katalogda yok |
| `GECERSIZ_PARAMETRE` | 400 | true | `sehir` + `sube_id` birlikte; `kapsam=benim` + `sehir`/`sube_id`; geçersiz `kapsam`; sayısal olmayan `sube_id` |

### Veritabanı

```sql
-- Filtresiz: model özeti
SELECT md.ad AS model,
       count(*) FILTER (WHERE a.durum = 'STOKTA') AS stokta,
       count(*) FILTER (WHERE a.durum = 'YOLDA')  AS yolda,
       min(a.tahmini_varis_tarihi) FILTER (WHERE a.durum = 'YOLDA') AS en_erken_varis
  FROM arac a
  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
  JOIN model   md ON md.model_id   = v.model_id
  JOIN sube     s ON s.sube_id     = a.sube_id
 WHERE a.durum IN ('STOKTA','YOLDA')
 GROUP BY md.ad
 ORDER BY md.ad COLLATE "C";

-- kapsam=benim: müşterinin araçları (RLS + açık sahiplik koşulu)
SELECT a.vin, md.ad, v.paket_adi, a.renk, a.plaka
  FROM arac a
  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
  JOIN model   md ON md.model_id   = v.model_id
 WHERE a.durum = 'SATILDI' AND a.musteri_id = fn_aktif_musteri_id();
```

- Tablolar: `arac`, `versiyon`, `model`, `sube`
- Rol: `bot`; RLS `p_arac_bot_oku` stokta/yoldaki araçları ve müşterinin kendi
  araçlarını gösterir, başkasının `SATILDI` aracını göstermez
- İndeks: `idx_arac_sube_durum (sube_id, durum)` şube filtreli sorgularda,
  `idx_arac_musteri (musteri_id)` kendi araçlar sorgusunda kullanılır

### LLM tool tanımı

```json
{
  "name": "arac_listele",
  "description": "Stoktaki ve yoldaki araçları listeler. Parametresiz çağrılırsa model bazında toplam verir. Bir model verilirse o modelin şehir ve paket kırılımını döner. Şehir verilirse o şehirdeki şubeleri, şube verilirse paket ve renk kırılımını döner. kapsam=benim verilirse müşterinin kendi araçlarını VIN ve plakasıyla listeler (servis randevusu için). Fiyat bilgisi dönmez; fiyat sorulursa web sitesine yönlendir.",
  "parameters": {
    "type": "object",
    "properties": {
      "model":   { "type": "string",  "description": "Model adı (ör. Ioniq 5). Tam eşleşme." },
      "sehir":   { "type": "string",  "description": "Şehir adı (ör. Ankara). sube_id ile birlikte kullanılamaz." },
      "sube_id": { "type": "integer", "description": "Şube kimliği. sehir ile birlikte kullanılamaz." },
      "kapsam":  { "type": "string",  "enum": ["benim"], "description": "Yalnızca müşterinin kendi araçlarını listeler." }
    }
  }
}
```

---

## 4. `POST /bot/randevu`

WhatsApp üzerinden randevu oluşturur. **Çalışanı ve aracı sistem atar**; LLM
kimseyi seçmez. Randevu `kaynak = 'WHATSAPP'` ve `durum = 'PLANLANDI'` olarak açılır
(bu, `randevu` tablosundaki RLS politikasının şartıdır).

### İstek

```json
{
  "sube_id": 1,
  "tur_kodu": "TEST_SURUSU",
  "tarih": "2026-11-28",
  "baslangic": "10:00",
  "model": "Ioniq 5",
  "ad": "Ali",
  "soyad": "Veli"
}
```

| Alan | Tip | Zorunlu | Açıklama |
|---|---|---|---|
| `sube_id` | integer | ✅ | Şube |
| `tur_kodu` | string | ✅ | Randevu türü |
| `tarih` | string | ✅ | `YYYY-MM-DD`, bugün–21 gün |
| `baslangic` | string | ✅ | `HH:MM`; türün saat penceresinde olmalı |
| `model` | string | ❌ | Yalnız araç gerektiren türlerde. Verilirse o modelden atanır; boş araç yoksa `ARAC_YOK` + mevcut modeller |
| `ad`, `soyad` | string | ❌ | Verilirse müşteri kaydına yazılır/güncellenir; kayıt yoksa telefonla oluşturulur |

**Kimlik gövdeden gelmez**: müşteri `X-Musteri-Telefon` başlığından belirlenir.

### Atama kuralları

**Çalışan:** şubede + aktif + doğru departman + yetkinliği o gün geçerli + o saatte
boş olanlar arasından **son 7 günün (bugün dahil) randevu sayısı en az olan**.
Eşitlikte `calisan_id` küçük olan seçilir (deterministik). Sayaç `v_dolu_slot`
view'ından okunur (bot `randevu` tablosunda başkalarının satırlarını göremez).

**Araç:** türün izin verdiği kümeden, o saatte boş olan ilk araç (`vin` sırası):

| Tür | Aday kümesi |
|---|---|
| `TEST_SURUSU` | şubede `STOKTA` |
| `TESLIMAT` | müşterinin kendi `SATILDI` aracı, o şubede |
| `SERVIS_TESLIM` | müşterinin bu şubede açık ve `TESLIME_HAZIR` kaydı |
| `PERIYODIK_BAKIM`, `SERVIS_GIRIS` | müşterinin kendi `SATILDI` aracı |
| `ARAC_INCELEME`, `SATIN_ALIM` | araç atanmaz (`model` gönderilirse 400) |

**Çakışma kilitle önlenmez.** Aynı anda gelen iki istekten biri veritabanındaki
`EXCLUDE` kısıtına takılır; bu durum `409 SLOT_DOLU` olarak döner (500 değil).
Kazananı veritabanı belirler; kilit yoktur.

### Başarılı yanıt — `201 Created`

```json
{
  "ok": true,
  "veri": {
    "randevu_id": 4211,
    "musteri_id": 12,
    "sube": { "sube_id": 1, "sehir": "Ankara", "ad": "Çankaya" },
    "tur_kodu": "TEST_SURUSU",
    "tarih": "2026-11-28",
    "baslangic": "10:00",
    "bitis": "11:00",
    "arac": { "vin": "VIN00000000000001", "model": "Ioniq 5",
              "paket": "Advance", "renk": "Beyaz" },
    "bilgi": "Randevunuz oluşturuldu: 2026-11-28 10:00, Çankaya (Ankara)."
  }
}
```

- Çalışan bilgisi **dönmez**: bot `calisan.ad` kolonunu okuyamaz (yetki yok).
- `arac` yalnız araç atanan türlerde bulunur.
- `bitis` = `baslangic` + türün süresi.

### Hata yanıtları

| Kod | HTTP | `kullaniciya_goster` | Koşul |
|---|---|---|---|
| `SUBE_YOK`, `TUR_YOK` | 404 | true | Bilinmeyen şube/tür |
| `GECERSIZ_TARIH` | 400 | true | `YYYY-MM-DD` değil |
| `GECMIS_TARIH` | 400 | true | Bugünden önce |
| `COK_UZAK_TARIH` | 400 | true | 21 günden fazla |
| `GECERSIZ_SAAT` | 400 | true | `HH:MM` değil veya türün penceresinde değil |
| `SLOT_DOLU` | 409 | true | Uygun/boş çalışan veya araç yok; `detay.sebep`: `CALISAN_YOK` \| `ARAC_YOK` |
| `ARAC_YOK` | 404 | true | İki durum: (a) `model` istendi ama o saatte o model boş değil — `detay.mevcut_modeller` dolu; (b) bu tür için hiç uygun araç yok (ör. müşterinin kayıtlı aracı yok) |
| `GECERSIZ_PARAMETRE` | 400 | true | `model` araç gerektirmeyen türde; eksik/bozuk alan; gövde JSON değil |

### Veritabanı

```sql
-- Müşteri kaydı (yoksa telefonla açılır; ad/soyad sonradan öğrenilebilir)
INSERT INTO musteri (telefon, ad, soyad)
VALUES (current_setting('app.musteri_telefon', true), $1, $2);

-- Çalışan seçimi: son 7 günün yükü en az olan
SELECT c.calisan_id
  FROM calisan c, tur t
 WHERE c.sube_id = $1 AND c.aktif_mi AND c.departman = t.departman
   AND NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                    WHERE d.calisan_id = c.calisan_id
                      AND tsrange(d.baslangic, d.bitis) && tsrange($2, $3))
 ORDER BY (SELECT count(*) FROM v_dolu_slot d2
            WHERE d2.calisan_id = c.calisan_id
              AND d2.baslangic >= current_date - interval '6 day'
              AND d2.baslangic <  current_date + interval '1 day') ASC,
          c.calisan_id
 LIMIT 1;

-- Ekleme (RLS: kaynak = 'WHATSAPP' zorunlu)
INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin,
                     baslangic, bitis, durum, kaynak)
VALUES ($1, $2, $3, $4, $5, $6, $7, 'PLANLANDI', 'WHATSAPP');
```

- EXCLUDE ihlali (`SQLSTATE 23P01`) → `409 SLOT_DOLU`
- `fn_randevu_dogrula` trigger'ı süre, saat penceresi, yetkinlik ve araç kurallarını
  ayrıca denetler (son savunma)

### LLM tool tanımı

```json
{
  "name": "randevu_olustur",
  "description": "WhatsApp üzerinden randevu oluşturur. Çalışanı ve aracı sistem atar. Test sürüşünde müşteri belirli bir model istediyse model alanını doldur; istemediyse boş bırak. Müşteri yeni ise ad ve soyad ver (kayıt yoksa telefonla oluşturulur). SLOT_DOLU dönerse başka saat öner.",
  "parameters": {
    "type": "object",
    "properties": {
      "sube_id":   { "type": "integer", "description": "Şube kimliği" },
      "tur_kodu":  { "type": "string",  "description": "Randevu türü kodu" },
      "tarih":     { "type": "string",  "description": "YYYY-MM-DD, bugünden en fazla 21 gün ileri" },
      "baslangic": { "type": "string",  "description": "HH:MM; /bot/slot'tan alınan müsait saat" },
      "model":     { "type": "string",  "description": "Yalnız araç gerektiren türlerde, müşteri belirli model istediyse" },
      "ad":        { "type": "string",  "description": "Müşteri adı (yeni kayıt veya güncelleme)" },
      "soyad":     { "type": "string",  "description": "Müşteri soyadı" }
    },
    "required": ["sube_id", "tur_kodu", "tarih", "baslangic"]
  }
}
```

---

## 5. `GET /bot/randevu`

Müşterinin **kendi** randevularını üç ayrı listede döner. RLS gereği başka
müşterilerin satırları görünmez; ayrıca açık `musteri_id = fn_aktif_musteri_id()`
koşulu vardır (iki katman).

### İstek

```
GET /bot/randevu
GET /bot/randevu?limit=5
```

| Query | Tip | Zorunlu | Açıklama |
|---|---|---|---|
| `limit` | integer | ❌ | Geçmiş listesinin uzunluğu, 1–50 (varsayılan 10) |

### Başarılı yanıt — `200 OK`

```json
{
  "ok": true,
  "veri": {
    "toplam": 4,
    "yaklasan": [
      {
        "randevu_id": 88,
        "tur_kodu": "PERIYODIK_BAKIM",
        "tur_adi": "Periyodik Bakım",
        "tarih": "2026-12-05",
        "baslangic": "10:00",
        "bitis": "11:00",
        "durum": "PLANLANDI",
        "durum_adi": "Planlandı",
        "sube": { "sube_id": 1, "sehir": "Ankara", "ad": "Çankaya" },
        "arac": { "vin": "VIN00000000000042", "model": "Ioniq 5",
                  "paket": "Advance", "renk": "Gri" }
      }
    ],
    "gecmis": [
      {
        "randevu_id": 77,
        "tur_kodu": "SERVIS_GIRIS",
        "tur_adi": "Servise Giriş",
        "tarih": "2026-11-21",
        "baslangic": "11:00",
        "bitis": "11:30",
        "durum": "TAMAMLANDI",
        "durum_adi": "Tamamlandı",
        "sube": { "sube_id": 1, "sehir": "Ankara", "ad": "Çankaya" },
        "arac": { "vin": "VIN00000000000042", "model": "Ioniq 5",
                  "paket": "Advance", "renk": "Gri" }
      }
    ],
    "son_bakim": {
      "randevu_id": 55,
      "tur_kodu": "PERIYODIK_BAKIM",
      "tur_adi": "Periyodik Bakım",
      "tarih": "2026-10-31",
      "baslangic": "09:00",
      "bitis": "10:00",
      "durum": "TAMAMLANDI",
      "durum_adi": "Tamamlandı",
      "sube": { "sube_id": 1, "sehir": "Ankara", "ad": "Çankaya" },
      "arac": { "vin": "VIN00000000000042", "model": "Ioniq 5",
                "paket": "Advance", "renk": "Gri" }
    },
    "bilgi": "1 yaklaşan randevunuz var. Toplam 4 randevu."
  }
}
```

### Üç listenin anlamı

| Alan | İçerik | Sıralama |
|---|---|---|
| `yaklasan` | `durum = PLANLANDI` ve **bitişi geçmemiş** randevular (devam eden dahil) | Yakından uzağa |
| `gecmis` | **Bitmiş veya iptal edilmiş** son `limit` randevu | Yeniden eskiye |
| `son_bakim` | En yeni **tamamlanmış periyodik bakım**; yoksa `null` | — |

`gecmis` iki durumu kapsar: süresi geçmiş randevular ve **tarihi gelecekte olsa
bile iptal edilmiş** randevular. Böylece her randevu tam olarak bir kovada
görünür; `toplam` ile listeler çelişmez (liste `limit` ile sınırlı olabilir).

`son_bakim` neden ayrı: son 10 randevu arasında arıza/kaza kayıtları bakımı
listeden düşürebilir. Bot "son bakımınız neredeydi?" sorusunu bu alandan
cevaplar; `limit` bu alanı etkilemez.

`arac` alanı, o randevuya bağlı araç varsa dolar. Araç sonradan başka bir
müşteriye satıldıysa RLS görünürlüğü kaldırır ve `arac` `null` gelir.

### Hata yanıtları

| Kod | HTTP | Koşul |
|---|---|---|
| `GECERSIZ_PARAMETRE` | 400 | `limit` sayısal değil / 1–50 dışında; tanımsız parametre (ör. `limt`) |
| `KIMLIK_YOK` | 401 | `X-Musteri-Telefon` yok/geçersiz |
| `YONTEM_DESTEKLENMIYOR` | 405 | GET/POST dışı yöntem (`Allow: GET, POST`) |

### Veritabanı

```sql
SELECT r.randevu_id, r.tur_kodu, rt.ad, r.baslangic, r.bitis, r.durum,
       s.sube_id, s.sehir, s.ad AS sube_ad,
       a.vin, md.ad AS model, v.paket_adi, a.renk
  FROM randevu r
  JOIN randevu_turu rt ON rt.tur_kodu  = r.tur_kodu
  JOIN sube s          ON s.sube_id    = r.sube_id
  LEFT JOIN arac a     ON a.vin        = r.arac_vin
  LEFT JOIN versiyon v ON v.versiyon_id = a.versiyon_id
  LEFT JOIN model md   ON md.model_id  = v.model_id
 WHERE r.musteri_id = fn_aktif_musteri_id()
   AND (r.bitis < (now() AT TIME ZONE 'Europe/Istanbul')  -- süresi geçmiş
        OR r.durum = 'IPTAL')                            -- veya iptal edilmiş
 ORDER BY r.baslangic DESC
 LIMIT $1;
```

- `now() AT TIME ZONE 'Europe/Istanbul'`: iş saatleri yerel saatle saklandığı
  için "şimdi" de yerel olarak karşılaştırılır (sunucu UTC olsa bile).
- İndeks: `idx_randevu_musteri (musteri_id, baslangic DESC)` geçmiş listesini
  sıralama maliyeti olmadan verir.

### LLM tool tanımı

```json
{
  "name": "randevularim",
  "description": "Müşterinin kendi randevularını getirir: yaklasan (planlanmış), gecmis (son N) ve son_bakim (en yeni tamamlanmış periyodik bakım). 'Randevum ne zaman?', 'geçen sefer neredeydim?', 'son bakımım ne zamandı?' sorularında kullan. İptal için randevu_id gerekir.",
  "parameters": {
    "type": "object",
    "properties": {
      "limit": { "type": "integer", "description": "Geçmiş listesi uzunluğu (1-50, varsayılan 10)" }
    }
  }
}
```

---

## 8. `POST /bot/musteri`

Müşterinin ad/soyad bilgisini yazar. Bot ismi konuşma sırasında öğrendiği için
ayrı uçtur; alanlar tek tek gönderilebilir (önce ad, sonra soyad).

### İstek

```json
{ "ad": "Ali" }
{ "soyad": "Veli" }
{ "ad": "Ali", "soyad": "Veli" }
```

| Alan | Zorunlu | Açıklama |
|---|---|---|
| `ad` | ⚠️ | En az biri gerekli |
| `soyad` | ⚠️ | En az biri gerekli |

Kimlik gövdeden gelmez: `X-Musteri-Telefon` başlığından belirlenir. Kayıt yoksa
telefonla oluşturulur (ad/soyad nullable — bkz. `db/440_musteri_bilgisi.sql`);
varsa yalnızca verilen alanlar güncellenir.

### Başarılı yanıt — `200 OK`

```json
{
  "ok": true,
  "veri": {
    "musteri_id": 12,
    "ad": "Ali",
    "soyad": "Veli",
    "bilgi": "Müşteri bilgisi kaydedildi."
  }
}
```

### Hata yanıtları

| Kod | HTTP | Koşul |
|---|---|---|
| `GECERSIZ_PARAMETRE` | 400 | İki alan da boş; gövde JSON değil; alan metin değil |
| `KIMLIK_YOK` | 401 | `X-Musteri-Telefon` yok/geçersiz |

### Veritabanı

```sql
-- RLS: yalnızca kendi telefonunun satırı (UPDATE politikası, db/440)
UPDATE musteri
   SET ad    = coalesce($1, ad),
       soyad = coalesce($2, soyad)
 WHERE telefon = current_setting('app.musteri_telefon', true);
```

Bot `musteri` tablosunda yalnız `ad`, `soyad` kolonlarını güncelleyebilir
(`GRANT UPDATE (ad, soyad)`); telefon ve kayıt zamanı değiştirilemez.

### LLM tool tanımı

```json
{
  "name": "musteri_bilgisi",
  "description": "Müşterinin adını ve/veya soyadını kaydeder. Müşteri ismini söylediğinde veya hitap için sorduğunda kullan. Alanlar tek tek gönderilebilir.",
  "parameters": {
    "type": "object",
    "properties": {
      "ad":    { "type": "string", "description": "Müşteri adı" },
      "soyad": { "type": "string", "description": "Müşteri soyadı" }
    }
  }
}
```

---
