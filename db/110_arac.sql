-- Araç: VIN ile tek kayıt; stoktaki, yoldaki ve satılmış araçlar aynı yerde.
-- Renk + versiyon + model bilgisi birlikte aracın kimliğini kurar.
CREATE TABLE arac (
    vin                  varchar(17) PRIMARY KEY CHECK (char_length(vin) = 17),
    versiyon_id          integer     NOT NULL REFERENCES versiyon,
    sube_id              integer     NOT NULL REFERENCES sube,  -- kayıtlı olduğu şube (satıldıysa satışın yapıldığı şube)
    renk                 varchar(32) NOT NULL,
    plaka                varchar(16) UNIQUE,  -- teslimde takılır; YOLDA/STOKTA iken NULL olabilir
    durum                varchar(10) NOT NULL CHECK (durum IN ('YOLDA', 'STOKTA', 'SATILDI')),
    tahmini_varis_tarihi date,
    musteri_id           integer REFERENCES musteri,   -- sahip; yalnızca SATILDI'da dolu
    -- Duruma göre zorunlu alanlar (ara rapor Tablo 2):
    -- YOLDA ise tahmini varış tarihi var; değilse yok.
    CHECK ((durum = 'YOLDA') = (tahmini_varis_tarihi IS NOT NULL)),
    -- SATILDI ise sahibi ve plakası var; değilse sahip boş.
    CHECK ((durum = 'SATILDI') = (musteri_id IS NOT NULL)),
    CHECK (durum <> 'SATILDI' OR plaka IS NOT NULL)
);
