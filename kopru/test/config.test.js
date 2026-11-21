import test from "node:test";
import assert from "node:assert/strict";

import { loadConfig } from "../lib/config.js";

const TOKEN = "a".repeat(32);

test("varsayılan değerlerle yüklenir", () => {
  const cfg = loadConfig({ BOT_TOKEN: TOKEN });
  assert.equal(cfg.backendUrl, "http://127.0.0.1:8080");
  assert.equal(cfg.botToken, TOKEN);
  assert.equal(cfg.pairPort, 3000);
  assert.equal(cfg.pairPhone, "");
  assert.equal(cfg.logLevel, "warn");
});

test("BACKEND_URL'in sondaki eğik çizgileri temizlenir", () => {
  const cfg = loadConfig({ BOT_TOKEN: TOKEN, BACKEND_URL: "http://host:9000///" });
  assert.equal(cfg.backendUrl, "http://host:9000");
});

test("BOT_TOKEN yoksa veya kısaysa başlatılmaz", () => {
  assert.throws(() => loadConfig({}), /BOT_TOKEN/);
  assert.throws(() => loadConfig({ BOT_TOKEN: "kisa" }), /BOT_TOKEN/);
  assert.throws(() => loadConfig({ BOT_TOKEN: "   " }), /BOT_TOKEN/);
});

test("BACKEND_URL geçersizse açık hata verir", () => {
  assert.throws(() => loadConfig({ BOT_TOKEN: TOKEN, BACKEND_URL: "backend:8080" }), /BACKEND_URL/);
  assert.throws(() => loadConfig({ BOT_TOKEN: TOKEN, BACKEND_URL: "ftp://x" }), /BACKEND_URL/);
});

test("PAIR_PORT geçersizse hata verir", () => {
  assert.throws(() => loadConfig({ BOT_TOKEN: TOKEN, PAIR_PORT: "0" }), /PAIR_PORT/);
  assert.throws(() => loadConfig({ BOT_TOKEN: TOKEN, PAIR_PORT: "abc" }), /PAIR_PORT/);
});

test("PAIR_PHONE yalnız rakamlara indirgenir", () => {
  const cfg = loadConfig({ BOT_TOKEN: TOKEN, PAIR_PHONE: "+90 532 123 45 67" });
  assert.equal(cfg.pairPhone, "905321234567");
});
