-- Maskeleme fonksiyonları: rapor view'larında müşteri PII'sini gizler.
-- Rapor rolü müşteri tablosunu doğrudan okuyamaz; ad ve telefonu yalnızca
-- bu fonksiyonlardan geçmiş haliyle (maskeli view'lardan) görür.

-- Telefon: son 10 hane alınır, ilk 3 ve son 2 hane görünür.
-- ör. '+905321234567' -> '0532 *** ** 67'. Ayrıştırılamayan numara tamamen gizlenir.
CREATE OR REPLACE FUNCTION fn_maskele_telefon(p_telefon text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN char_length(d) >= 10
            THEN '0' || substr(right(d, 10), 1, 3) || ' *** ** ' || right(d, 2)
        ELSE '*** *** ** **'
    END
    FROM (SELECT regexp_replace(p_telefon, '\D', '', 'g') AS d) AS t
$$;

-- Ad / soyad: ilk harf görünür, gerisi sabit uzunlukta yıldız
-- (uzunluk sabit tutulur ki ismin harf sayısı sızmasın). ör. 'Ayşe' -> 'A***'.
CREATE OR REPLACE FUNCTION fn_maskele_ad(p_ad text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN char_length(btrim(p_ad)) = 0 THEN '***'
        ELSE upper(left(btrim(p_ad), 1)) || '***'
    END
$$;
