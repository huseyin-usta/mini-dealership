-- Servis İşlem: serviste yapılan her bir işlem, parça veya işçilik kalemi.
-- Ücretler TL cinsinden bigint tam sayıdır.
-- Ödeme kaynağının servis sebebine uygunluğu ve garanti kontrolü trigger ile denetlenir.
CREATE TABLE servis_islem (
    islem_id        integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    servis_kaydi_id integer      NOT NULL REFERENCES servis_kaydi ON DELETE CASCADE,
    islem_adi       varchar(128) NOT NULL,
    ucret           bigint       NOT NULL CHECK (ucret >= 0),  -- tam sayı TL
    odeme_kaynagi   varchar(10)  NOT NULL CHECK (odeme_kaynagi IN ('MUSTERI', 'GARANTI', 'SIGORTA')),
    aciklama        text
);

