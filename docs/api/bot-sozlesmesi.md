# Bot API Sözleşmesi

WhatsApp köprüsü (Node.js) ile Java backend arasındaki HTTP sözleşmesi.

Köprü veritabanına **hiç dokunmaz**; bütün iş mantığı backend'de, bütün kısıtlar
PostgreSQL'de. Köprü yalnızca mesajı taşır.

## Genel kurallar

### Kimlik

Müşteri kimliği **her istekte** köprüden gelir, LLM argümanlarından **asla**:

```
X-Musteri-Telefon: +905321234567
```

Köprü bu değeri WhatsApp JID'sinden çıkarır (`resolveSender`). Backend bunu
transaction içinde `SET LOCAL app.musteri_telefon` değişkenine yazar; satır bazlı
güvenlik (RLS) devreye girer ve bot yalnızca o müşterinin satırlarını görür.
Değişken yoksa RLS hiçbir satır göstermez (fail-closed).

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
| LLM içi | `YETKI_YOK`, `SERVIS_KAPALI` | LLM müşteriye söylemez, başka çalışan/şube/gün arar |
| Sistem | `SISTEM_HATASI` | "Şu an hizmet veremiyorum" |

## Endpoint'ler

| # | Endpoint | LLM tool adı | Amaç |
|---|---|---|---|
| 1 | `GET /bot/sube` | `sube_listele` | Şehir ve şube listesi |
| 2 | `GET /bot/slot` | `musait_slotlar` | Müsait randevu saatleri |
| 3 | `GET /bot/arac` | `arac_listele` | Stoktaki ve yoldaki araçlar |
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
