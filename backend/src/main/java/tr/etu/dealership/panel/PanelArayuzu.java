package tr.edu.etu.dealership.panel;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Panel arayüzünün statik dosyaları ({@code panel/} klasörü JAR'a
 * {@code panel/} olarak gömülür; bkz. pom.xml). Aynı adresten servis edildiği
 * için CORS gerekmez ve oturum anahtarı başka bir kökene gitmez.
 *
 * <p>Yalnızca beyaz listedeki uzantılar ve {@code [a-z0-9-/]} karakterli yollar
 * sunulur: {@code ..} ile classpath'te gezinmek mümkün değildir. Sıkı bir
 * Content-Security-Policy ile satır içi betik ve dış kaynak yasaktır.
 */
public final class PanelArayuzu implements HttpHandler {

    private static final Pattern YOL = Pattern.compile("/(?:[a-z0-9-]+/)*[a-z0-9-]+\\.(?:html|css|js|svg)");
    private static final Map<String, String> TURLER = Map.of(
            "html", "text/html; charset=utf-8",
            "css", "text/css; charset=utf-8",
            "js", "text/javascript; charset=utf-8",
            "svg", "image/svg+xml");
    private static final String CSP = "default-src 'self'; script-src 'self'; style-src 'self'; "
            + "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; "
            + "base-uri 'none'; form-action 'self'";

    @Override
    public void handle(HttpExchange ex) throws IOException {
        try {
            String yontem = ex.getRequestMethod();
            boolean head = "HEAD".equals(yontem);
            if (!"GET".equals(yontem) && !head) {
                ex.getResponseHeaders().set("Allow", "GET, HEAD");
                metin(ex, 405, "yöntem desteklenmiyor", false);
                return;
            }
            String yol = ex.getRequestURI().getPath();
            if ("/".equals(yol)) yol = "/index.html";
            if (!YOL.matcher(yol).matches()) {
                metin(ex, 404, "bulunamadı", head);
                return;
            }
            byte[] icerik;
            try (InputStream in = PanelArayuzu.class.getResourceAsStream("/panel" + yol)) {
                if (in == null) {
                    metin(ex, 404, "bulunamadı", head);
                    return;
                }
                icerik = in.readAllBytes();
            }
            String uzanti = yol.substring(yol.lastIndexOf('.') + 1);
            var b = ex.getResponseHeaders();
            b.set("Content-Type", TURLER.get(uzanti));
            b.set("Content-Security-Policy", CSP);
            b.set("X-Content-Type-Options", "nosniff");
            b.set("Referrer-Policy", "no-referrer");
            b.set("Cache-Control", "no-cache");
            if (head) {
                ex.sendResponseHeaders(200, -1);
                return;
            }
            ex.sendResponseHeaders(200, icerik.length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(icerik);
            }
        } finally {
            ex.close();
        }
    }

    private static void metin(HttpExchange ex, int durum, String metin, boolean head) throws IOException {
        byte[] g = metin.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
        ex.getResponseHeaders().set("X-Content-Type-Options", "nosniff");
        if (head) {
            ex.sendResponseHeaders(durum, -1);
            return;
        }
        ex.sendResponseHeaders(durum, g.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(g);
        }
    }
}
