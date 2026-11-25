// Bugünkü randevular: şube/gün/tür/durum filtresi, durum değiştirme.

import { api, sorgu } from '../api.js';
import { h, yerlestir, bicim, rozet, tablo, sayfalama, secim, alan, uyari, yukleniyor, bugun, ETIKET } from '../dom.js';

const LIMIT = 50;

export async function goster(kok, { baglam }) {
  const { katalog, oturum } = baglam;
  const durum = {
    tarih: bugun(),
    sube_id: oturum.calisan.sube_id,
    tur_kodu: '',
    durum: '',
    calisan_id: '',
    sayfa: 1,
  };
  const mesaj = h('div');
  const liste = h('div');

  const tarih = h('input', { type: 'date', value: durum.tarih });
  const sube = secim('sube_id', katalog.subeler.map((s) => [s.sube_id, `${s.sehir} – ${s.ad}`]), durum.sube_id);
  const tur = secim('tur_kodu', katalog.turler.map((t) => [t.tur_kodu, t.ad]), '', { bos: 'Tümü' });
  const drm = secim('durum', ['PLANLANDI', 'TAMAMLANDI', 'GELMEDI', 'IPTAL'].map((d) => [d, ETIKET[d]]), '', { bos: 'Tümü' });
  const calisan = h('select');
  const calisanlariDoldur = () => {
    const secili = calisan.value;
    yerlestir(calisan, h('option', { value: '' }, 'Tümü'),
      katalog.calisanlar.filter((c) => String(c.sube_id) === sube.value)
        .map((c) => h('option', { value: c.calisan_id, selected: String(c.calisan_id) === secili }, `${c.ad} ${c.soyad}`)));
  };
  calisanlariDoldur();

  const oku = () => {
    Object.assign(durum, {
      tarih: tarih.value || bugun(),
      sube_id: sube.value,
      tur_kodu: tur.value,
      durum: drm.value,
      calisan_id: calisan.value,
      sayfa: 1,
    });
    yukle();
  };
  for (const el of [tarih, tur, drm, calisan]) el.addEventListener('change', oku);
  sube.addEventListener('change', () => { calisanlariDoldur(); oku(); });

  async function yukle() {
    yerlestir(liste, yukleniyor());
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
        ], veri.randevular, { bosMetin: 'Bu gün için randevu yok.' }),
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
    h('h1', {}, 'Bugünkü randevular'),
    h('div', { class: 'filtre' },
      alan('Gün', tarih), alan('Şube', sube), alan('Tür', tur), alan('Durum', drm), alan('Çalışan', calisan),
      h('a', { href: '#/randevu-ekle' }, h('button', { class: 'ana', type: 'button' }, '+ Randevu ekle'))),
    mesaj,
    h('div', { class: 'kart' }, liste));
  yukle();
}

/** Tarayıcı saatine göre şimdi 'YYYY-MM-DDTHH:MM' (randevu saatleriyle karşılaştırmak için). */
function simdi() {
  const d = new Date();
  const iki = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${iki(d.getMonth() + 1)}-${iki(d.getDate())}T${iki(d.getHours())}:${iki(d.getMinutes())}`;
}
