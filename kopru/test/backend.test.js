import test from "node:test";
import assert from "node:assert/strict";

import { BackendHatasi, mesajGonder } from "../lib/backend.js";

const CFG = {
  backendUrl: "http://backend:8080",
  botToken: "t".repeat(32),
};

function sahteFetch(durum, govde) {
  const cagrilar = [];
  const fn = async (url, opts) => {
    cagrilar.push({ url, opts });
    return new Response(typeof govde === "string" ? govde : JSON.stringify(govde), {
      status: durum,
      headers: { "Content-Type": "application/json" },
    });
  };
  fn.cagrilar = cagrilar;
  return fn;
}

test("başarılı yanıt: cevabı döndürür ve kimlik başlıklarını gönderir", async () => {
  const fetchImpl = sahteFetch(200, { ok: true, veri: { cevap: "Merhaba!" } });

  const cevap = await mesajGonder({
    ...CFG,
    telefon: "+905321234567",
    metin: "selam",
    kaynakId: "wamid.1",
    fetchImpl,
  });

  assert.equal(cevap, "Merhaba!");

  const { url, opts } = fetchImpl.cagrilar[0];
  assert.equal(url, "http://backend:8080/bot/mesaj");
  assert.equal(opts.method, "POST");
  assert.equal(opts.headers["X-Bot-Token"], CFG.botToken);
  assert.equal(opts.headers["X-Musteri-Telefon"], "+905321234567");
  assert.deepEqual(JSON.parse(opts.body), { metin: "selam", kaynak_id: "wamid.1" });
});

test("kaynakId yoksa gövdeye eklenmez", async () => {
  const fetchImpl = sahteFetch(200, { ok: true, veri: { cevap: "ok" } });
  await mesajGonder({ ...CFG, telefon: "+905321234567", metin: "x", fetchImpl });

  assert.deepEqual(JSON.parse(fetchImpl.cagrilar[0].opts.body), { metin: "x" });
});

test("503 LLM_UNAVAILABLE -> tur=llm", async () => {
  const fetchImpl = sahteFetch(503, { ok: false, hata: { kod: "LLM_UNAVAILABLE" } });
  await assert.rejects(
    () => mesajGonder({ ...CFG, telefon: "+905321234567", metin: "x", fetchImpl }),
    (e) => e instanceof BackendHatasi && e.tur === "llm"
  );
});

test("401 -> tur=kimlik", async () => {
  const fetchImpl = sahteFetch(401, { ok: false, hata: { kod: "YETKISIZ_ISTEK" } });
  await assert.rejects(
    () => mesajGonder({ ...CFG, telefon: "+905321234567", metin: "x", fetchImpl }),
    (e) => e instanceof BackendHatasi && e.tur === "kimlik"
  );
});

test("ağ hatası -> tur=ag", async () => {
  const fetchImpl = async () => {
    throw new TypeError("fetch failed");
  };
  await assert.rejects(
    () => mesajGonder({ ...CFG, telefon: "+905321234567", metin: "x", fetchImpl }),
    (e) => e instanceof BackendHatasi && e.tur === "ag"
  );
});

test("bozuk JSON / ok:false -> tur=beklenmedik", async () => {
  const bozuk = sahteFetch(200, "<html>değil</html>");
  await assert.rejects(
    () => mesajGonder({ ...CFG, telefon: "+905321234567", metin: "x", fetchImpl: bozuk }),
    (e) => e instanceof BackendHatasi && e.tur === "beklenmedik"
  );

  const bosCevap = sahteFetch(200, { ok: true, veri: { cevap: "   " } });
  await assert.rejects(
    () => mesajGonder({ ...CFG, telefon: "+905321234567", metin: "x", fetchImpl: bosCevap }),
    (e) => e instanceof BackendHatasi && e.tur === "beklenmedik"
  );
});
