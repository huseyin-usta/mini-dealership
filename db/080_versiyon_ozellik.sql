-- Versiyon özellikleri: versiyon başına çok değerli nitelik (ör. 'koltuk' = 'deri').
-- Ara rapor Tablo 2: silinen versiyonla birlikte silinir (CASCADE).
CREATE TABLE versiyon_ozellik (
    versiyon_id integer      NOT NULL REFERENCES versiyon ON DELETE CASCADE,
    ozellik_adi varchar(64)  NOT NULL,
    deger       varchar(128) NOT NULL,
    PRIMARY KEY (versiyon_id, ozellik_adi)
);
