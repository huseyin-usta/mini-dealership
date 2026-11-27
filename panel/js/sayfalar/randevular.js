// Bugünkü randevular: şube/gün/tür/durum filtresi, durum değiştirme.

import { api, sorgu } from '../api.js';
import { h, yerlestir, bicim, rozet, tablo, sayfalama, secim, alan, uyari, yukleniyor, bugun, ETIKET } from '../dom.js';

const LIMIT = 50;
// Filtreler sekme boyunca hatırlanır (başka sayfaya gidip dönünce kaybolmasın).
const HAFIZA = 'panel.randevular.filtre';
const GUNLER = ['Pazar', 'Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi'];

function hatirla() {
  try { return JSON.parse(sessionStorage.getItem(HAFIZA)) || {}; } catch { return {}; }
}

function sakla(durum) {
  try {
    const { sayfa, ...filtre } = durum;
    sessionStorage.setItem(HAFIZA, JSON.stringify(filtre));
  } catch { /* depolama kapalıysa hafıza yok, sayfa yine çalışır */ }
}

function gunEkle(tarih, n) {
  const [y, a, g] = tarih.split('-').map(Number);
  const d = new Date(y, a - 1, g + n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function gunAdi(tarih) {
  const [y, a, g] = tarih.split('-').map(Number);
  return GUNLER[new Date(y, a - 1, g).getDay()];
}

export async function goster(kok, { baglam }) {
  const { katalog, oturum } = baglam;
  const onceki = hatirla();
  const subeVar = katalog.subeler.some((s) => String(s.sube_id) === String(onceki.sube_id));
  const durum = {
    tarih: onceki.tarih || bugun(),
    sube_id: subeVar ? onceki.sube_id : oturum.calisan.sube_id,
    tur_kodu: onceki.tur_kodu || '',
    durum: onceki.durum || '',
    calisan_id: onceki.calisan_id || '',
    sayfa: 1,
  };
  const mesaj = h('div');
  const liste = h('div');

  const tarih = h('input', { type: 'date', value: durum.tarih });
  const sube = secim('sube_id', katalog.subeler.map((s) => [s.sube_id, `${s.sehir} – ${s.ad}`]), durum.sube_id);
  const tur = secim('tur_kodu', katalog.turler.map((t) => [t.tur_kodu, t.ad]), durum.tur_kodu, { bos: 'Tümü' });
  const drm = secim('durum', ['PLANLANDI', 'TAMAMLANDI', 'GELMEDI', 'IPTAL'].map((d) => [d, ETIKET[d]]), durum.durum, { bos: 'Tümü' });
  const calisan = h('select');
  const calisanlariDoldur = (secili = calisan.value) => {
    yerlestir(calisan, h('option', { value: '' }, 'Tümü'),
      katalog.calisanlar.filter((c) => String(c.sube_id) === sube.value)
        .map((c) => h('option', { value: c.calisan_id, selected: String(c.calisan_id) === secili }, `${c.ad} ${c.soyad}`)));
  };
  calisanlariDoldur(String(durum.calisan_id));

  const gunEtiketi = h('span', { class: 'gun-etiketi' });
  const oku = () => {
    Object.assign(durum, {
      tarih: tarih.value || bugun(),
      sube_id: sube.value,
      tur_kodu: tur.value,
      durum: drm.value,
      calisan_id: calisan.value,
      sayfa: 1,
    });
    sakla(durum);
    yukle();
  };
  for (const el of [tarih, tur, drm, calisan]) el.addEventListener('change', oku);
  sube.addEventListener('change', () => { calisanlariDoldur(); oku(); });
  const gunSec = (t) => { tarih.value = t; oku(); };
  const gunGezinme = h('div', { class: 'dugmeler gun-gezinme' },
    h('button', { type: 'button', title: 'Önceki gün', 'aria-label': 'Önceki gün', onclick: () => gunSec(gunEkle(tarih.value || bugun(), -1)) }, '‹'),
    h('button', { type: 'button', onclick: () => gunSec(bugun()) }, 'Bugün'),
    h('button', { type: 'button', title: 'Sonraki gün', 'aria-label': 'Sonraki gün', onclick: () => gunSec(gunEkle(tarih.value || bugun(), 1)) }, '›'));

  async function yukle(sessiz = false) {
    if (!sessiz) yerlestir(liste, yukleniyor());
    const bugunMu = durum.tarih === bugun();
    yerlestir(gunEtiketi, `${bicim.tarih(durum.tarih)} ${gunAdi(durum.tarih)}`,
      bugunMu ? h('span', { class: 'rozet mavi' }, 'Bugün') : null);
    try {
      const { sayfa, ...filtre } = durum;
      const veri = await api(`/panel/randevu${sorgu({ ...filtre, limit: LIMIT, sayfa })}`);
      yerlestir(liste,
        tablo([
          { ad: 'Saat', deger: (r) => `${bicim.saat(r.baslangic)}–${bicim.saat(r.bitis)}`, sinif: 'sayi' },
          { ad: 'Tür', deger: (r) => r.tur_adi },
          { ad: 'Müşteri', deger: (r) => h('a', { href: `#/musteri/${r.musteri_id}` }, r.musteri || 'Adı bilinmiyor') },
          { ad: 'Telefon', deger: (r) => r.telefon, sinif: 'sayi' },
          { ad: 'Çalışan', deger: (r) => r.calisan },
          { ad: 'Araç', deger: (r) => r.arac_vin
            ? h('a', { href: `#/arac/${r.arac_vin}` }, [r.model_adi, r.plaka].filter(Boolean).join(' · '))
            : '—' },
          { ad: 'Kaynak', deger: (r) => rozet(r.kaynak) },
          { ad: 'Durum', deger: (r) => rozet(r.durum) },
          { ad: '', deger: (r) => islemler(r) },
        ], veri.randevular, {
          bosMetin: 'Bu gün için randevu yok.',
          // Bugün: süren randevu vurgulanır, saati geçmiş olanlar soluklaşır.
          satirSinif: (r) => {
            if (!bugunMu) return null;
            const s = simdi();
            if (r.baslangic <= s && s < r.bitis) return 'suruyor';
            return r.bitis <= s ? 'gecti' : null;
          },
        }),
        sayfalama(veri.toplam, LIMIT, durum.sayfa, (s) => { durum.sayfa = s; yukle(); }));
    } catch (e) {
      yerlestir(liste, uyari('hata', e.message));
    }
  }

  function islemler(r) {
    if (r.durum !== 'PLANLANDI') return null;
    const basladi = r.baslangic <= simdi();
    return h('div', { class: 'dugmeler' },
      basladi ? h('button', { class: 'kucuk', onclick: () => degistir(r, 'TAMAMLANDI') }, 'Tamamlandı') : null,
      basladi ? h('button', { class: 'kucuk', onclick: () => degistir(r, 'GELMEDI') }, 'Gelmedi') : null,
      h('button', { class: 'kucuk tehlike', onclick: () => degistir(r, 'IPTAL') }, 'İptal'));
  }

  async function degistir(r, hedef) {
    if (hedef === 'IPTAL' && !confirm(`${bicim.zaman(r.baslangic)} randevusu iptal edilsin mi?`)) return;
    yerlestir(mesaj);
    try {
      await api(`/panel/randevu/${r.randevu_id}/durum`, { yontem: 'POST', govde: { durum: hedef } });
      yerlestir(mesaj, uyari('basari', `Randevu ${ETIKET[hedef].toLocaleLowerCase('tr')} olarak işaretlendi.`));
      yukle();
    } catch (e) {
      yerlestir(mesaj, uyari('hata', e.message));
    }
  }

  yerlestir(kok,
    h('h1', {}, 'Randevular · ', gunEtiketi),
    h('div', { class: 'filtre' },
      gunGezinme, alan('Gün', tarih), alan('Şube', sube), alan('Tür', tur), alan('Durum', drm), alan('Çalışan', calisan),
      h('a', { href: '#/randevu-ekle' }, h('button', { class: 'ana', type: 'button' }, '+ Randevu ekle'))),
    mesaj,
    h('div', { class: 'kart' }, liste));
  yukle();
  baglam.otomatikYenile(() => yukle(true));
}

/** Tarayıcı saatine göre şimdi 'YYYY-MM-DDTHH:MM' (randevu saatleriyle karşılaştırmak için). */
function simdi() {
  const d = new Date();
  const iki = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${iki(d.getMonth() + 1)}-${iki(d.getDate())}T${iki(d.getHours())}:${iki(d.getMinutes())}`;
}
