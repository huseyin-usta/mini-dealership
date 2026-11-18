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

## Endpoint'ler

| # | Endpoint | LLM tool adı | Amaç |
|---|---|---|---|
| 1 | `GET /bot/sube` | `sube_listele` | Şehir ve şube listesi |
| 2 | `GET /bot/slot` | `musait_slotlar` | Müsait randevu saatleri ve o saatteki imkanlar |
| 3 | `GET /bot/arac` | `arac_listele` | Stoktaki/yoldaki araçlar veya müşterinin araçları |
| 4 | `POST /bot/randevu` | `randevu_olustur` | Randevu oluşturma |
| 5 | `GET /bot/randevu` | `randevularim` | Müşterinin randevu geçmişi |
| 6 | `POST /bot/randevu/{id}/iptal` | `randevu_iptal` | Randevu iptali |
| 7 | `POST /bot/mesaj` | — | Köprünün giriş noktası (LLM tool'u değil) |

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

| Tür | Çalışan | Araç |
|---|---|---|
| `TEST_SURUSU` | yetkinlik şartı var | o şubede `STOKTA` ve o saat boş |
| `TESLIMAT` | departman: `SATIS` | teslim edilecek araç |
| `ARAC_INCELEME`, `SATIN_ALIM` | departman: `SATIS` | gerekmez |
| `PERIYODIK_BAKIM`, `SERVIS_GIRIS` | departman: `SERVIS` | gerekmez (araç müşteride) |
| `SERVIS_TESLIM` | departman: `SERVIS` | müşterinin açık servis kaydındaki araç (teslime hazır olmalı) |

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
| `arac_vin` | string | ❌ | Verilirse yalnızca o araç boş olan dilimler döner |

### Başarılı yanıt — `200 OK`

```json
{
  "ok": true,
  "veri": {
    "tarih": "2026-11-20",
    "tur_kodu": "TEST_SURUSU",
    "bilgi": "Test Sürüşü 10:00-12:00 ve 14:00-16:00 arasında yapılır.",
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
    "bilgi": "Test Sürüşü 10:00-12:00 ve 14:00-16:00 arasında yapılır.",
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
| `ARAC_STOKTA_YOK` | 404 | true | `arac_vin` verildi; test sürüşü/teslimat için araç o şubede `STOKTA` değil |
| `ARAC_SERVISTE_DEGIL` | 404 | true | `arac_vin` verildi; servisten teslim için açık servis kaydı yok |
| `SERVIS_TESLIM_HAZIR_DEGIL` | 409 | true | Araç serviste ama teslime hazır değil; `detay` son durumu ve tahmini teslim tarihini taşır |
| `GECERSIZ_PARAMETRE` | 400 | true | Parametreler birlikte kullanılamaz (`kapsam=benim` + `arac_vin`) |

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
WITH olası AS (
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
tur AS (
    SELECT rt.tur_kodu, rt.yetkinlik_id, rt.departman,
           rt.tur_kodu IN ('TEST_SURUSU','TESLIMAT','SERVIS_TESLIM') AS arac_gerekli
      FROM randevu_turu rt WHERE rt.tur_kodu = $2
),
uygun_calisan AS (
    -- Şubede, aktif, doğru departmanda, yetkinliği olan çalışanlar
    SELECT c.calisan_id
      FROM calisan c, tur t
     WHERE c.sube_id = $3 AND c.aktif_mi AND c.departman = t.departman
       AND (t.yetkinlik_id IS NULL OR EXISTS (
             SELECT 1 FROM calisan_yetkinlik cy
              WHERE cy.calisan_id = c.calisan_id
                AND cy.yetkinlik_id = t.yetkinlik_id))
),
uygun_arac AS (
    -- Test sürüşü/teslimat: şubede stokta olan araçlar
    SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
      FROM arac a
      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
      JOIN model   md ON md.model_id   = v.model_id
     WHERE a.sube_id = $3 AND a.durum = 'STOKTA'
       AND (SELECT arac_gerekli FROM tur)
       AND (SELECT tur_kodu FROM tur) <> 'SERVIS_TESLIM'
    UNION ALL
    -- Servisten teslim: bu şubede açık ve TESLİME HAZIR kaydı olan araçlar
    SELECT DISTINCT a.vin, v.paket_adi, md.ad AS model, a.renk
      FROM arac a
      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
      JOIN model   md ON md.model_id   = v.model_id
      JOIN v_musteri_servis_durumu msd ON msd.arac_vin = a.vin
     WHERE (SELECT tur_kodu FROM tur) = 'SERVIS_TESLIM'
       AND msd.kapandi_mi = false
       AND msd.son_durum = 'TESLIME_HAZIR'
       AND msd.sube_id = $3
)
SELECT o.baslangic::time, o.bitis::time,
       (SELECT count(*) FROM uygun_calisan uc
         WHERE NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                            WHERE d.calisan_id = uc.calisan_id
                              AND tsrange(d.baslangic, d.bitis) && tsrange(o.baslangic, o.bitis))),
       CASE WHEN t.arac_gerekli THEN
         COALESCE((SELECT json_agg(json_build_object('vin', ua.vin, 'model', ua.model,
                                                     'paket', ua.paket_adi, 'renk', ua.renk))
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
