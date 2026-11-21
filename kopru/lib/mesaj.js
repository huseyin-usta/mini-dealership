/**
 * Gelen mesaj akışı: müşteriye ne zaman ne söyleneceğine karar veren tek yer.
 *
 * Baileys'e bağımlı değildir; testte sahte {@code gonder} ve sahte {@code fetch}
 * ile çalışır.
 */
import { BackendHatasi, mesajGonder } from "./backend.js";

/** Backend'e ulaşılamadığında / LLM cevap veremediğinde gönderilen metin. */
export const YEDEK_CEVAP = "Şu an yanıt veremiyorum, birazdan tekrar deneyin.";

/** Metin dışı mesajlara verilen kısa yanıt. */
export const MEDYA_CEVABI = "Şu an yalnızca yazılı mesajlara yanıt verebiliyorum.";

/**
 * @param {object} p
 * @param {object} p.cfg            loadConfig çıktısı
 * @param {string} p.jid            cevabın gönderileceği WhatsApp JID'si
 * @param {string} p.sender         müşteri telefonu (E.164) — JID'den türetilir
 * @param {string|null} p.metin     müşteri metni (medya ise null)
 * @param {string|null} [p.kaynakId] WhatsApp mesaj kimliği (idempotency)
 * @param {(jid: string, metin: string) => Promise<void>} p.gonder
 * @param {typeof fetch} [p.fetchImpl]
 * @param {{warn: Function, error: Function}} [p.log]
 * @returns {Promise<{durum: string, cevap?: string}>}
 */
export async function gelenMesajiIsle({
  cfg,
  jid,
  sender,
  metin,
  kaynakId = null,
  gonder,
  fetchImpl = fetch,
  log = console,
}) {
  if (!metin) {
    // Fotoğraf/ses/sticker: metin yok. Sessiz kalmak yerine kısa bilgi ver.
    await guvenliGonder(gonder, jid, MEDYA_CEVABI, log);
    return { durum: "medya" };
  }

  let cevap;
  try {
    cevap = await mesajGonder({
      backendUrl: cfg.backendUrl,
      botToken: cfg.botToken,
      telefon: sender,
      metin,
      kaynakId,
      fetchImpl,
    });
  } catch (e) {
    if (e instanceof BackendHatasi) {
      log.warn(`Backend hatası (${e.tur}): ${e.message}`);
      await guvenliGonder(gonder, jid, YEDEK_CEVAP, log);
      return { durum: e.tur };
    }
    log.error("Beklenmedik hata:", e);
    await guvenliGonder(gonder, jid, YEDEK_CEVAP, log);
    return { durum: "beklenmedik" };
  }

  await guvenliGonder(gonder, jid, cevap, log);
  return { durum: "cevaplandi", cevap };
}

async function guvenliGonder(gonder, jid, metin, log) {
  try {
    await gonder(jid, metin);
  } catch (e) {
    // Gönderim hatası akışı düşürmesin; log'da kalsın.
    log.error("Cevap gönderilemedi:", e);
  }
}
