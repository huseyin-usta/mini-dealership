-- Versiyon: modelin donanım paketi + model yılı kombinasyonu; fiyat burada.
-- (Model / versiyon ayrımı BCNF örneğidir: fiyat ve paket, modele değil versiyona bağlı.)
CREATE TABLE versiyon (
    versiyon_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    model_id     integer      NOT NULL REFERENCES model ON DELETE CASCADE,
    paket_adi    varchar(128) NOT NULL,             -- ör. 'Style X'
    model_yili   smallint     NOT NULL CHECK (model_yili >= 1950),
    -- Para alanları: TL cinsinden tam sayı (kuruş hassasiyeti araç domaininde gereksiz).
    -- Bu kalıp tüm para kolonlarında tekrar edecek (servis masrafı, sigorta tutarı...).
    liste_fiyati bigint NOT NULL CHECK (liste_fiyati >= 0),
    UNIQUE (model_id, paket_adi, model_yili)
);
