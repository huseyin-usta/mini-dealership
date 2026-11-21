/**
 * Eşleştirme sayfası: QR'ı telefondan tarayabilmek için geçici bir HTTP sunucusu.
 *
 * Terminale basılan QR, docker log'ları üzerinden bozulur; operatör telefonundan
 * tarayabilsin diye PNG sayfası sunulur. Sayfa yalnızca eşleşme beklenirken
 * açıktır; bağlantı kurulunca kapanır.
 */
import http from "node:http";
import QRCode from "qrcode";

function kacir(s) {
  return String(s).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

export function createPairingServer({
  port,
  host = "0.0.0.0",
  qrRenderer = (text) => QRCode.toDataURL(text),
  pngRenderer = (text) => QRCode.toBuffer(text),
} = {}) {
  let qrDataUrl = null;
  let pngBuffer = null;
  let pairingCode = null;
  let server = null;

  function sayfa() {
    const guvenliQr = qrDataUrl && /^data:image\//.test(qrDataUrl) ? qrDataUrl : null;
    const kod = pairingCode ? kacir(pairingCode) : "";
    const kodBlogu = kod
      ? `<div class="kod"><p class="soluk">veya telefon numarasıyla bağlan:</p>
<div class="rakamlar">${kod}</div></div>`
      : "";
    const qrBlogu = guvenliQr
      ? `<img src="${guvenliQr}" width="300" height="300" alt="QR"/>`
      : `<div class="bekle">QR bekleniyor… sayfa otomatik yenilenir.</div>`;
    return `<!doctype html><html lang="tr"><head><meta charset="utf-8"/>
<meta http-equiv="refresh" content="5"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Bayi Asistanı — WhatsApp Eşleştirme</title>
<style>body{font-family:system-ui,Arial,sans-serif;text-align:center;margin:24px;color:#222}
.kutu{display:inline-block;padding:20px;border:1px solid #eee;border-radius:12px;max-width:92vw}
.rakamlar{font-size:34px;letter-spacing:6px;font-weight:700;margin-top:8px}
.soluk{color:#666;font-size:14px;margin:12px 0 0}.bekle{color:#888;padding:120px 0}</style>
</head><body><div class="kutu">
<h2>WhatsApp Eşleştirme</h2>
<p>Telefonda <b>WhatsApp → Ayarlar → Bağlı Cihazlar → Cihaz Bağla</b> açın ve kodu tarayın.</p>
${qrBlogu}
${kodBlogu}
<p class="soluk">Bağlantı kurulunca bu sayfa kapanır.</p>
</div></body></html>`;
  }

  function isle(req, res) {
    if (req.method !== "GET") {
      res.writeHead(405, { "Content-Type": "text/plain" });
      return res.end("method not allowed");
    }
    if (req.url === "/qr.png") {
      if (!pngBuffer) {
        res.writeHead(404);
        return res.end("no qr yet");
      }
      res.writeHead(200, { "Content-Type": "image/png", "Content-Length": pngBuffer.length });
      return res.end(pngBuffer);
    }
    if (req.url === "/" || req.url === "/index.html") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(sayfa());
    }
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found");
  }

  return {
    async start() {
      if (server && server.listening) return;
      server = http.createServer(isle);
      await new Promise((cozum, red) => {
        server.once("error", red);
        server.listen(port, host, () => {
          server.off("error", red);
          server.on("error", (e) => console.error("eşleştirme sunucusu hatası:", e.message));
          cozum();
        });
      });
    },
    stop() {
      if (!server) return;
      try {
        if (server.closeAllConnections) server.closeAllConnections();
      } catch { /* en iyi çaba */ }
      server.close();
      server = null;
    },
    async setQr(text) {
      [qrDataUrl, pngBuffer] = await Promise.all([
        qrRenderer(text).catch(() => null),
        pngRenderer(text).catch(() => null),
      ]);
    },
    setPairingCode(code) {
      pairingCode = code;
    },
    get portu() {
      return server && server.address() ? server.address().port : port;
    },
    get dinliyor() {
      return !!(server && server.listening);
    },
    _sayfa: sayfa,
  };
}
