-- Model: bayinin sattığı araç modeli. Bayi tek markalı olduğundan marka sütunu yok (miniworld kuralı).
-- Garanti süresi modele göre değişir (yıl ve km).
CREATE TABLE model (
    model_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ad          varchar(128) NOT NULL UNIQUE,   -- ör. 'Tucson'
    garanti_yil smallint     NOT NULL CHECK (garanti_yil > 0),
    garanti_km  integer      NOT NULL CHECK (garanti_km > 0)
);
