#!/usr/bin/env python3
"""Test yardımcısı: sahte LLM sunucusu (Gemini VE OpenAI/Mistral biçimi).

Gerçek LLM çağrısı testlerde maliyetli ve kararsızdır; bu stub, backend'in araç
döngüsünü uçtan uca denemek için sabit yanıtlar üretir. İki protokolü de konuşur:

  POST /v1beta/models/<model>:generateContent   (Gemini biçimi)
  POST /v1/chat/completions                     (OpenAI/Mistral biçimi)

Davranış (son kullanıcı mesajındaki işarete göre):
  - "ARIZA"      -> HTTP 500 (LLM arızası)
  - "IDHATA"     -> geçersiz id ile randevu_iptal çağrısı
  - "BILINMEYEN" -> tanımsız araç çağrısı
  - "IKI"        -> tek turda iki araç çağrısı
  - diğer        -> musait_slotlar
Araç sonucu geldiğinde (functionResponse / role=tool) yanıtı metne gömer.

Kullanım: python3 scripts/test-gemini-stub.py <port> <tarih:YYYY-MM-DD>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
TARIH = sys.argv[2]


def secim(marker_text, arac_sonucu):
    """(metin, [arac_adlari]) döndürür."""
    if arac_sonucu is not None:
        return "ARAC_SONUC:" + arac_sonucu[:400], []
    if "IDHATA" in marker_text:
        return "", [("randevu_iptal", {"id": "1 2"})]
    if "BILINMEYEN" in marker_text:
        return "", [("uydurma_arac", {})]
    if "IKI" in marker_text:
        return "", [("sube_listele", {}),
                    ("musait_slotlar", {"sube_id": 1, "tur_kodu": "TEST_SURUSU",
                                        "tarih": TARIH})]
    return "", [("musait_slotlar", {"sube_id": 1, "tur_kodu": "TEST_SURUSU",
                                    "tarih": TARIH})]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, kod, govde):
        veri = json.dumps(govde, ensure_ascii=False).encode("utf-8")
        self.send_response(kod)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(veri)))
        self.end_headers()
        self.wfile.write(veri)

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        ham = self.rfile.read(n).decode("utf-8") if n else "{}"
        try:
            govde = json.loads(ham)
        except json.JSONDecodeError:
            govde = {}

        if self.path.rstrip("/").endswith("/chat/completions"):
            self.openai(govde)
        else:
            self.gemini(govde)

    # --- OpenAI / Mistral biçimi -------------------------------------------

    def openai(self, govde):
        mesajlar = govde.get("messages", [])
        son_kullanici = ""
        for m in reversed(mesajlar):
            if m.get("role") == "user":
                son_kullanici = json.dumps(m.get("content", ""), ensure_ascii=False)
                break
        arac_mesajlari = [m for m in mesajlar if m.get("role") == "tool"]

        if "ARIZA" in son_kullanici:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'{"error":"stub-ariza"}')
            return

        arac_sonucu = arac_mesajlari[-1].get("content") if arac_mesajlari else None
        metin, cagrilar = secim(son_kullanici, arac_sonucu)

        mesaj = {"role": "assistant", "content": metin or None}
        if cagrilar:
            mesaj["tool_calls"] = [
                {"id": "call_%d" % i, "type": "function",
                 "function": {"name": ad, "arguments": json.dumps(args, ensure_ascii=False)}}
                for i, (ad, args) in enumerate(cagrilar)
            ]
        self._json(200, {"choices": [{"index": 0, "message": mesaj,
                                      "finish_reason": "stop"}]})

    # --- Gemini biçimi ------------------------------------------------------

    def gemini(self, govde):
        icerikler = govde.get("contents", [])
        parcalar = [p for c in icerikler for p in c.get("parts", [])]

        son_kullanici = ""
        for c in reversed(icerikler):
            if c.get("role") == "user":
                son_kullanici = json.dumps(c.get("parts", []), ensure_ascii=False)
                break

        if "ARIZA" in son_kullanici:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'{"error":"stub-ariza"}')
            return

        fn = next((p["functionResponse"] for p in parcalar if "functionResponse" in p), None)
        arac_sonucu = json.dumps(fn.get("response", {}), ensure_ascii=False) if fn else None
        metin, cagrilar = secim(son_kullanici, arac_sonucu)

        yanit_parcalari = []
        if metin:
            yanit_parcalari.append({"text": metin})
        for ad, args in cagrilar:
            yanit_parcalari.append({"functionCall": {"name": ad, "args": args}})

        self._json(200, {"candidates": [{"content": {"role": "model",
                                                     "parts": yanit_parcalari},
                                         "finishReason": "STOP"}]})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
