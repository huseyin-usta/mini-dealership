-- Randevu–araç sahipliği: aracın müşteriye ait olması kuralını veritabanına taşır.
--
-- Bot ve panel aynı kuralı Java'da da uygular, ama tek savunma Java olmamalı:
-- yeni bir yazma yolu (panel, ileride başka bir istemci) kuralı atlayabilir.
-- Bu trigger INSERT'te ve aracı/müşteriyi/türü değiştiren UPDATE'lerde çalışır;
-- yalnızca durum değiştiren güncellemeler (ör. TAMAMLANDI) yeniden doğrulanmaz,
-- çünkü araç sonradan satılmış olabilir.
--
-- Kurallar (bot sözleşmesiyle aynı):
--   TESLIMAT          : araç satılmışsa sahibi bu müşteri olmalı (yoldaysa sahip yok)
--   PERIYODIK_BAKIM   : araç SATILDI ve sahibi bu müşteri
--   SERVIS_GIRIS      : araç SATILDI ve sahibi bu müşteri
--   SERVIS_TESLIM     : bu müşterinin açık ve TESLİME HAZIR servis kaydı olmalı
--   TEST_SURUSU       : kural yok (stok aracı; 220 zaten şube/durum denetliyor)
--   ARAC_INCELEME/SATIN_ALIM: araç bağı yok

CREATE OR REPLACE FUNCTION fn_randevu_sahiplik()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_durum   varchar(10);
    v_sahip   integer;
    v_son     varchar(32);
    v_hazir   boolean;
BEGIN
    IF NEW.arac_vin IS NULL THEN
        RETURN NEW;
    END IF;

    -- Yalnızca aracı/müşteriyi/türü etkileyen değişikliklerde doğrula.
    IF TG_OP = 'UPDATE'
       AND NEW.arac_vin   IS NOT DISTINCT FROM OLD.arac_vin
       AND NEW.musteri_id IS NOT DISTINCT FROM OLD.musteri_id
       AND NEW.tur_kodu   IS NOT DISTINCT FROM OLD.tur_kodu THEN
        RETURN NEW;
    END IF;

    SELECT durum, musteri_id INTO v_durum, v_sahip
      FROM arac WHERE vin = NEW.arac_vin;

    IF NEW.tur_kodu = 'TESLIMAT' THEN
        IF v_sahip IS NOT NULL AND v_sahip <> NEW.musteri_id THEN
            RAISE EXCEPTION
                'Teslimat aracı bu müşteriye satılmamış (arac_vin: %, sahip: %)',
                NEW.arac_vin, v_sahip;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.tur_kodu IN ('PERIYODIK_BAKIM', 'SERVIS_GIRIS') THEN
        IF v_durum <> 'SATILDI' OR v_sahip IS DISTINCT FROM NEW.musteri_id THEN
            RAISE EXCEPTION
                'Servis randevusunda araç müşterinin kendi aracı olmalı (arac_vin: %, durum: %, sahip: %)',
                NEW.arac_vin, v_durum, v_sahip;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.tur_kodu = 'SERVIS_TESLIM' THEN
        -- Veri seti/ilerideki bir akış randevuyu servis kaydına doğrudan
        -- bağlamışsa (teslim_randevu_id) kayıt zaten bu randevu için açılmıştır.
        IF EXISTS (SELECT 1 FROM servis_kaydi sk
                    WHERE sk.teslim_randevu_id = NEW.randevu_id) THEN
            RETURN NEW;
        END IF;

        -- Aynı araç+müşteri için birden çok açık kayıt olabilir (eski kapanmamış
        -- kayıtlar). Herhangi biri TESLİME HAZIR ise teslim edilebilir.
        SELECT coalesce(bool_or(g.durum = 'TESLIME_HAZIR'), false),
               coalesce((array_agg(g.durum ORDER BY g.zaman DESC NULLS LAST,
                                                g.gecmis_id DESC))[1],
                        'kayıt yok')
          INTO v_hazir, v_son
          FROM servis_kaydi sk
          JOIN randevu ac ON ac.randevu_id = sk.acilis_randevu_id
          LEFT JOIN LATERAL (
                SELECT d.durum, d.zaman, d.gecmis_id
                  FROM servis_durum_gecmisi d
                 WHERE d.servis_kaydi_id = sk.servis_kaydi_id
                 ORDER BY d.zaman DESC, d.gecmis_id DESC
                 LIMIT 1
               ) g ON true
         WHERE ac.arac_vin = NEW.arac_vin
           AND ac.musteri_id = NEW.musteri_id
           AND sk.teslim_randevu_id IS NULL;

        IF NOT v_hazir THEN
            RAISE EXCEPTION
                'Servisten teslim için açık ve TESLİME HAZIR servis kaydı yok (arac_vin: %, son durum: %)',
                NEW.arac_vin, coalesce(v_son, 'kayıt yok');
        END IF;
        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_randevu_sahiplik ON randevu;
-- CONSTRAINT TRIGGER + DEFERRABLE: sentetik veri yüklemesi tek transaction'da
-- randevuları servis kayıtlarından ÖNCE yazar (FK sırası). Kural commit'te
-- doğrulanır; tek satırlık panel/bot eklemelerinde commit anında devreye girer.
CREATE CONSTRAINT TRIGGER trg_randevu_sahiplik
AFTER INSERT OR UPDATE ON randevu
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION fn_randevu_sahiplik();

-- Doğrulama trigger'ları bot gibi az yetkili rollerin de çalıştırabilmesi için
-- SECURITY DEFINER olmalı (bkz. 420_yetkiler.sql'deki aynı desen).
ALTER FUNCTION fn_randevu_sahiplik() SECURITY DEFINER
    SET search_path = public, pg_temp;
