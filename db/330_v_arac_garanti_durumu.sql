-- Aracın bugünkü garanti durumu (türetilmiş nitelik, saklanmaz).
-- Mantık trg_servis_islem_garanti (210) ile aynıdır, ancak tek bir servis anı
-- yerine "bugün" itibarıyla hesaplanır:
--   * Garanti ilk SATIS stok hareketinde başlar; model garanti_yil / garanti_km geçerli
--   * Periyodik bakım aralığı sabit: 1 yıl / 15.000 km (satıştan itibaren, 0 km'den)
--   * İptal edilen / gelinmeyen / henüz gerçekleşmemiş randevuların servis kayıtları sayılmaz
--   * Aracın kilometresi tutulmaz; son bilinen km = en son servis girişindeki km
-- Ardışık bakımlar arasındaki fark LAG window function'ı ile bulunur.
-- Yalnızca satılmış (satış kaydı olan) araçlar listelenir. PII içermez.
--
-- NOT MATERIALIZED: satis ve gecerli_servis birden çok yerde kullanıldığı için
-- PostgreSQL bunları varsayılan olarak bir kez, TÜM araçlar için hesaplar
-- (CTE Scan); `WHERE vin = ...` filtresi içeri inemez ve tek araç sorgusu
-- ~166 ms sürer. Satır içine alınınca filtre GROUP BY / PARTITION BY arac_vin
-- üzerinden indekslere iner: tek araç ~4 ms, tüm araçlar ~490 → ~550 ms
-- (docs/analiz/indeks-analizi.md §7).
CREATE VIEW v_arac_garanti_durumu AS
WITH satis AS NOT MATERIALIZED (
    SELECT arac_vin, min(zaman)::timestamp AS satis_zamani
      FROM stok_hareketi
     WHERE hareket_turu = 'SATIS'
     GROUP BY arac_vin
),
gecerli_servis AS NOT MATERIALIZED (
    SELECT r.arac_vin, r.baslangic, sk.giris_kilometresi AS km, sk.sebep
      FROM servis_kaydi sk
      JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id
     WHERE r.durum NOT IN ('IPTAL', 'GELMEDI')
       AND r.baslangic <= localtimestamp   -- henüz gerçekleşmemiş (planlı) servisler sayılmaz
),
-- Bakım zinciri: satış anı (0 km) + satıştan sonraki her bakım
bakim_zinciri AS (
    SELECT arac_vin, satis_zamani AS zaman, 0 AS km FROM satis
    UNION ALL
    SELECT g.arac_vin, g.baslangic, g.km
      FROM gecerli_servis g
      JOIN satis s ON s.arac_vin = g.arac_vin
     WHERE g.sebep = 'BAKIM' AND g.baslangic >= s.satis_zamani
),
bakim_araliklari AS (
    SELECT arac_vin, zaman, km,
           LAG(zaman) OVER w AS onceki_zaman,
           LAG(km)    OVER w AS onceki_km
      FROM bakim_zinciri
    WINDOW w AS (PARTITION BY arac_vin ORDER BY zaman)
),
bakim_ozet AS (
    SELECT arac_vin,
           max(zaman) AS son_bakim_zamani,
           -- en son bakımın km'si (aynı zincirde en geç zaman)
           (array_agg(km ORDER BY zaman DESC))[1] AS son_bakim_km,
           -- zincirin ilk satırında (satış) LAG NULL'dır; bakım yoksa false
           coalesce(bool_or(zaman > onceki_zaman + interval '1 year'
                            OR km - onceki_km > 15000), false) AS gecmiste_aksatildi
      FROM bakim_araliklari
     GROUP BY arac_vin
),
son_km AS (
    SELECT g.arac_vin, max(g.km) AS son_bilinen_km
      FROM gecerli_servis g
     GROUP BY g.arac_vin
)
SELECT a.vin,
       a.plaka,
       a.musteri_id,
       m.ad                                              AS model_adi,
       s.satis_zamani::date                              AS garanti_baslangic,
       (s.satis_zamani + make_interval(years => m.garanti_yil))::date AS garanti_bitis,
       m.garanti_km,
       coalesce(k.son_bilinen_km, 0)                     AS son_bilinen_km,
       b.son_bakim_zamani::date                          AS son_bakim_tarihi,
       (b.son_bakim_zamani + interval '1 year')::date    AS sonraki_bakim_son_tarih,
       b.son_bakim_km + 15000                            AS sonraki_bakim_son_km,
       CASE
           WHEN localtimestamp > s.satis_zamani + make_interval(years => m.garanti_yil)
               THEN 'SURE_DOLDU'
           WHEN coalesce(k.son_bilinen_km, 0) > m.garanti_km
               THEN 'KM_ASILDI'
           WHEN b.gecmiste_aksatildi
                OR localtimestamp > b.son_bakim_zamani + interval '1 year'
                OR coalesce(k.son_bilinen_km, 0) - b.son_bakim_km > 15000
               THEN 'BAKIM_AKSATILDI'
           ELSE 'GECERLI'
       END                                               AS garanti_durumu
  FROM arac a
  JOIN satis s       ON s.arac_vin = a.vin
  JOIN versiyon v    ON v.versiyon_id = a.versiyon_id
  JOIN model m       ON m.model_id = v.model_id
  JOIN bakim_ozet b  ON b.arac_vin = a.vin
  LEFT JOIN son_km k ON k.arac_vin = a.vin;
