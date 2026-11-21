/**
 * Köprü yapılandırması. Tüm değerler ortam değişkeninden gelir; repoda sır yok.
 *
 * BACKEND_URL  backend taban adresi (varsayılan http://127.0.0.1:8080)
 * BOT_TOKEN    backend ile paylaşılan sır (zorunlu, en az 32 karakter)
 * PAIR_PORT    eşleştirme sayfası portu (varsayılan 3000)
 * PAIR_PHONE   numarayla eşleştirme için telefon (E.164, + olmadan; opsiyonel)
 * LOG_LEVEL    pino seviyesi (varsayılan warn)
 */

/** Backend'in beklediği en kısa token uzunluğu (Ayarlar.gizli ile aynı). */
const ASGARI_TOKEN = 32;

export function loadConfig(env = process.env) {
  const backendUrl = (env.BACKEND_URL || "http://127.0.0.1:8080").trim().replace(/\/+$/, "");

  let url;
  try {
    url = new URL(backendUrl);
  } catch {
    throw new Error("BACKEND_URL geçerli bir adres değil: " + backendUrl);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("BACKEND_URL http(s) olmalı: " + backendUrl);
  }

  const botToken = (env.BOT_TOKEN || "").trim();
  if (botToken.length < ASGARI_TOKEN) {
    throw new Error(
      "BOT_TOKEN tanımlı değil veya " + ASGARI_TOKEN +
      " karakterden kısa (openssl rand -hex 24 ile üretin)."
    );
  }

  const pairPort = Number(env.PAIR_PORT || 3000);
  if (!Number.isInteger(pairPort) || pairPort < 1 || pairPort > 65535) {
    throw new Error("PAIR_PORT geçersiz: " + env.PAIR_PORT);
  }

  return {
    backendUrl,
    botToken,
    pairPort,
    pairPhone: (env.PAIR_PHONE || "").replace(/\D/g, ""),
    logLevel: (env.LOG_LEVEL || "warn").trim(),
  };
}
