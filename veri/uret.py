#!/usr/bin/env python3
"""Mini-Dealership sentetik veri üretici.

Kısıtlara uyan (çakışmasız randevu, tür saat pencereleri, yetkinlik, garanti
kuralı...) tutarlı bir bayi geçmişi üretir ve veri/uretilen/ altına tablo başına
bir CSV + yükleme script'i (yukle.sql) yazar. Yükleme scripts/veri-yukle.sh ile
yapılır; trigger'lar ve EXCLUDE kısıtları açıkken yüklenir, yani üretilen verinin
kurallara uyduğunu veritabanının kendisi doğrular.

Yalnızca standart kütüphane kullanır. Sabit seed ile her çalıştırmada aynı veri.

Kullanım: python3 veri/uret.py [--olcek 0.5] [--seed 372] [--bugun 2026-11-14] [--cikti veri/uretilen]

Modelleme kararları:
- Test sürüşleri her şubedeki modele özel test sürüşü (demo) araçlarıyla yapılır;
  bu araçlar hep STOKTA kalır (trigger aracın o anki durumunu kontrol eder, geçmişte
  satılmış bir araçla test sürüşü yüklenemezdi).
- Veri penceresi BASLANGIC'tan bugüne kadardır (bot ve WhatsApp randevuları bu
  pencerede). Pencereden önce satılmış araçların stok hareketleri ve satıştan
  itibaren tüm servis geçmişi de üretilir; aksi halde bakım zinciri kopuk görünür.
- Garanti ödemesi yalnızca trigger'ın (210) kabul edeceği durumlarda ve sınırlara
  güvenlik payı bırakılarak girilir.
"""

import argparse
import csv
import math
import os
import random
from datetime import date, datetime, time, timedelta

# ---------------------------------------------------------------------------
# Sabitler
# ---------------------------------------------------------------------------

BASLANGIC = date(2023, 11, 1)          # bot / veri penceresinin başı
ESKI_SATIS_BAS = date(2020, 1, 1)      # pencere öncesi satılmış filonun en eski satışı
BAKIM_GUN, BAKIM_KM = 365, 15000       # sabit periyodik bakım aralığı (trigger ile aynı)

SUBELER = [  # (şehir, ad, plaka kodu, ağırlık)
    ('Ankara', 'Çankaya', '06', 1.3), ('Ankara', 'Yenimahalle', '06', 0.9),
    ('İstanbul', 'Kadıköy', '34', 1.4), ('İstanbul', 'Beşiktaş', '34', 1.2),
    ('İstanbul', 'Ataşehir', '34', 1.0), ('İzmir', 'Bornova', '35', 1.0),
    ('Bursa', 'Nilüfer', '16', 0.8), ('Antalya', 'Muratpaşa', '07', 0.7),
]

# (ad, garanti yıl, garanti km, test sürüşü ilgisi, satış ağırlığı, 2026 taban fiyatı, paketler, yakıt)
MODELLER = [
    ('i10',     3, 100000, 0.6, 1.0,  950000, ['Jump', 'Style'], 'Benzin'),
    ('i20',     3, 100000, 1.0, 1.4, 1250000, ['Jump', 'Style', 'Elite'], 'Benzin'),
    ('Bayon',   3, 100000, 0.8, 0.9, 1400000, ['Style', 'Elite'], 'Benzin'),
    ('Elantra', 3, 100000, 1.0, 1.1, 1750000, ['Style', 'Smart', 'Elite'], 'Benzin'),
    ('Kona',    3, 100000, 1.1, 0.8, 1950000, ['Style', 'Elite'], 'Hibrit'),
    ('Tucson',  3, 100000, 1.5, 1.2, 2350000, ['Comfort', 'Prime', 'Elite'], 'Hibrit'),
    ('Santa Fe', 3, 100000, 0.6, 0.3, 3300000, ['Prime', 'Elite'], 'Hibrit'),
    ('Ioniq 5', 5, 150000, 1.7, 0.35, 2950000, ['Advance', 'Elite'], 'Elektrik'),
]
MODEL_YILLARI = range(2020, 2027)
RENKLER = ['Beyaz', 'Siyah', 'Gri', 'Gümüş', 'Lacivert', 'Kırmızı', 'Mavi', 'Yeşil']

# tur_kodu: (ad, süre dk, departman, yetkinlik kodu, saat pencereleri, WhatsApp olasılığı)
TURLER = {
    'TEST_SURUSU':     ('Test Sürüşü', 60, 'SATIS', 'TEST_SURUSU', [('10:00', '12:00'), ('14:00', '17:00')], 0.70),
    'ARAC_INCELEME':   ('Araç İnceleme', 60, 'SATIS', None, [('09:00', '18:00')], 0.60),
    'SATIN_ALIM':      ('Satın Alım', 60, 'SATIS', None, [('09:00', '17:00')], 0.10),
    'TESLIMAT':        ('Yeni Araç Teslimi', 60, 'SATIS', None, [('13:00', '17:00')], 0.05),
    'PERIYODIK_BAKIM': ('Periyodik Bakım', 60, 'SERVIS', None, [('09:00', '16:00')], 0.60),
    'SERVIS_GIRIS':    ('Servise Giriş', 30, 'SERVIS', None, [('09:00', '12:00')], 0.50),
    'SERVIS_TESLIM':   ('Servisten Teslim', 30, 'SERVIS', None, [('14:00', '18:00')], 0.30),
}
MESAI = ('09:00', '18:00')   # Pazartesi–Cumartesi, tüm şubelerde ortak; Pazar kapalı

YETKINLIKLER = [('TEST_SURUSU', 'Test Sürüşü Yetkisi'), ('EV_SERVIS', 'Elektrikli Araç Servis Sertifikası'),
                ('EKSPERTIZ', 'Hasar Ekspertiz Yetkisi')]
SIGORTA_SIRKETLERI = ['Kalkan Sigorta', 'Yıldız Kasko', 'Pusula Sigorta', 'Liman Sigorta',
                      'Ardıç Sigorta', 'Çınar Kasko']

ADLAR = ['Ahmet', 'Mehmet', 'Mustafa', 'Ali', 'Hüseyin', 'Hasan', 'İbrahim', 'Murat', 'Ömer', 'Emre',
         'Burak', 'Can', 'Kerem', 'Yusuf', 'Serkan', 'Onur', 'Tolga', 'Cem', 'Barış', 'Kaan',
         'Oğuz', 'Eren', 'Volkan', 'Umut', 'Selim', 'Fatma', 'Ayşe', 'Emine', 'Hatice', 'Zeynep',
         'Elif', 'Merve', 'Esra', 'Büşra', 'Derya', 'Gamze', 'Seda', 'Ebru', 'Özlem', 'Selin',
         'Deniz', 'Ece', 'Damla', 'İrem', 'Gizem', 'Pınar', 'Burcu', 'Tuğba', 'Aslı', 'Yağmur']
SOYADLAR = ['Yılmaz', 'Kaya', 'Demir', 'Çelik', 'Şahin', 'Yıldız', 'Yıldırım', 'Öztürk', 'Aydın',
            'Özdemir', 'Arslan', 'Doğan', 'Kılıç', 'Aslan', 'Çetin', 'Kara', 'Koç', 'Kurt', 'Özkan',
            'Şimşek', 'Polat', 'Korkmaz', 'Erdoğan', 'Güneş', 'Aksoy', 'Tekin', 'Ateş', 'Bulut',
            'Turan', 'Uçar', 'Bozkurt', 'Keskin', 'Avcı', 'Ünal', 'Güler', 'Taş', 'Sarı', 'Er',
            'Acar', 'Kaplan', 'Duman', 'Yavuz', 'Akın', 'Uysal', 'Karaca', 'Toprak', 'Ekinci']

BAKIM_KALEMLERI = [('Periyodik bakım işçiliği', 2500, 4500, 1.0), ('Motor yağı', 2500, 5000, 1.0),
                   ('Yağ filtresi', 400, 800, 1.0), ('Hava filtresi', 500, 900, 0.6),
                   ('Polen filtresi', 400, 700, 0.5), ('Fren hidroliği', 600, 1100, 0.3)]
ARIZA_KALEMLERI = [('Akü değişimi', 4000, 9000), ('Klima kompresörü', 15000, 35000),
                   ('Şanzıman valfi', 12000, 30000), ('Yazılım güncellemesi', 1500, 4000),
                   ('Sensör değişimi', 3000, 9000), ('Su pompası', 6000, 14000),
                   ('Marş motoru', 7000, 16000), ('Elektrik tesisatı onarımı', 3000, 12000),
                   ('Direksiyon kutusu', 15000, 40000)]
KAZA_KALEMLERI = [('Ön tampon değişimi', 8000, 25000), ('Arka tampon değişimi', 7000, 22000),
                  ('Kaporta düzeltme', 5000, 30000), ('Boya', 6000, 35000), ('Far değişimi', 6000, 20000),
                  ('Ön cam değişimi', 7000, 18000), ('Radyatör değişimi', 8000, 20000)]
ARIZA_SIKAYET = ['Motor arıza lambası yanıyor', 'Klima soğutmuyor', 'Araç geç çalışıyor',
                 'Vites geçişlerinde vuruntu', 'Multimedya ekranı donuyor', 'Direksiyonda titreme',
                 'Ön taraftan ses geliyor', 'Şarj olmuyor / şarj hatası']
KAZA_SIKAYET = ['Önden çarpma', 'Arkadan çarpma', 'Park halindeyken hasar', 'Yan çarpma']


# ---------------------------------------------------------------------------
# Yardımcılar
# ---------------------------------------------------------------------------

def hm(s):
    h, m = s.split(':')
    return int(h) * 60 + int(m)


def yil_ekle(dt, n):
    """PostgreSQL '+ n years' semantiği: 29 Şubat geçersizse 28 Şubat."""
    try:
        return dt.replace(year=dt.year + n)
    except ValueError:
        return dt.replace(year=dt.year + n, day=28)


def poisson(lam, rnd):
    if lam <= 0:
        return 0
    L, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rnd.random()
        if p <= L:
            return k
        k += 1


def fmt(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, datetime):
        return v.strftime('%Y-%m-%d %H:%M:%S')
    if isinstance(v, date):
        return v.isoformat()
    return v


class Uretici:
    def __init__(self, olcek, seed, bugun):
        self.r = random.Random(seed)
        self.olcek = olcek
        self.bugun = bugun
        # "Şimdi": bugünün mesai öncesi; bugünkü randevuların hepsi henüz PLANLANDI
        self.simdi = datetime.combine(bugun, time(8, 0))
        self.ufuk = bugun + timedelta(days=21)        # ileri tarihli randevu ufku
        self.mesgul = set()                           # (tür, anahtar, gün, slot)
        self.musteriler, self.calisanlar, self.araclar = [], [], []
        self.stok, self.randevular, self.servisler = [], [], []
        self.gecmis, self.islemler, self.sigortalar, self.mesajlar = [], [], [], []
        self.telefonlar, self.plaka_sayac, self.vin_sayac, self.dosya_sayac = set(), 0, 0, 0
        self._baslangiclar = {
            k: [s for (a, b) in v[4] for s in range(hm(a), hm(b) - v[1] + 1, 30)]
            for k, v in TURLER.items()}

    # ----- referans veriler ------------------------------------------------
    def referans(self):
        r = self.r
        self.subeler = [dict(sehir=s, ad=a, kod=k, agirlik=w) for s, a, k, w in SUBELER]
        self.yetkinlikler = {kod: dict(kod=kod, ad=ad) for kod, ad in YETKINLIKLER}
        self.modeller, self.versiyonlar = [], []
        for ad, gy, gkm, test_w, satis_w, fiyat, paketler, yakit in MODELLER:
            m = dict(ad=ad, garanti_yil=gy, garanti_km=gkm, test_w=test_w, satis_w=satis_w,
                     versiyonlar={}, yakit=yakit)
            self.modeller.append(m)
            for yil in MODEL_YILLARI:
                for i, paket in enumerate(paketler):
                    v = dict(model=m, paket=paket, yil=yil,
                             fiyat=int(round(fiyat * (1 + 0.12 * i) / (1.32 ** (2026 - yil)), -3)),
                             ozellik=[('yakit', yakit),
                                      ('vites', 'Otomatik' if i > 0 or yakit != 'Benzin' else 'Manuel'),
                                      ('koltuk', 'Deri' if i == len(paketler) - 1 else 'Kumaş'),
                                      ('ekran', ['8 inç', '10.25 inç', '12.3 inç'][min(i, 2)]),
                                      ('jant', ['16 inç', '17 inç', '18 inç', '19 inç'][min(i + (ad in ('Tucson', 'Santa Fe', 'Ioniq 5')), 3)])])
                    self.versiyonlar.append(v)
                    m['versiyonlar'].setdefault(yil, []).append(v)
        self.sigorta_sirketleri = [
            dict(ad=ad, tel='0850 %03d %02d %02d' % (r.randint(200, 999), r.randint(10, 99), r.randint(10, 99)),
                 eposta='hasar@%s.example' % ad.split()[0].lower().replace('ı', 'i').replace('ç', 'c'))
            for ad in SIGORTA_SIRKETLERI]

    def calisan_uret(self):
        r = self.r
        for sube in self.subeler:
            sube['calisan'] = {'SATIS': [], 'SERVIS': []}
            for dept, adet in (('SATIS', 8), ('SERVIS', 10)):
                for i in range(adet):
                    cekirdek = i < 3            # her şubede ayrılmayan, erken işe girmiş çekirdek kadro
                    if cekirdek or r.random() < 0.85:
                        giris = date(2012, 1, 1) + timedelta(days=r.randint(0, 2900))     # 2012–2019
                    else:
                        giris = BASLANGIC + timedelta(days=r.randint(0, 800))            # pencere içinde
                    ayrilis = None
                    if not cekirdek and r.random() < 0.07:
                        ayrilis = max(giris, BASLANGIC) + timedelta(days=r.randint(60, 900))
                        if ayrilis >= self.bugun:
                            ayrilis = None
                    c = dict(sube=sube, dept=dept, ad=r.choice(ADLAR), soyad=r.choice(SOYADLAR),
                             giris=giris, ayrilis=ayrilis, yetkinlik={})
                    if dept == 'SATIS' and (i < 2 or r.random() < 0.6):
                        c['yetkinlik']['TEST_SURUSU'] = giris + timedelta(days=r.randint(0, 60) if i >= 2 else 0)
                    if dept == 'SERVIS' and r.random() < 0.3:
                        c['yetkinlik']['EV_SERVIS'] = giris + timedelta(days=r.randint(30, 400))
                    if dept == 'SERVIS' and r.random() < 0.2:
                        c['yetkinlik']['EKSPERTIZ'] = giris + timedelta(days=r.randint(30, 400))
                    self.calisanlar.append(c)
                    sube['calisan'][dept].append(c)
        sayac = {}
        for c in self.calisanlar:
            taban = ('%s.%s' % (c['ad'], c['soyad']))
            taban = taban.translate(str.maketrans('çğıöşüÇĞİÖŞÜ', 'cgiosuCGIOSU')).lower()
            sayac[taban] = sayac.get(taban, 0) + 1
            c['kadi'] = taban if sayac[taban] == 1 else '%s%d' % (taban, sayac[taban])
            c['eposta'] = '%s@bayi.example' % c['kadi']
            # Gerçek bcrypt değil (stdlib'de yok); panel demo hesapları ayrıca tanımlanır
            c['hash'] = '$2a$10$' + ''.join(r.choice('./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789') for _ in range(53))

    # ----- kimlik üreticileri ----------------------------------------------
    def yeni_musteri(self):
        r = self.r
        while True:
            tel = '+905%02d%07d' % (r.randint(30, 59), r.randint(0, 9999999))
            if tel not in self.telefonlar:
                break
        self.telefonlar.add(tel)
        m = dict(k=len(self.musteriler), tel=tel, ad=r.choice(ADLAR), soyad=r.choice(SOYADLAR), ilk=None)
        self.musteriler.append(m)
        return m

    def temas(self, m, zaman):
        if m['ilk'] is None or zaman < m['ilk']:
            m['ilk'] = zaman

    def yeni_vin(self, model):
        self.vin_sayac += 1
        kod = ''.join(ch for ch in model['ad'].upper() if ch.isalnum())[:2].ljust(2, 'X')
        return 'KMH%s%012d' % (kod, self.vin_sayac)

    def yeni_plaka(self, sube):
        self.plaka_sayac += 1
        n = self.plaka_sayac
        harf = 'ABCDEFGHJKLMNPRSTUVYZ'
        h = harf[n % 21] + harf[(n // 21) % 21] + harf[(n // 441) % 21]
        return '%s %s %d' % (sube['kod'], h, 100 + (n // 9261) % 900)

    # ----- takvim ----------------------------------------------------------
    def _bos(self, anahtarlar):
        return not any(a in self.mesgul for a in anahtarlar)

    def slot_bul(self, tur, sube, gun0, musteri, vin=None, max_gun=10, sadece_ileri=False):
        """Tür penceresinde; çalışan, müşteri ve araç için boş ilk slotu bulur ve ayırır."""
        r = self.r
        ad, sure, dept, yetk, _, _ = TURLER[tur]
        adim = sure // 30
        for k in range(max_gun + 1):
            gun = gun0 + timedelta(days=k)
            if gun.weekday() == 6:                      # Pazar kapalı
                continue
            g = gun.toordinal()
            adaylar = [c for c in sube['calisan'][dept]
                       if c['giris'] <= gun and (c['ayrilis'] is None or gun < c['ayrilis'])
                       and (yetk is None or (yetk in c['yetkinlik'] and c['yetkinlik'][yetk] <= gun))]
            if not adaylar:
                continue
            baslar = self._baslangiclar[tur][:]
            r.shuffle(baslar)
            r.shuffle(adaylar)
            for b in baslar:
                bas = datetime.combine(gun, time(b // 60, b % 60))
                if sadece_ileri and bas < self.simdi:
                    continue
                slotlar = [b // 30 + i for i in range(adim)]
                diger = [('m', musteri['k'], g, s) for s in slotlar]
                if vin:
                    diger += [('a', vin, g, s) for s in slotlar]
                if not self._bos(diger):
                    continue
                for c in adaylar:
                    ck = [('c', id(c), g, s) for s in slotlar]
                    if self._bos(ck):
                        self.mesgul.update(diger)
                        self.mesgul.update(ck)
                        return bas, c
        return None

    def randevu(self, tur, sube, gun0, musteri, vin=None, versiyon=None, durum=None, max_gun=10,
                kaynak=None, sadece_ileri=False, oranlar=(0.10, 0.08)):
        sonuc = self.slot_bul(tur, sube, gun0, musteri, vin, max_gun, sadece_ileri)
        if sonuc is None:
            return None
        bas, cal = sonuc
        r = self.r
        if durum is None:
            durum = self.durum_sec(bas, *oranlar)
        elif bas >= self.simdi and durum in ('TAMAMLANDI', 'GELMEDI'):
            durum = 'PLANLANDI'                         # slot ileri kaydı: henüz gerçekleşmedi
        if kaynak is None:
            whatsapp = TURLER[tur][5] if bas.date() >= BASLANGIC + timedelta(days=10) else 0
            kaynak = 'WHATSAPP' if r.random() < whatsapp else 'PANEL'
        rv = dict(musteri=musteri, sube=sube, tur=tur, cal=cal, vin=vin, versiyon=versiyon,
                  bas=bas, bit=bas + timedelta(minutes=TURLER[tur][1]), durum=durum, kaynak=kaynak, notlar=None)
        # Randevunun alındığı an (mesajlar / müşteri kaydı için)
        alinma = bas - timedelta(days=r.uniform(0.5, 10), hours=r.uniform(0, 6))
        alinma = min(alinma, self.simdi - timedelta(hours=r.uniform(1, 72)))
        rv['alinma'] = alinma
        self.temas(musteri, alinma)
        self.randevular.append(rv)
        return rv

    def durum_sec(self, bas, iptal=0.10, gelmedi=0.08):
        x = self.r.random()
        if bas >= self.simdi:
            return 'IPTAL' if x < 0.07 else 'PLANLANDI'
        return 'IPTAL' if x < iptal else ('GELMEDI' if x < iptal + gelmedi else 'TAMAMLANDI')

    def sube_sec(self):
        return self.r.choices(self.subeler, [s['agirlik'] for s in self.subeler])[0]

    def versiyon_sec(self, model, yil):
        yil = max(min(yil, max(MODEL_YILLARI)), min(MODEL_YILLARI))
        return self.r.choice(model['versiyonlar'][yil])

    # ----- araçlar ve satışlar ---------------------------------------------
    def demo_araclar(self):
        """Her şubede her modelden bir test sürüşü aracı (hep STOKTA)."""
        r = self.r
        for sube in self.subeler:
            sube['demo'] = {}
            for m in self.modeller:
                a = dict(vin=self.yeni_vin(m), versiyon=self.versiyon_sec(m, 2023), sube=sube,
                         renk=r.choice(RENKLER), plaka=None, durum='STOKTA', varis=None, musteri=None, satis=None)
                gelis = datetime(2023, 4, 3, 10) + timedelta(days=r.randint(0, 60))
                self.stok += [dict(arac=a, tur='SIPARIS', zaman=gelis - timedelta(days=r.randint(25, 50)), kaynak=None, hedef=sube),
                              dict(arac=a, tur='GELIS', zaman=gelis, kaynak=None, hedef=sube)]
                self.araclar.append(a)
                sube['demo'][m['ad']] = a

    def eski_filo(self):
        """Pencere öncesi satılmış araçlar: sahipleri servise gelir."""
        r = self.r
        adet = int(5000 * self.olcek)
        aralik = (BASLANGIC - ESKI_SATIS_BAS).days
        for _ in range(adet):
            m = r.choices(self.modeller, [x['satis_w'] for x in self.modeller])[0]
            sube = self.sube_sec()
            satis = datetime.combine(ESKI_SATIS_BAS + timedelta(days=r.randint(0, aralik - 1)),
                                     time(r.randint(10, 16), r.choice([0, 30])))
            gelis = satis - timedelta(days=r.randint(5, 60), hours=r.randint(0, 3))
            sahip = self.yeni_musteri()
            self.temas(sahip, satis - timedelta(days=r.randint(1, 20)))
            a = dict(vin=self.yeni_vin(m), versiyon=self.versiyon_sec(m, satis.year), sube=sube,
                     renk=r.choice(RENKLER), plaka=self.yeni_plaka(sube), durum='SATILDI', varis=None,
                     musteri=sahip, satis=satis)
            self.stok += [dict(arac=a, tur='SIPARIS', zaman=gelis - timedelta(days=r.randint(20, 60)), kaynak=None, hedef=sube),
                          dict(arac=a, tur='GELIS', zaman=gelis, kaynak=None, hedef=sube),
                          dict(arac=a, tur='SATIS', zaman=satis, kaynak=sube, hedef=None)]
            self.araclar.append(a)

    def yeni_araclar(self):
        """Pencere içinde sipariş edilen araçlar: yolda / stokta / satış süreciyle satıldı."""
        r = self.r
        adet = int(11000 * self.olcek)
        bas = date(2023, 9, 1)
        aralik = (self.bugun + timedelta(days=75) - bas).days
        max_w = max(m['satis_w'] for m in self.modeller)
        for _ in range(adet):
            m = r.choices(self.modeller, [x['satis_w'] for x in self.modeller])[0]
            sube = self.sube_sec()
            varis = bas + timedelta(days=r.randint(0, aralik))
            siparis = datetime.combine(varis - timedelta(days=r.randint(25, 60)), time(r.randint(9, 17)))
            a = dict(vin=self.yeni_vin(m), renk=r.choice(RENKLER), sube=sube, plaka=None, musteri=None, satis=None,
                     versiyon=self.versiyon_sec(m, varis.year + (1 if varis.month >= 9 else 0)))
            self.araclar.append(a)
            if siparis.date() > self.bugun:
                siparis = datetime.combine(self.bugun - timedelta(days=r.randint(1, 20)), time(11))
            self.stok.append(dict(arac=a, tur='SIPARIS', zaman=siparis, kaynak=None, hedef=sube))
            if varis > self.bugun:
                a.update(durum='YOLDA', varis=varis)
                continue
            a.update(durum='STOKTA', varis=None)
            gelis = datetime.combine(varis, time(r.randint(9, 16), r.choice([0, 30])))
            self.stok.append(dict(arac=a, tur='GELIS', zaman=gelis, kaynak=None, hedef=sube))
            son = gelis
            if r.random() < 0.10:
                hedef = r.choice([s for s in self.subeler if s is not sube])
                t = gelis + timedelta(days=r.randint(3, 20), hours=1)
                if t < self.simdi:
                    self.stok.append(dict(arac=a, tur='TRANSFER', zaman=t, kaynak=sube, hedef=hedef))
                    a['sube'] = sube = hedef
                    son = t
            # Satış: modelin satış ağırlığına göre bekleme süresi
            bekleme = r.expovariate(1.0 / (30.0 * max_w / m['satis_w']))
            satis_gun = son.date() + timedelta(days=1 + int(bekleme))
            if satis_gun >= self.bugun:
                continue
            self.satis_sureci(a, m, sube, satis_gun)

    def satis_sureci(self, a, m, sube, satis_gun):
        r = self.r
        alici = self.yeni_musteri()
        rv = self.randevu('SATIN_ALIM', sube, satis_gun, alici, vin=a['vin'], durum='TAMAMLANDI', max_gun=6)
        if rv is None or rv['bas'] >= self.simdi:
            if rv is not None:                          # satış ufku aştı: geri al, araç stokta kalır
                self.randevular.remove(rv)
            return
        # Satış öncesi inceleme / test sürüşü (aynı model, satış şubesi)
        demo = sube['demo'][m['ad']]
        if r.random() < 0.6:
            self.randevu('TEST_SURUSU', sube, satis_gun - timedelta(days=r.randint(2, 25)), alici,
                         vin=demo['vin'], durum='TAMAMLANDI', max_gun=3)
        if r.random() < 0.4:
            self.randevu('ARAC_INCELEME', sube, satis_gun - timedelta(days=r.randint(3, 30)), alici,
                         versiyon=a['versiyon'], durum='TAMAMLANDI', max_gun=3)
        satis = rv['bit']
        a.update(durum='SATILDI', musteri=alici, satis=satis, plaka=self.yeni_plaka(sube))
        self.stok.append(dict(arac=a, tur='SATIS', zaman=satis, kaynak=sube, hedef=None))
        teslim_gun = satis.date() + timedelta(days=r.randint(2, 10))
        self.randevu('TESLIMAT', sube, teslim_gun, alici, vin=a['vin'],
                     durum='TAMAMLANDI' if teslim_gun < self.bugun else None, max_gun=5)

    def ek_satis_randevulari(self):
        """Satışa dönüşmeyen test sürüşleri ve incelemeler (dönüşüm oranı analizi için)."""
        r = self.r
        aralik = (self.ufuk - BASLANGIC).days
        for tur, adet in (('TEST_SURUSU', 28000), ('ARAC_INCELEME', 18000)):
            for _ in range(int(adet * self.olcek)):
                m = r.choices(self.modeller, [x['test_w'] for x in self.modeller])[0]
                sube = self.sube_sec()
                gun = BASLANGIC + timedelta(days=r.randint(0, aralik))
                musteri = self.yeni_musteri() if r.random() < 0.65 or not self.musteriler else r.choice(self.musteriler)
                if tur == 'TEST_SURUSU':
                    self.randevu(tur, sube, gun, musteri, vin=sube['demo'][m['ad']]['vin'], max_gun=5)
                else:
                    self.randevu(tur, sube, gun, musteri, versiyon=self.versiyon_sec(m, gun.year), max_gun=5)

    # ----- servis ----------------------------------------------------------
    def garanti_gecerli(self, a, t, km, bakimlar):
        """Trigger 210 ile aynı kural, sınırlara güvenlik payıyla (şüphede False)."""
        m = a['versiyon']['model']
        pay = timedelta(days=3)
        if km > m['garanti_km'] - 500 or t > yil_ekle(a['satis'], m['garanti_yil']) - pay:
            return False
        onceki_t, onceki_km = a['satis'], 0
        for bt, bkm in sorted(b for b in bakimlar if b[0] <= t):
            if bt > yil_ekle(onceki_t, 1) - pay or bkm - onceki_km > BAKIM_KM - 300:
                return False
            onceki_t, onceki_km = bt, bkm
        return not (t > yil_ekle(onceki_t, 1) - pay or km - onceki_km > BAKIM_KM - 300)

    def servis_sube(self, a):
        if self.r.random() < 0.85:
            return a['sube']
        ayni = [s for s in self.subeler if s['sehir'] == a['sube']['sehir']]
        return self.r.choice(ayni)

    def servis_uret(self):
        r = self.r
        for a in self.araclar:
            if a['satis'] is None:
                continue
            gunluk_km = r.uniform(7000, 30000) / 365.0
            aksatan = r.random() < 0.12
            km_at = lambda t: int(gunluk_km * (t - a['satis']).total_seconds() / 86400)
            bakimlar = self.bakim_zinciri(a, gunluk_km, aksatan, km_at)
            yil = max(0.0, (self.simdi - a['satis']).days / 365.0)
            for sebep, oran in (('ARIZA', 0.17), ('KAZA', 0.06)):
                for _ in range(poisson(oran * yil, r)):
                    t0 = a['satis'] + timedelta(days=r.uniform(15, max(16, (self.simdi - a['satis']).days - 1)))
                    if t0.date() >= self.bugun:
                        continue
                    self.onarim(a, sebep, t0.date(), km_at, bakimlar)

    def bakim_zinciri(self, a, gunluk_km, aksatan, km_at):
        r = self.r
        bakimlar = []
        onceki = a['satis']                             # son gerçekleşen bakım (ya da satış)
        km_gun = BAKIM_KM / gunluk_km
        tekrar = None                                   # gelinmeyen bakımın yeniden randevu günü
        while True:
            if tekrar is None:
                limit = min(BAKIM_GUN, km_gun)
                carpan = r.uniform(1.08, 1.5) if (aksatan and r.random() < 0.3) else r.uniform(0.72, 0.90)
                hedef = (onceki + timedelta(days=limit * carpan)).date()
            else:
                hedef, tekrar = tekrar, None
            if hedef > self.ufuk:
                break
            sube = self.servis_sube(a)
            rv = self.randevu('PERIYODIK_BAKIM', sube, hedef, a['musteri'], vin=a['vin'], max_gun=7,
                              oranlar=(0.03, 0.03))
            if rv is None:
                onceki = datetime.combine(hedef, time(9))
                continue
            if rv['bas'] >= self.simdi:
                break
            if rv['durum'] in ('IPTAL', 'GELMEDI'):
                tekrar = rv['bas'].date() + timedelta(days=r.randint(3, 10))
                continue
            km = km_at(rv['bas'])
            sk = dict(acilis=rv, teslim=None, sorumlu=rv['cal'], sebep='BAKIM', giris_km=km, cikis_km=km + r.randint(1, 5),
                      tahmini=rv['bas'].date(), sikayet=None)
            self.servisler.append(sk)
            for i, (durum, dk) in enumerate((('INCELENIYOR', 5), ('ISLEMDE', 15), ('TESLIME_HAZIR', 50), ('TAMAMLANDI', 60))):
                self.gecmis.append(dict(servis=sk, durum=durum, zaman=rv['bas'] + timedelta(minutes=dk), aciklama=None))
            enf = 1.0 / (1.35 ** (2026 - rv['bas'].year))
            for ad, alt, ust, olas in BAKIM_KALEMLERI:
                if r.random() < olas:
                    self.islemler.append(dict(servis=sk, ad=ad, ucret=int(round(r.uniform(alt, ust) * enf, -1)),
                                              kaynak='MUSTERI', aciklama=None))
            bakimlar.append((rv['bas'], km))
            onceki = rv['bas']
        return bakimlar

    def onarim(self, a, sebep, gun, km_at, bakimlar):
        r = self.r
        sube = self.servis_sube(a)
        rv = self.randevu('SERVIS_GIRIS', sube, gun, a['musteri'], vin=a['vin'], durum='TAMAMLANDI', max_gun=4)
        if rv is None or rv['bas'] >= self.simdi:
            if rv is not None:
                rv['durum'] = 'PLANLANDI'               # ileri tarihli giriş: henüz servis kaydı yok
            return
        km = km_at(rv['bas'])
        if sebep == 'ARIZA':
            sure = r.randint(1, 6) + (r.randint(5, 20) if r.random() < 0.3 else 0)
        else:
            sure = r.randint(5, 25)
        # 12:00'de hazır; teslim penceresi 14:00'te başladığı için teslim hep hazır anından sonra
        hazir = datetime.combine(rv['bas'].date() + timedelta(days=sure), time(12, 0))
        gec = r.randint(3, 15) if r.random() < 0.2 else r.randint(-2, 1)
        tahmini = hazir.date() - timedelta(days=gec)
        tahmini = max(tahmini, rv['bas'].date())
        sk = dict(acilis=rv, teslim=None, sorumlu=rv['cal'], sebep=sebep, giris_km=km, cikis_km=None,
                  tahmini=tahmini, sikayet=r.choice(ARIZA_SIKAYET if sebep == 'ARIZA' else KAZA_SIKAYET))
        self.servisler.append(sk)
        # Durum geçmişi
        adimlar = [('INCELENIYOR', rv['bas'] + timedelta(minutes=30))]
        t = rv['bas'] + timedelta(hours=r.uniform(3, 20))
        if sebep == 'KAZA':
            adimlar.append(('EKSPERTIZ_BEKLENIYOR', t))
            t += timedelta(days=r.uniform(1, min(5, sure * 0.4)))
        if sure > 5 and r.random() < 0.6:
            adimlar.append(('PARCA_BEKLENIYOR', t))
            t += timedelta(days=r.uniform(1, sure * 0.5))
        t = min(t, hazir - timedelta(hours=6))
        t = max(t, adimlar[-1][1] + timedelta(minutes=30))
        adimlar += [('ISLEMDE', t), ('TESLIME_HAZIR', hazir)]
        teslim = None
        if hazir < self.simdi:
            teslim = self.randevu('SERVIS_TESLIM', sube, hazir.date() + timedelta(days=r.randint(0, 2)), a['musteri'],
                                  vin=a['vin'], max_gun=5, durum=None)
            if teslim is not None:
                teslim['durum'] = 'TAMAMLANDI' if teslim['bas'] < self.simdi else 'PLANLANDI'
                sk['teslim'] = teslim
                if teslim['bas'] < self.simdi:
                    adimlar.append(('TAMAMLANDI', teslim['bit']))
                    sk['cikis_km'] = km + r.randint(0, 20)
        # sıralı ve benzersiz zamanlar; gelecekteki adımlar henüz yaşanmadı
        onceki = None
        for durum, zaman in adimlar:
            if zaman >= self.simdi:
                break
            if onceki is not None and zaman <= onceki:
                zaman = onceki + timedelta(minutes=5)
            self.gecmis.append(dict(servis=sk, durum=durum, zaman=zaman, aciklama=None))
            onceki = zaman
        # Masraflar
        enf = 1.0 / (1.35 ** (2026 - rv['bas'].year))
        kalemler = ARIZA_KALEMLERI if sebep == 'ARIZA' else KAZA_KALEMLERI
        secim = r.sample(kalemler, r.randint(1, 3)) + [('İşçilik', 1500, 6000)]
        if sebep == 'ARIZA':
            gecerli = self.garanti_gecerli(a, rv['bas'], km, bakimlar)
            red = gecerli and r.random() < 0.1
            kaynak = 'GARANTI' if gecerli and not red else 'MUSTERI'
            aciklama = 'Garanti talebi reddedildi: kullanım hatası' if red else None
        else:
            sigortali = r.random() < 0.7
            kaynak = 'SIGORTA' if sigortali else 'MUSTERI'
            aciklama = None
        toplam = 0
        for ad, alt, ust in secim:
            ucret = int(round(r.uniform(alt, ust) * enf, -1))
            toplam += ucret
            self.islemler.append(dict(servis=sk, ad=ad, ucret=ucret, kaynak=kaynak, aciklama=aciklama))
        if sebep == 'KAZA' and kaynak == 'SIGORTA':
            self.dosya_sayac += 1
            self.sigortalar.append(dict(servis=sk, sirket=r.choice(self.sigorta_sirketleri),
                                        dosya_no='HSR-%d-%06d' % (rv['bas'].year, self.dosya_sayac),
                                        eksper='%s %s' % (r.choice(ADLAR), r.choice(SOYADLAR)),
                                        tutar=int(round(toplam * r.uniform(0.85, 1.0), -1))))

    # ----- mesajlar --------------------------------------------------------
    def mesaj_uret(self):
        r = self.r
        for rv in self.randevular:
            if rv['kaynak'] != 'WHATSAPP':
                continue
            m, sube = rv['musteri'], rv['sube']
            tur_ad = TURLER[rv['tur']][0].lower()
            tarih = rv['bas'].strftime('%d.%m.%Y')
            saat = rv['bas'].strftime('%H:%M')
            konusma = [('GELEN', 'Merhaba, %s için randevu almak istiyorum.' % tur_ad)]
            if r.random() < 0.6:
                konusma += [('GIDEN', 'Merhaba! Hangi şehirdesiniz?'), ('GELEN', sube['sehir'])]
            konusma += [('GIDEN', '%s şubemizde %s saat %s uygun. Onaylıyor musunuz?' % (sube['ad'], tarih, saat)),
                        ('GELEN', r.choice(['Evet', 'Evet, onaylıyorum', 'Tamam, olur'])),
                        ('GIDEN', 'Randevunuz oluşturuldu: %s, %s %s.' % (sube['ad'], tarih, saat))]
            t = rv['alinma']
            for yon, icerik in konusma:
                self.mesajlar.append(dict(musteri=m, yon=yon, zaman=t, icerik=icerik))
                t += timedelta(seconds=r.randint(15, 150))
            if rv['durum'] == 'IPTAL':
                t2 = min(rv['bas'] - timedelta(hours=r.uniform(2, 48)), self.simdi - timedelta(minutes=10))
                t2 = max(t2, t + timedelta(minutes=5))
                self.mesajlar += [dict(musteri=m, yon='GELEN', zaman=t2, icerik='Randevumu iptal etmek istiyorum.'),
                                  dict(musteri=m, yon='GIDEN', zaman=t2 + timedelta(seconds=20),
                                       icerik='%s tarihli randevunuz iptal edildi.' % tarih)]
        # Randevuya dönüşmeyen stok soruları
        aralik = int((self.simdi - datetime.combine(BASLANGIC, time(8))).total_seconds())
        for _ in range(int(12000 * self.olcek)):
            m = self.yeni_musteri() if r.random() < 0.5 else r.choice(self.musteriler)
            model = r.choice(self.modeller)
            t = datetime.combine(BASLANGIC, time(8)) + timedelta(seconds=r.randint(0, aralik))
            self.temas(m, t)
            for yon, icerik in (('GELEN', '%s stokta var mı?' % model['ad']),
                                ('GIDEN', 'Hangi şehirdesiniz?'),
                                ('GELEN', r.choice(self.subeler)['sehir']),
                                ('GIDEN', r.choice(['%s stoğumuzda mevcut, test sürüşü ister misiniz?' % model['ad'],
                                                    '%s şu an yolda, tahmini varış birkaç hafta içinde.' % model['ad'],
                                                    'Sizi satış danışmanımıza yönlendiriyorum.']))):
                self.mesajlar.append(dict(musteri=m, yon=yon, zaman=t, icerik=icerik))
                t += timedelta(seconds=r.randint(15, 150))

    # ----- çıktı -----------------------------------------------------------
    def calistir(self):
        self.referans()
        self.calisan_uret()
        self.demo_araclar()
        self.eski_filo()
        self.yeni_araclar()
        self.ek_satis_randevulari()
        self.servis_uret()
        self.mesaj_uret()

    def yaz(self, cikti):
        r = self.r
        os.makedirs(cikti, exist_ok=True)
        dosyalar = []

        def tablo(ad, kolonlar, satirlar):
            yol = os.path.join(cikti, ad + '.csv')
            with open(yol, 'w', newline='', encoding='utf-8') as f:
                w = csv.writer(f, lineterminator='\n')
                w.writerow(kolonlar)
                for s in satirlar:
                    w.writerow(['' if v is None else fmt(v) for v in s])
            dosyalar.append((ad, kolonlar, len(satirlar)))

        def numarala(liste):
            for i, x in enumerate(liste, 1):
                x['id'] = i

        # Kimlikler kronolojik sırayla verilir (gerçek sistemdeki ekleme sırasına benzesin)
        for m in self.musteriler:
            if m['ilk'] is None:
                m['ilk'] = datetime.combine(BASLANGIC, time(9))
            m['kayit'] = m['ilk'] - timedelta(minutes=r.randint(1, 30))
        self.musteriler.sort(key=lambda m: (m['kayit'], m['k']))
        self.randevular.sort(key=lambda x: (x['alinma'], x['bas']))
        self.servisler.sort(key=lambda s: s['acilis']['bas'])
        self.gecmis.sort(key=lambda g: g['zaman'])
        self.mesajlar.sort(key=lambda x: x['zaman'])
        self.stok.sort(key=lambda x: x['zaman'])
        for liste in (self.subeler, self.calisanlar, self.modeller, self.versiyonlar, self.musteriler,
                      self.randevular, self.servisler, self.sigorta_sirketleri):
            numarala(liste)
        yetk_id = {kod: i for i, (kod, _) in enumerate(YETKINLIKLER, 1)}
        islem_sirasi = sorted(self.islemler, key=lambda i: i['servis']['id'])

        tablo('sube', ['sehir', 'ad'], [(s['sehir'], s['ad']) for s in self.subeler])
        tablo('mesai', ['gun', 'acilis', 'kapanis'], [(g, MESAI[0], MESAI[1]) for g in range(1, 7)])
        tablo('yetkinlik', ['kod', 'ad'], YETKINLIKLER)
        tablo('calisan', ['sube_id', 'ad', 'soyad', 'departman', 'eposta', 'kullanici_adi', 'sifre_hash',
                          'aktif_mi', 'ise_giris_tarihi'],
              [(c['sube']['id'], c['ad'], c['soyad'], c['dept'], c['eposta'], c['kadi'], c['hash'], True, c['giris'])
               for c in self.calisanlar])
        tablo('calisan_yetkinlik', ['calisan_id', 'yetkinlik_id', 'verilis_tarihi', 'bitis_tarihi'],
              [(c['id'], yetk_id[k], t, None) for c in self.calisanlar for k, t in sorted(c['yetkinlik'].items())])
        tablo('model', ['ad', 'garanti_yil', 'garanti_km'],
              [(m['ad'], m['garanti_yil'], m['garanti_km']) for m in self.modeller])
        tablo('versiyon', ['model_id', 'paket_adi', 'model_yili', 'liste_fiyati'],
              [(v['model']['id'], v['paket'], v['yil'], v['fiyat']) for v in self.versiyonlar])
        tablo('versiyon_ozellik', ['versiyon_id', 'ozellik_adi', 'deger'],
              [(v['id'], k, d) for v in self.versiyonlar for k, d in v['ozellik']])
        tablo('musteri', ['telefon', 'ad', 'soyad', 'kayit_zamani'],
              [(m['tel'], m['ad'], m['soyad'], m['kayit']) for m in self.musteriler])
        tablo('arac', ['vin', 'versiyon_id', 'sube_id', 'renk', 'plaka', 'durum', 'tahmini_varis_tarihi', 'musteri_id'],
              [(a['vin'], a['versiyon']['id'], a['sube']['id'], a['renk'], a['plaka'], a['durum'], a['varis'],
                a['musteri']['id'] if a['musteri'] else None) for a in self.araclar])
        tablo('stok_hareketi', ['arac_vin', 'hareket_turu', 'zaman', 'kaynak_sube_id', 'hedef_sube_id'],
              [(s['arac']['vin'], s['tur'], s['zaman'], s['kaynak']['id'] if s['kaynak'] else None,
                s['hedef']['id'] if s['hedef'] else None) for s in self.stok])
        tablo('randevu_turu', ['tur_kodu', 'ad', 'sure_dakika', 'departman', 'yetkinlik_id'],
              [(k, v[0], v[1], v[2], yetk_id[v[3]] if v[3] else None) for k, v in TURLER.items()])
        tablo('tur_saat', ['tur_kodu', 'gun', 'baslangic', 'bitis'],
              [(k, g, a, b) for k, v in TURLER.items() for g in range(1, 7) for a, b in v[4]])
        tablo('randevu', ['musteri_id', 'sube_id', 'tur_kodu', 'calisan_id', 'arac_vin', 'versiyon_id',
                          'baslangic', 'bitis', 'durum', 'kaynak', 'notlar'],
              [(x['musteri']['id'], x['sube']['id'], x['tur'], x['cal']['id'], x['vin'],
                x['versiyon']['id'] if x['versiyon'] else None, x['bas'], x['bit'], x['durum'], x['kaynak'], x['notlar'])
               for x in self.randevular])
        tablo('servis_kaydi', ['acilis_randevu_id', 'teslim_randevu_id', 'sorumlu_calisan_id', 'sebep',
                               'giris_kilometresi', 'cikis_kilometresi', 'tahmini_teslim_tarihi', 'sikayet_aciklama'],
              [(s['acilis']['id'], s['teslim']['id'] if s['teslim'] else None, s['sorumlu']['id'], s['sebep'],
                s['giris_km'], s['cikis_km'], s['tahmini'], s['sikayet']) for s in self.servisler])
        tablo('servis_durum_gecmisi', ['servis_kaydi_id', 'durum', 'zaman', 'aciklama'],
              [(g['servis']['id'], g['durum'], g['zaman'], g['aciklama']) for g in self.gecmis])
        tablo('sigorta_sirketi', ['ad', 'iletisim_tel', 'eposta'],
              [(s['ad'], s['tel'], s['eposta']) for s in self.sigorta_sirketleri])
        tablo('servis_sigorta', ['servis_kaydi_id', 'sirket_id', 'dosya_no', 'eksper', 'onaylanan_tutar'],
              [(s['servis']['id'], s['sirket']['id'], s['dosya_no'], s['eksper'], s['tutar']) for s in self.sigortalar])
        tablo('servis_islem', ['servis_kaydi_id', 'islem_adi', 'ucret', 'odeme_kaynagi', 'aciklama'],
              [(i['servis']['id'], i['ad'], i['ucret'], i['kaynak'], i['aciklama']) for i in islem_sirasi])
        tablo('mesaj', ['musteri_id', 'yon', 'zaman', 'icerik'],
              [(x['musteri']['id'], x['yon'], x['zaman'], x['icerik']) for x in self.mesajlar])

        # Yükleme script'i: tek transaction (psql -1), kimlikler COPY sırasıyla 1..N
        sayilar = {ad: n for ad, _, n in dosyalar}
        pasif = [c['id'] for c in self.calisanlar if c['ayrilis'] is not None]
        with open(os.path.join(cikti, 'yukle.sql'), 'w', encoding='utf-8') as f:
            f.write('-- veri/uret.py tarafından üretildi; scripts/veri-yukle.sh çalıştırır.\n')
            f.write("SET TIME ZONE 'Europe/Istanbul';\n")
            for ad, kolonlar, n in dosyalar:
                f.write("\\echo '  %s (%d satır)'\n" % (ad, n))
                f.write("\\copy %s (%s) FROM '%s.csv' WITH (FORMAT csv, HEADER true)\n" % (ad, ', '.join(kolonlar), ad))
            f.write('\n-- İşten ayrılan çalışanlar: randevuları ayrılış tarihinden önce; şimdi pasif\n')
            if pasif:
                f.write('UPDATE calisan SET aktif_mi = false WHERE calisan_id IN (%s);\n' % ', '.join(map(str, pasif)))
            f.write('\n-- Kimlik eşleşmesi kontrolü (FK\'lar üreticinin verdiği 1..N kimliklere dayanır)\n')
            f.write('DO $$\nBEGIN\n')
            for tablo_adi, kolon in (('sube', 'sube_id'), ('calisan', 'calisan_id'), ('model', 'model_id'),
                                     ('versiyon', 'versiyon_id'), ('musteri', 'musteri_id'), ('randevu', 'randevu_id'),
                                     ('servis_kaydi', 'servis_kaydi_id'), ('sigorta_sirketi', 'sirket_id')):
                f.write("  IF (SELECT coalesce(max(%s), 0) FROM %s) <> %d THEN RAISE EXCEPTION 'Kimlik kaymasi: %s'; END IF;\n"
                        % (kolon, tablo_adi, sayilar[tablo_adi], tablo_adi))
            f.write('END $$;\n')
        return dosyalar


def main():
    p = argparse.ArgumentParser(description='Mini-Dealership sentetik veri üretici')
    p.add_argument('--olcek', type=float, default=0.5,
                   help='hacim çarpanı; 0.5 ≈ 450.000, 1.0 ≈ 900.000 satır (ana tablolar). Hedef ≥ 250.000')
    p.add_argument('--seed', type=int, default=372)
    p.add_argument('--bugun', type=date.fromisoformat, default=date(2026, 11, 14),
                   help='veri bu tarihe göre geçmiş/gelecek ayrılır (tekrarlanabilirlik için sabit)')
    p.add_argument('--cikti', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uretilen'))
    a = p.parse_args()
    u = Uretici(a.olcek, a.seed, a.bugun)
    u.calistir()
    dosyalar = u.yaz(a.cikti)
    ana = ('randevu', 'mesaj', 'stok_hareketi', 'servis_durum_gecmisi')
    for ad, _, n in dosyalar:
        print('%-22s %9d%s' % (ad, n, '  *' if ad in ana else ''))
    print('ana tablolar toplamı (*): %d' % sum(n for ad, _, n in dosyalar if ad in ana))
    print('çıktı: %s' % a.cikti)


if __name__ == '__main__':
    main()
