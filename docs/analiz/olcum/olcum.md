# İndeks analizi ölçüm sonuçları

PostgreSQL 16 (Docker), `scripts/indeks-analiz.sh`, JIT kapalı, her sorgu 5 kez, medyan Execution Time.
Sorgular: `docs/analiz/sorgular.sql`. Ek ölçüm (ek_arac_garanti): v_arac_garanti_durumu, vin=KMHBA000000000282

| Sorgu | İndekssiz (ms) | İndeksli (ms) | Hızlanma |
|---|---:|---:|---:|
| sorgu_1 | 71.17 | 39.95 | 1.8x |
| sorgu_2 | 16.34 | 1.52 | 10.8x |
| sorgu_3 | 24.55 | 0.48 | 50.9x |
| sorgu_4 | 38.16 | 11.88 | 3.2x |
| sorgu_5 | 83.97 | 82.69 | 1.0x |
| sorgu_6 | 478.55 | 472.06 | 1.0x |
| sorgu_7 | 369.50 | 371.43 | 1.0x |
| ek_arac_garanti | 141.14 | 133.62 | 1.1x |

## İndeks boyutları

```
     tablo     |             indeks              |  boyut  
---------------+---------------------------------+---------
 arac          | idx_arac_musteri                | 184 kB
 arac          | idx_arac_sube_durum             | 80 kB
 mesaj         | idx_mesaj_musteri_zaman         | 6696 kB
 mesaj         | idx_mesaj_zaman                 | 8592 kB
 randevu       | idx_randevu_arac_vin            | 784 kB
 randevu       | idx_randevu_musteri             | 2424 kB
 randevu       | idx_randevu_sube_baslangic      | 4872 kB
 randevu       | idx_randevu_tur_durum_baslangic | 3000 kB
 servis_islem  | idx_servis_islem_garanti        | 280 kB
 servis_islem  | idx_servis_islem_kayit_id       | 5528 kB
 servis_kaydi  | idx_servis_kaydi_acik_tahmin    | 256 kB
 stok_hareketi | idx_stok_hareketi_arac_zaman    | 1184 kB
 stok_hareketi | idx_stok_hareketi_tur_zaman     | 1520 kB
(13 rows)

```

## Tablo satır sayıları

```
        tablo         | satir  
----------------------+--------
 mesaj                | 216782
 servis_islem         | 139005
 servis_durum_gecmisi | 134549
 randevu              |  77961
 servis_kaydi         |  32989
 musteri              |  25339
 stok_hareketi        |  23804
 arac                 |   8064
 servis_sigorta       |    836
 versiyon_ozellik     |    665
 calisan              |    144
 versiyon             |    133
 calisan_yetkinlik    |     76
 tur_saat             |     48
 model                |      8
 sube                 |      8
 randevu_turu         |      7
 sigorta_sirketi      |      6
 mesai                |      6
 yetkinlik            |      3
(20 rows)

```
