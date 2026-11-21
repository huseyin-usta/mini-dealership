/**
 * Backend istemcisi: yalnız {@code POST /bot/mesaj}.
 *
 * Köprü iş mantığı bilmez; mesajı iletir, cevabı alır. Hata türlerini anlamlı
 * biçimde ayırır ki çağıran (mesaj işleyici) müşteriye ne söyleyeceğine karar
 * verebilsin.
 */

/** Backend'e ulaşılamadı, kimlik reddedildi ya da LLM cevap veremedi. */
export class BackendHatasi extends Error {
  /**
   * @param {"ag"|"kimlik"|"llm"|"beklenmedik"} tur
   * @param {string} mesaj
   * @param {number} [durum] HTTP durum kodu (varsa)
   */
  constructor(tur, mesaj, durum) {
    super(mesaj);
    this.name = "BackendHatasi";
    this.tur = tur;
    this.durum = durum;
  }
}

/**
 * Mesajı backend'e iletir ve müşteriye gönderilecek cevabı döndürür.
 *
 * @param {object} p
 * @param {string} p.backendUrl  taban adres (sondaki / yok)
 * @param {string} p.botToken    X-Bot-Token
 * @param {string} p.telefon     E.164 (+905...)
 * @param {string} p.metin       müşteri mesajı
 * @param {string|null} [p.kaynakId] WhatsApp mesaj kimliği (idempotency)
 * @param {typeof fetch} [p.fetchImpl]
 * @param {number} [p.timeoutMs]
 * @returns {Promise<string>} cevap metni
 */
export async function mesajGonder({
  backendUrl,
  botToken,
  telefon,
  metin,
  kaynakId = null,
  fetchImpl = fetch,
  timeoutMs = 65_000,
}) {
  const govde = { metin };
  if (kaynakId) govde.kaynak_id = kaynakId;

  let yanit;
  try {
    yanit = await fetchImpl(`${backendUrl}/bot/mesaj`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "X-Bot-Token": botToken,
        "X-Musteri-Telefon": telefon,
      },
      body: JSON.stringify(govde),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (e) {
    // Zaman aşımı veya bağlantı hatası
    throw new BackendHatasi("ag", "Backend'e ulaşılamadı: " + e.message);
  }

  const metinGovde = await yanit.text();
  let cozulen = null;
  try {
    cozulen = metinGovde ? JSON.parse(metinGovde) : null;
  } catch {
    cozulen = null;
  }

  if (yanit.status === 401 || yanit.status === 403) {
    throw new BackendHatasi("kimlik", "Backend kimliği reddetti (HTTP " + yanit.status + ")", yanit.status);
  }

  if (yanit.status === 503 && cozulen?.hata?.kod === "LLM_UNAVAILABLE") {
    throw new BackendHatasi("llm", "LLM yanıt veremedi", yanit.status);
  }

  if (!yanit.ok || cozulen?.ok !== true) {
    throw new BackendHatasi(
      "beklenmedik",
      "Beklenmedik backend yanıtı (HTTP " + yanit.status + ")",
      yanit.status
    );
  }

  const cevap = cozulen?.veri?.cevap;
  if (typeof cevap !== "string" || cevap.trim().length === 0) {
    throw new BackendHatasi("beklenmedik", "Backend boş cevap döndürdü", yanit.status);
  }

  return cevap.trim();
}
