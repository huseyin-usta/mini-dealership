-- Sigorta Şirketi: kaza onarımlarında hasar dosyası açılan sigorta/kasko firmaları.
CREATE TABLE sigorta_sirketi (
    sirket_id    integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ad           varchar(128) NOT NULL UNIQUE,
    iletisim_tel varchar(32),
    eposta       varchar(254)
);

