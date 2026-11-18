-- Müşterinin kendi servis durumu: WhatsApp botu müşteri "arabam ne durumda?"
-- diye sorduğunda yalnızca o müşterinin açık/kapalı servis kaydını görür.
--
-- Güvenlik: satırlar fn_aktif_musteri_id() ile süzülür. Bu fonksiyon, oturumdaki
-- app.musteri_telefon değişkeninden (transaction başına SET LOCAL ile yazılır)
-- müşteri kimliğini çözer; değişken yoksa NULL döner ve view hiçbir satır göstermez
-- (fail-closed). Bot başka müşterinin kaydını göremez.
--
-- PII/hassas alanlar dışarıda:
--   * masraf/ücret kolonları YOK (spec: masraf ve ödeme servisten teslimde kapanır,
--     bot müşteriye tutar bildirmez)
--   * sorumlu çalışan kimliği YOK (bot çalışan ataması görmez)
--   * giriş/çıkış kilometresi YOK (yalnızca durum takibi için gerekli)
--
-- security_barrier: sorguya eklenen filtreler, satır süzme uygulanmadan önce ham
-- satırlara erişip veri sızdıramaz.
CREATE VIEW v_musteri_servis_durumu
WITH (security_barrier = true)
AS
SELECT sd.servis_kaydi_id,
       sd.sube_id,
       sd.arac_vin,
       sd.sebep,
       sd.son_durum,
       sd.son_durum_zamani,
       sd.tahmini_teslim_tarihi,
       sd.kalan_gun,
       sd.gecikti_mi,
       sd.kapandi_mi
  FROM v_servis_durumu sd
 WHERE sd.musteri_id = fn_aktif_musteri_id();

COMMENT ON VIEW v_musteri_servis_durumu IS
    'Bot için müşteriye özel servis durumu: masraf ve çalışan bilgisi içermez, '
    'yalnızca konuşulan müşterinin satırlarını gösterir.';

-- Bot bu view'ı okur. Base tablolara (servis_kaydi, servis_islem) erişimi yoktur;
-- view security_barrier ile çalışır ve satırları fn_aktif_musteri_id() ile süzer.
GRANT SELECT ON v_musteri_servis_durumu TO bot;

-- Diğer view'larla aynı sahiplik değişmezi (420'deki ALTER ... OWNER döngüsü bu
-- dosyadan önce çalıştığı için burada ayrıca yapılır).
ALTER VIEW v_musteri_servis_durumu OWNER TO admin;
