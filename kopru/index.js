/**
 * WhatsApp köprüsü — giriş noktası.
 *
 * Görevi iki şeydir: WhatsApp oturumunu ayakta tutmak ve gelen metni backend'e
 * iletip cevabı müşteriye yazmak. İş mantığı (müsaitlik, randevu, LLM) backend'de;
 * köprü veritabanına dokunmaz.
 */
import "dotenv/config";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import makeWASocket, {
  DisconnectReason,
  fetchLatestBaileysVersion,
  makeCacheableSignalKeyStore,
  useMultiFileAuthState,
} from "@whiskeysockets/baileys";
import P from "pino";
import qrcode from "qrcode-terminal";

import { loadConfig } from "./lib/config.js";
import { createPairingServer } from "./lib/pairing.js";
import { gelenMesajiIsle } from "./lib/mesaj.js";
import { islenecekMesajlar, toE164 } from "./lib/sender.js";

const KOK = path.dirname(fileURLToPath(import.meta.url));
const AUTH_DIR = path.join(KOK, "auth");

const cfg = loadConfig();
const log = P({ level: cfg.logLevel });

let eslestirme = null;
let eslestirmeSozu = null;
let kodIstendi = false;
let soket = null;

/** Eşleştirme sayfasını (gerekirse) açar. Eşzamanlı çağrılar aynı sözü paylaşır. */
function eslestirmeBaslat() {
  if (eslestirme) return Promise.resolve(eslestirme);
  if (eslestirmeSozu) return eslestirmeSozu;

  eslestirmeSozu = (async () => {
    const sunucu = createPairingServer({ port: cfg.pairPort });
    try {
      await sunucu.start();
      console.log(`🔗 Eşleştirme sayfası: http://<bu-cihaz>:${sunucu.portu}/`);
      eslestirme = sunucu;
      return sunucu;
    } catch (e) {
      console.error(`⚠️ Eşleştirme sayfası ${cfg.pairPort} portunda açılamadı: ${e.message}`);
      return null;
    } finally {
      eslestirmeSozu = null;
    }
  })();

  return eslestirmeSozu;
}

function eslestirmeDurdur() {
  if (!eslestirme) return;
  eslestirme.stop();
  eslestirme = null;
  kodIstendi = false;
  console.log("🔒 Eşleştirme sayfası kapatıldı.");
}

/** QR geldikçe sayfayı tazeler; numarayla eşleştirme kodunu bir kez ister. */
async function qrIsle(qr) {
  const sunucu = await eslestirmeBaslat();
  if (!sunucu) return;
  await sunucu.setQr(qr).catch(() => {});

  if (cfg.pairPhone && !kodIstendi && typeof soket?.requestPairingCode === "function") {
    kodIstendi = true;
    try {
      const kod = await soket.requestPairingCode(cfg.pairPhone);
      sunucu.setPairingCode(kod);
      console.log(`🔑 Eşleştirme kodu (alternatif): ${kod}`);
    } catch (e) {
      console.warn("⚠️ Eşleştirme kodu alınamadı:", e.message);
    }
  }
}

/** Baileys bağlantı olayları: QR, kapanma, açılma. */
function baglantiGuncelle(update, sock) {
  const { connection, lastDisconnect, qr } = update;

  if (qr) {
    // Beklenmez: QR terminale de basılmalı, sayfa açılamasa bile.
    qrIsle(qr).catch((e) => console.error("eşleştirme hatası:", e.message));
    console.log("\n📱 QR'ı WhatsApp'tan tarayın:\n");
    qrcode.generate(qr, { small: true });
  }

  if (connection === "close") {
    const kod = lastDisconnect?.error?.output?.statusCode;
    const yeniden = kod !== DisconnectReason.loggedOut;
    console.log(`Bağlantı kapandı [${kod}]. Yeniden bağlanma: ${yeniden}`);
    if (yeniden) {
      sock?.ev?.removeAllListeners?.();
      setTimeout(() => baslat().catch((e) => console.error("Yeniden bağlanma hatası:", e)), 2000);
    } else {
      // Oturum geçersiz: eski QR'ı göstermeye devam etmenin anlamı yok.
      eslestirmeDurdur();
    }
  } else if (connection === "open") {
    console.log(`✅ WhatsApp bağlandı: ${soket?.user?.id ?? ""}`);
    eslestirmeDurdur();
  }
}

async function baslat() {
  fs.mkdirSync(AUTH_DIR, { recursive: true });

  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
  const { version } = await fetchLatestBaileysVersion();

  soket = makeWASocket({
    version,
    auth: {
      creds: state.creds,
      keys: makeCacheableSignalKeyStore(state.keys, log),
    },
    logger: log,
    markOnlineOnConnect: false,
    syncFullHistory: false,
  });

  soket.ev.on("creds.update", saveCreds);
  soket.ev.on("connection.update", (update) => baglantiGuncelle(update, soket));

  soket.ev.on("messages.upsert", async (olay) => {
    if (olay.type !== "notify") return;
    // Teşhis: yalnızca LOG_LEVEL=debug iken ham JID alanlarını gör (içerik loglanmaz).
    if (cfg.logLevel === "debug") {
      for (const ham of olay.messages || []) {
        if (ham.key?.fromMe) continue;
        console.log(`🔎 jid=${ham.key?.remoteJid} alt=${ham.key?.remoteJidAlt} partAlt=${ham.key?.participantAlt}`);
      }
    }
    // Sıralı işlenir: aynı müşterinin iki mesajı birbirini kesmesin.
    for (const m of islenecekMesajlar(olay.messages)) {
      let sender = m.sender;
      if (!sender) {
        // WhatsApp LID gönderdiyse ve mesajda PN (remoteJidAlt) yoksa,
        // oturumdaki LID→PN eşlemesinden çözmeyi dene.
        try {
          const pn = await soket.signalRepository?.lidMapping?.getPNForLID(m.jid);
          sender = pn ? toE164(pn) : null;
        } catch (e) {
          log.warn(`LID çözümlenemedi: ${e.message}`);
        }
      }
      if (!sender) {
        console.log(`⚠️ Kimlik çözülemedi, mesaj atlandı: ${m.jid}`);
        continue;
      }
      console.log(`📩 [${sender}] ${m.metin ?? "(medya)"}`);
      await gelenMesajiIsle({
        cfg,
        jid: m.jid,
        sender,
        metin: m.metin,
        kaynakId: m.kaynakId,
        gonder: (jid, metin) => soket.sendMessage(jid, { text: metin }),
        log,
      });
    }
  });
}

for (const sinyal of ["SIGINT", "SIGTERM"]) {
  process.on(sinyal, () => {
    console.log("\nKapatılıyor…");
    eslestirmeDurdur();
    try {
      soket?.end?.(undefined);
    } catch { /* en iyi çaba */ }
    process.exit(0);
  });
}

baslat().catch((e) => {
  console.error("Köprü başlatılamadı:", e.message);
  process.exit(1);
});
