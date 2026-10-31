-- Çalışan-yetkinlik: çoka-çok; bir çalışanın birden çok yetkinliği olabilir.
-- bitis_tarihi NULL = süresiz geçerli.
CREATE TABLE calisan_yetkinlik (
    calisan_id     integer NOT NULL REFERENCES calisan,
    yetkinlik_id   integer NOT NULL REFERENCES yetkinlik,
    verilis_tarihi date    NOT NULL,
    bitis_tarihi   date,
    PRIMARY KEY (calisan_id, yetkinlik_id),
    CHECK (bitis_tarihi IS NULL OR bitis_tarihi >= verilis_tarihi)
);
