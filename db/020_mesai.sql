-- Mesai: tüm şubeler için standart mesai saatleri (şube bazlı değil).
-- gun: 1 = Pazartesi ... 7 = Pazar (ISO gün numarası; EXTRACT(ISODOW ...) ile uyumlu).
CREATE TABLE mesai (
    gun     smallint PRIMARY KEY CHECK (gun BETWEEN 1 AND 7),
    acilis  time NOT NULL,
    kapanis time NOT NULL,
    CHECK (acilis < kapanis)
);
