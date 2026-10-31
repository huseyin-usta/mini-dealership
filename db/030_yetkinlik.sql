-- Yetkinlik: çalışanlara verilebilen sertifika/yetki türleri (ör. test sürüşü yetkisi).
CREATE TABLE yetkinlik (
    yetkinlik_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kod          varchar(32)  NOT NULL UNIQUE,   -- ör. 'TEST_SURUSU'
    ad           varchar(128) NOT NULL
);
