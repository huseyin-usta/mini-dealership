-- Randevu Türü: şubelerde verilebilen standart randevu tipleri ve kuralları.
-- Süre ve departman bilgisi içerir; gerekiyorsa yetkinlik şartı koşar (ör. test sürüşü).
CREATE TABLE randevu_turu (
    tur_kodu     varchar(32) PRIMARY KEY,                         -- ör. 'TEST_SURUSU', 'PERIYODIK_BAKIM'
    ad           varchar(64) NOT NULL,                            -- ör. 'Test Sürüşü', 'Periyodik Bakım'
    sure_dakika  smallint    NOT NULL CHECK (sure_dakika > 0),    -- standart süre (30 veya 60 dk)
    departman    varchar(10) NOT NULL CHECK (departman IN ('SATIS', 'SERVIS')),
    yetkinlik_id integer     REFERENCES yetkinlik                 -- gereken yetkinlik varsa FK, yoksa NULL
);

