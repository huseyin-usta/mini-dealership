import test from "node:test";
import assert from "node:assert/strict";

import { MEDYA_CEVABI, YEDEK_CEVAP, gelenMesajiIsle } from "../lib/mesaj.js";

const CFG = { backendUrl: "http://backend:8080", botToken: "t".repeat(32) };

function toplayici() {
  const gonderilen = [];
  return {
    gonderilen,
    gonder: async (jid, metin) => {
      gonderilen.push({ jid, metin });
    },
  };
}

function fetchCevap(durum, govde) {
  return async () =>
    new Response(JSON.stringify(govde), {
      status: durum,
      headers: { "Content-Type": "application/json" },
    });
}

const sessizLog = { warn: () => {}, error: () => {} };

test("başarılı akış: cevap müşteriye gönderilir", async () => {
  const { gonderilen, gonder } = toplayici();
  const sonuc = await gelenMesajiIsle({
    cfg: CFG,
    jid: "905321234567@s.whatsapp.net",
    sender: "+905321234567",
    metin: "cumartesi randevu",
    kaynakId: "wamid.1",
    gonder,
    fetchImpl: fetchCevap(200, { ok: true, veri: { cevap: "Hangi şehir?" } }),
    log: sessizLog,
  });

  assert.equal(sonuc.durum, "cevaplandi");
  assert.deepEqual(gonderilen, [
    { jid: "905321234567@s.whatsapp.net", metin: "Hangi şehir?" },
  ]);
});

test("LLM cevap veremezse yedek mesaj gönderilir", async () => {
  const { gonderilen, gonder } = toplayici();
  const sonuc = await gelenMesajiIsle({
    cfg: CFG,
    jid: "905321234567@s.whatsapp.net",
    sender: "+905321234567",
    metin: "selam",
    gonder,
    fetchImpl: fetchCevap(503, { ok: false, hata: { kod: "LLM_UNAVAILABLE" } }),
    log: sessizLog,
  });

  assert.equal(sonuc.durum, "llm");
  assert.deepEqual(gonderilen, [
    { jid: "905321234567@s.whatsapp.net", metin: YEDEK_CEVAP },
  ]);
});

test("backend'e ulaşılamazsa yedek mesaj gönderilir", async () => {
  const { gonderilen, gonder } = toplayici();
  const sonuc = await gelenMesajiIsle({
    cfg: CFG,
    jid: "905321234567@s.whatsapp.net",
    sender: "+905321234567",
    metin: "selam",
    gonder,
    fetchImpl: async () => {
      throw new TypeError("fetch failed");
    },
    log: sessizLog,
  });

  assert.equal(sonuc.durum, "ag");
  assert.equal(gonderilen[0].metin, YEDEK_CEVAP);
});

test("kimlik reddi (401) müşteriye sızdırılmaz, yedek mesaj gider", async () => {
  const { gonderilen, gonder } = toplayici();
  const sonuc = await gelenMesajiIsle({
    cfg: CFG,
    jid: "905321234567@s.whatsapp.net",
    sender: "+905321234567",
    metin: "selam",
    gonder,
    fetchImpl: fetchCevap(401, { ok: false, hata: { kod: "YETKISIZ_ISTEK" } }),
    log: sessizLog,
  });

  assert.equal(sonuc.durum, "kimlik");
  assert.equal(gonderilen[0].metin, YEDEK_CEVAP);
  assert.ok(!gonderilen[0].metin.includes("401"));
});

test("medya mesajına kısa bilgi verilir, backend çağrılmaz", async () => {
  const { gonderilen, gonder } = toplayici();
  let cagrildi = false;

  const sonuc = await gelenMesajiIsle({
    cfg: CFG,
    jid: "905321234567@s.whatsapp.net",
    sender: "+905321234567",
    metin: null,
    gonder,
    fetchImpl: async () => {
      cagrildi = true;
      throw new Error("çağrılmamalıydı");
    },
    log: sessizLog,
  });

  assert.equal(sonuc.durum, "medya");
  assert.equal(cagrildi, false);
  assert.equal(gonderilen[0].metin, MEDYA_CEVABI);
});

test("gönderim hatası akışı düşürmez", async () => {
  const sonuc = await gelenMesajiIsle({
    cfg: CFG,
    jid: "905321234567@s.whatsapp.net",
    sender: "+905321234567",
    metin: "selam",
    gonder: async () => {
      throw new Error("socket kapandı");
    },
    fetchImpl: fetchCevap(200, { ok: true, veri: { cevap: "Merhaba" } }),
    log: sessizLog,
  });

  assert.equal(sonuc.durum, "cevaplandi");
});
