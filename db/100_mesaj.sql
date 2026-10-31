-- Mesaj: bota gelen ve giden her WhatsApp mesajı (analitik hacim tablosu).
CREATE TABLE mesaj (
    mesaj_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    musteri_id integer     NOT NULL REFERENCES musteri,
    yon        varchar(6)  NOT NULL CHECK (yon IN ('GELEN', 'GIDEN')),
    zaman      timestamptz NOT NULL DEFAULT now(),
    icerik     text        NOT NULL
);
