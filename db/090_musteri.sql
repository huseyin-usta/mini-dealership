-- Müşteri: telefon numarasıyla tanımlanır (bot müşteriyi telefondan tanır).
CREATE TABLE musteri (
    musteri_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    telefon       varchar(20) NOT NULL UNIQUE,
    ad            varchar(64) NOT NULL,
    soyad         varchar(64) NOT NULL,
    kayit_zamani  timestamptz NOT NULL DEFAULT now()
);
