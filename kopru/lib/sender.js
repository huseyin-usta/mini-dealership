/**
 * WhatsApp mesajından gönderen kimliğini ve metni çıkarma.
 *
 * Kimlik kuralı (backend sözleşmesi): müşteri telefonu **WhatsApp JID'sinden**
 * türetilir, asla mesaj içeriğinden veya LLM'den. Grup mesajları işlenmez;
 * grup JID'si kişi yerine grubu temsil eder.
 */

/** JID'den E.164 telefon üretir; geçersizse null. */
export function toE164(raw) {
  if (raw === null || raw === undefined) return null;
  // Cihaz eki (:12) ve alan adı (@s.whatsapp.net) atılır.
  const digits = String(raw).split("@")[0].split(":")[0].replace(/\D/g, "");
  if (digits.length < 8 || digits.length > 15) return null;
  return "+" + digits;
}

/**
 * Mesajın göndericisini döndürür: {@code +905321234567} veya {@code null}.
 * Grup mesajları ({@code @g.us}) işlenmez.
 */
export function resolveSender(jid, participant) {
  if (!jid) return null;
  // Grup, durum (status@broadcast) ve kanal mesajları kişi adına değildir.
  if (jid.endsWith("@g.us") || jid.endsWith("@broadcast") || jid.endsWith("@newsletter")) {
    return null;
  }
  return toE164(participant || jid);
}

/** Baileys mesajındaki düz metni döndürür; metin yoksa (medya vb.) null. */
export function extractText(message) {
  if (!message) return null;
  const ham =
    message.conversation ??
    message.extendedTextMessage?.text ??
    message.imageMessage?.caption ??
    null;
  if (typeof ham !== "string") return null;
  const temiz = ham.replace(/\s+/g, " ").trim();
  return temiz.length === 0 ? null : temiz;
}

/**
 * Baileys {@code messages.upsert} olayından işlenecek mesajları süzer:
 * kendi gönderdiğimiz (fromMe) ve grup mesajları elenir.
 */
export function islenecekMesajlar(messages) {
  const sonuc = [];
  for (const msg of messages || []) {
    if (!msg || msg.key?.fromMe) continue;
    const jid = msg.key?.remoteJid;
    const sender = resolveSender(jid, msg.key?.participant);
    if (!sender) continue;
    sonuc.push({
      jid,
      sender,
      metin: extractText(msg.message),
      kaynakId: msg.key?.id ?? null,
    });
  }
  return sonuc;
}
