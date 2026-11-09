-- Tür Saat: bir randevu türünün haftanın hangi günü, hangi saat aralıklarında
-- verilebileceğini tanımlar (ör. test sürüşü Cumartesi 10:00-12:00 ve 14:00-16:00).
-- Randevu türü silinirse tanımlı saat aralıkları da silinir (CASCADE).
CREATE TABLE tur_saat (
    tur_kodu  varchar(32) NOT NULL REFERENCES randevu_turu ON DELETE CASCADE,
    gun       smallint    NOT NULL REFERENCES mesai(gun),
    baslangic time        NOT NULL,
    bitis     time        NOT NULL,
    PRIMARY KEY (tur_kodu, gun, baslangic),
    CHECK (baslangic < bitis)
);

