import test from "node:test";
import assert from "node:assert/strict";

import { extractText, islenecekMesajlar, resolveSender, toE164 } from "../lib/sender.js";

test("toE164: JID'den telefon üretir, cihaz ekini atar", () => {
  assert.equal(toE164("905321234567@s.whatsapp.net"), "+905321234567");
  assert.equal(toE164("905321234567:12@s.whatsapp.net"), "+905321234567");
  assert.equal(toE164("+90 (532) 123 45 67"), "+905321234567");
});

test("toE164: sınır dışı numaralar reddedilir", () => {
  assert.equal(toE164("1234567"), null);        // 7 hane
  assert.equal(toE164("1234567890123456"), null); // 16 hane
  assert.equal(toE164(null), null);
  assert.equal(toE164(""), null);
});

test("resolveSender: DM'de gönderen, grupta null", () => {
  assert.equal(resolveSender("905321234567@s.whatsapp.net"), "+905321234567");
  assert.equal(resolveSender("905321234567@s.whatsapp.net", "905551112233@s.whatsapp.net"),
    "+905551112233");
  assert.equal(resolveSender("120363000000000000@g.us"), null);
  assert.equal(resolveSender("status@broadcast"), null);
  assert.equal(resolveSender("123456789012345678@newsletter"), null);
  assert.equal(resolveSender(null), null);
});

test("resolveSender: LID'de telefon PN alanından alınır", () => {
  // WhatsApp v7 doğrudan sohbetlerde remoteJid olarak LID gönderebilir.
  assert.equal(resolveSender("63436683780257@lid", undefined,
    "905551112233@s.whatsapp.net"), "+905551112233");
  // PN hiç yoksa yanlış numara yazmak yerine null.
  assert.equal(resolveSender("63436683780257@lid"), null);
});

test("extractText: düz metin, alıntılı metin ve medya alt yazısı", () => {
  assert.equal(extractText({ conversation: "  merhaba   dünya " }), "merhaba dünya");
  assert.equal(extractText({ extendedTextMessage: { text: "selam" } }), "selam");
  assert.equal(extractText({ imageMessage: { caption: "bu araç" } }), "bu araç");
});

test("extractText: metin yoksa null (medya)", () => {
  assert.equal(extractText({ imageMessage: {} }), null);
  assert.equal(extractText({ conversation: "   " }), null);
  assert.equal(extractText(null), null);
});

test("islenecekMesajlar: kendi mesajımız ve gruplar elenir", () => {
  const mesajlar = [
    // kendi gönderdiğimiz
    { key: { fromMe: true, remoteJid: "905321234567@s.whatsapp.net", id: "A" }, message: { conversation: "x" } },
    // grup
    { key: { remoteJid: "1203630@g.us", id: "B" }, message: { conversation: "grup" } },
    // işlenecek DM
    { key: { remoteJid: "905321234567@s.whatsapp.net", id: "C" },
      message: { conversation: "randevu almak istiyorum" } },
    // medya (metinsiz) — yine listeye girer, metin null
    { key: { remoteJid: "905551112233@s.whatsapp.net", id: "D" }, message: { imageMessage: {} } },
  ];

  const sonuc = islenecekMesajlar(mesajlar);
  assert.equal(sonuc.length, 2);
  assert.deepEqual(sonuc[0], {
    jid: "905321234567@s.whatsapp.net",
    sender: "+905321234567",
    metin: "randevu almak istiyorum",
    kaynakId: "C",
  });
  assert.equal(sonuc[1].metin, null);
  assert.equal(sonuc[1].kaynakId, "D");
});

test("islenecekMesajlar: LID mesajında telefon PN alanından gelir", () => {
  const sonuc = islenecekMesajlar([{
    key: { remoteJid: "63436683780257@lid", remoteJidAlt: "905551112233@s.whatsapp.net", id: "L" },
    message: { conversation: "merhaba" },
  }]);
  assert.equal(sonuc.length, 1);
  assert.equal(sonuc[0].jid, "63436683780257@lid");       // cevap LID'e gider
  assert.equal(sonuc[0].sender, "+905551112233");          // kimlik PN'den
});

test("islenecekMesajlar: LID eşlemesi yoksa da listeye girer (köprü çözer)", () => {
  const sonuc = islenecekMesajlar([{
    key: { remoteJid: "63436683780257@lid", id: "M" },
    message: { conversation: "merhaba" },
  }]);
  assert.equal(sonuc.length, 1);
  assert.equal(sonuc[0].sender, null);
  assert.equal(sonuc[0].jid, "63436683780257@lid");
});

test("islenecekMesajlar: boş girdi", () => {
  assert.deepEqual(islenecekMesajlar([]), []);
  assert.deepEqual(islenecekMesajlar(undefined), []);
});
