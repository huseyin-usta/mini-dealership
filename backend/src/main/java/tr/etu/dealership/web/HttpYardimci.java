package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import tr.edu.etu.dealership.db.Veritabani;

/** Operasyonel yardımcı endpoint'ler (LLM'e açık değil; izleme için). */
public final class HttpYardimci {

    private HttpYardimci() {
    }

    /**
     * {@code GET /saglik} — veritabanı erişilebilir mi?
     *
     * <p>Kimlik doğrulaması istemez (konteyner sağlık kontrolü içindir) ve
     * yalnızca iki kelimeden birini döndürür; veri ya da sır sızdırmaz.
     * {@code HEAD} desteklenir (sağlık kontrol araçları gövdesiz yoklama yapar);
     * diğer yöntemler ve tanımsız alt yollar reddedilir.
     */
    public static HttpHandler saglik(Veritabani db) {
        return (HttpExchange ex) -> {
            try {
                String yol = ex.getRequestURI().getPath();
                if (!ex.getHttpContext().getPath().equals(yol)) {
                    JsonYanit.yazMetin(ex, 404, "bulunamadı");
                    return;
                }

                String yontem = ex.getRequestMethod();
                boolean head = "HEAD".equals(yontem);
                if (!"GET".equals(yontem) && !head) {
                    ex.getResponseHeaders().set("Allow", "GET, HEAD");
                    JsonYanit.yazMetin(ex, 405, "yöntem desteklenmiyor");
                    return;
                }

                boolean hazir = db.hazirMi();
                if (head) {
                    ex.sendResponseHeaders(hazir ? 200 : 503, -1);
                    return;
                }
                JsonYanit.yazMetin(ex, hazir ? 200 : 503,
                        hazir ? "ok" : "db erişilemiyor");
            } finally {
                ex.close();
            }
        };
    }
}
