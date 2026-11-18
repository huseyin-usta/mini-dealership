package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import tr.edu.etu.dealership.db.Veritabani;

import java.io.IOException;

/** Operasyonel yardımcı endpoint'ler (LLM'e açık değil; izleme için). */
public final class HttpYardimci {

    private HttpYardimci() {
    }

    /** {@code GET /saglik} — veritabanı erişilebilir mi? */
    public static HttpHandler saglik(Veritabani db) {
        return (HttpExchange ex) -> {
            try {
                if (db.hazirMi()) {
                    JsonYanit.yazMetin(ex, 200, "ok");
                } else {
                    JsonYanit.yazMetin(ex, 503, "db erişilemiyor");
                }
            } finally {
                ex.close();
            }
        };
    }
}
