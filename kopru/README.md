# WhatsApp Köprüsü

Baileys tabanlı ince köprü. **İş mantığı yoktur**: WhatsApp oturumunu ayakta
tutar, gelen metni backend'e iletir, cevabı müşteriye yazar. Veritabanına
dokunmaz; LLM backend'de çalışır.

## Yaptığı

1. WhatsApp çoklu cihaz oturumu açar (QR veya telefon numarasıyla eşleştirme).
2. Gelen metni JID'den çıkarılan telefonla birlikte `POST /bot/mesaj`'a iletir
   (`kaynak_id` = WhatsApp mesaj kimliği → idempotency).
3. Dönen cevabı müşteriye yazar.
4. Backend'e ulaşılamazsa/LLM cevap veremezse kısa bir yedek mesaj gönderir.
5. Grup, durum (`status@broadcast`) ve kanal mesajlarını, ayrıca kendi
   gönderdiği mesajları işlemez.

## Yapmadığı

- Müsaitlik hesabı, randevu, iptal, stok — hepsi backend'de.
- Mesaj/randevu kaydı — backend yapar.
- LLM çağrısı — backend yapar.

## Kurulum

```bash
cd kopru
cp .env.example .env      # BOT_TOKEN ve BACKEND_URL doldur
npm install
npm start
```

İlk açılışta terminalde QR çıkar ve `http://<cihaz>:3000/` adresinde taranabilir
bir sayfa açılır. Bağlantı kurulunca sayfa kapanır. Oturum `kopru/auth/`
altında saklanır (git'e girmez).

## Test

```bash
npm test        # node --test; Baileys ve backend gerekmez
```

Testler saf fonksiyonları (JID → telefon, metin çıkarma), backend istemcisini
(sahte `fetch`) ve mesaj akışını (sahte gönderim) kapsar.

## Ortam değişkenleri

| Değişken | Zorunlu | Açıklama |
|---|---|---|
| `BACKEND_URL` | ❌ | Varsayılan `http://127.0.0.1:8080` |
| `BOT_TOKEN` | ✅ | Backend'deki `BOT_TOKEN` ile aynı, ≥32 karakter |
| `PAIR_PORT` | ❌ | Varsayılan `3000` |
| `PAIR_PHONE` | ❌ | Numarayla eşleştirme (ülke kodu dahil) |
| `LOG_LEVEL` | ❌ | Varsayılan `warn` |

## Sözleşme

Köprü yalnız `POST /bot/mesaj` ucunu kullanır:
`docs/api/bot-sozlesmesi.md` §7.
