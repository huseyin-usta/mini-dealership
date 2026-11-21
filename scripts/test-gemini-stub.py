#!/usr/bin/env python3
"""Test yardımcısı: Gemini generateContent için sahte sunucu.

Gerçek LLM çağrısı testlerde maliyetli ve kararsızdır; bu stub, backend'in araç
döngüsünü uçtan uca denemek için sabit yanıtlar üretir.

Davranış (son kullanıcı mesajındaki işarete göre):
  - "ARIZA"     -> HTTP 500 (LLM arızası)
  - "IDHATA"    -> geçersiz id ile randevu_iptal çağrısı (araç hatası yolu)
  - "BILINMEYEN"-> tanımsız araç çağrısı (halüsinasyon yolu)
  - "IKI"       -> tek turda iki araç çağrısı (paralel çağrı yolu)
  - diğer       -> musait_slotlar (gerçek /bot/slot ucunu çağırır)
İkinci turda (functionResponse geldiğinde) araç yanıtını metne gömer.

Kullanım: python3 scripts/test-gemini-stub.py <port> <tarih:YYYY-MM-DD>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
TARIH = sys.argv[2]


def parca(text=None, cagri=None, ad=None, args=None):
    if text is not None:
        return {"text": text}
    return {"functionCall": {"name": ad, "args": args or {}}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # sessiz
        pass

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        ham = self.rfile.read(n).decode("utf-8") if n else "{}"
        try:
            govde = json.loads(ham)
        except json.JSONDecodeError:
            govde = {}

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
        if fn is not None:
            sonuc = json.dumps(fn.get("response", {}), ensure_ascii=False)
            yanit_parcalari = [parca(text="ARAC_SONUC:" + sonuc[:400])]
        elif "IDHATA" in son_kullanici:
            yanit_parcalari = [parca(ad="randevu_iptal", args={"id": "1 2"})]
        elif "BILINMEYEN" in son_kullanici:
            yanit_parcalari = [parca(ad="uydurma_arac", args={})]
        elif "IKI" in son_kullanici:
            yanit_parcalari = [
                parca(ad="sube_listele", args={}),
                parca(ad="musait_slotlar", args={
                    "sube_id": 1, "tur_kodu": "TEST_SURUSU", "tarih": TARIH}),
            ]
        else:
            yanit_parcalari = [parca(ad="musait_slotlar", args={
                "sube_id": 1, "tur_kodu": "TEST_SURUSU", "tarih": TARIH})]

        yanit = {"candidates": [{"content": {"role": "model", "parts": yanit_parcalari},
                                 "finishReason": "STOP"}]}
        govde_bytes = json.dumps(yanit, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(govde_bytes)))
        self.end_headers()
        self.wfile.write(govde_bytes)


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
