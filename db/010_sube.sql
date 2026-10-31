-- Şube: bayi ağının farklı şehirlerdeki birimleri.
CREATE TABLE sube (
    sube_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sehir    varchar(64)  NOT NULL,
    ad       varchar(128) NOT NULL,
    -- Aynı şehirde aynı ada sahip iki şube olamaz.
    UNIQUE (sehir, ad)
);
