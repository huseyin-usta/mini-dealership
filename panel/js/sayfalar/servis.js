// Servis kayıtları: açık/geciken kayıtlar, kayıt detayı (durum geçmişi,
// masraflar) ve güncelleme (durum ekleme, işlem/masraf ekleme).

import { api, sorgu } from '../api.js';
import { h, yerlestir, bicim, rozet, tablo, sayfalama, secim, alan, uyari, yukleniyor, bugun, ETIKET, telefon } from '../dom.js';

const LIMIT = 50;
const DURUMLAR = ['INCELENIYOR', 'PARCA_BEKLENIYOR', 'EKSPERTIZ_BEKLENIYOR', 'ISLEMDE', 'TESLIME_HAZIR', 'TAMAMLANDI'];
const ODEME = { BAKIM: ['MUSTERI'], ARIZA: ['MUSTERI', 'GARANTI'], KAZA: ['MUSTERI', 'SIGORTA'] };

export async function goster(kok, { parametre, baglam }) {
  if (parametre) return detay(kok, parametre);
  return liste(kok, baglam);
}

async function liste(kok, baglam) {
  const { katalog, oturum } = baglam;
  const durum = { sube_id: String(oturum.calisan.sube_id), tumu: '', acik: 'true', gecikti: '', ara: '', sayfa: 1 };
  const sonuc = h('div');
  const ara = h('input', { type: 'search', placeholder: 'VIN veya plaka', maxlength: 17 });
  const sube = secim('sube_id', katalog.subeler.map((s) => [s.sube_id, `${s.sehir} – ${s.ad}`]), durum.sube_id, { bos: 'Tüm şubeler' });
  const acik = secim('acik', [['true', 'Açık'], ['false', 'Kapanmış']], 'true', { bos: 'Tümü' });
  const gecikti = h('input', { type: 'checkbox' });

  const oku = () => {
    Object.assign(durum, {
      sube_id: sube.value, tumu: sube.value ? '' : 'true', acik: acik.value, gecikti: gecikti.checked ? 'true' : '', ara: ara.value.trim(), sayfa: 1,
    });
    yukle();
  };
  for (const el of [sube, acik, gecikti]) el.addEventListener('change', oku);
  let zamanlayici;
  ara.addEventListener('input', () => { clearTimeout(zamanlayici); zamanlayici = setTimeout(oku, 300); });

  async function yukle(sessiz = false) {
    if (!sessiz) yerlestir(sonuc, yukleniyor());
    try {
      const { sayfa, ...f } = durum;
      const v = await api(`/panel/servis${sorgu({ ...f, limit: LIMIT, sayfa })}`);
      yerlestir(sonuc,
        tablo([
          { ad: 'No', deger: (s) => h('a', { href: `#/servis-kaydi/${s.servis_kaydi_id}` }, `#${s.servis_kaydi_id}`) },
          { ad: 'Araç', deger: (s) => [s.model_adi, ' · ', h('span', { class: 'sayi' }, s.plaka || s.arac_vin)] },
          { ad: 'Müşteri', deger: (s) => bicim.bos(s.musteri) },
          { ad: 'Sebep', deger: (s) => rozet(s.sebep) },
          { ad: 'Giriş', deger: (s) => bicim.zaman(s.giris_zamani) },
          { ad: 'Durum', deger: (s) => rozet(s.son_durum) },
          { ad: 'Tahmini teslim', deger: (s) => [bicim.tarih(s.tahmini_teslim_tarihi),
            s.gecikti_mi ? [' ', h('span', { class: 'rozet kirmizi' }, `${-s.kalan_gun} gün gecikti`)] : null] },
          { ad: 'Masraf', deger: (s) => bicim.para(s.toplam_masraf), sinif: 'sayi' },
        ], v.servisler, {
          satirTik: (s) => { location.hash = `#/servis-kaydi/${s.servis_kaydi_id}`; },
          bosMetin: 'Servis kaydı yok.',
        }),
        sayfalama(v.toplam, LIMIT, durum.sayfa, (s) => { durum.sayfa = s; yukle(); }));
    } catch (e) {
      yerlestir(sonuc, uyari('hata', e.message));
    }
  }

  yerlestir(kok,
    h('h1', {}, 'Servis kayıtları'),
    h('div', { class: 'filtre' }, alan('Ara', ara), alan('Şube', sube), alan('Kayıtlar', acik),
      h('label', { style: null }, 'Yalnızca gecikenler', gecikti)),
    h('div', { class: 'kart' }, sonuc));
  yukle();
  baglam.otomatikYenile(() => yukle(true));
}

async function detay(kok, id) {
  const mesaj = h('div');
  const govde = h('div', {}, yukleniyor());
  yerlestir(kok, h('p', {}, h('a', { href: '#/servis' }, '‹ Servis kayıtları')), mesaj, govde);

  async function yukle() {
    let s;
    try {
      s = await api(`/panel/servis/${encodeURIComponent(id)}`);
    } catch (e) {
      yerlestir(govde, uyari('hata', e.message));
      return;
    }
    cizdir(s);
  }

  function cizdir(s) {
    yerlestir(govde,
      h('h1', {}, `Servis #${s.servis_kaydi_id} · `, rozet(s.sebep), ' ', rozet(s.son_durum),
        s.gecikti_mi ? [' ', h('span', { class: 'rozet kirmizi' }, 'Gecikti')] : null),
      h('div', { class: 'izgara' },
        h('div', { class: 'kart' }, h('h2', {}, 'Kayıt'),
          h('dl', { class: 'bilgi' },
            h('dt', {}, 'Araç'), h('dd', {}, h('a', { href: `#/arac/${s.arac_vin}` }, `${s.model_adi} · ${s.plaka || s.arac_vin}`)),
            h('dt', {}, 'Müşteri'), h('dd', {}, h('a', { href: `#/musteri/${s.musteri_id}` }, s.musteri || 'Adı bilinmiyor'), ' · ', telefon(s.telefon, { tam: true })),
            h('dt', {}, 'Sorumlu'), h('dd', {}, s.sorumlu_calisan),
            h('dt', {}, 'Giriş'), h('dd', {}, `${bicim.zaman(s.giris_zamani)} · ${bicim.sayi(s.giris_kilometresi)} km`),
            h('dt', {}, 'Şikâyet'), h('dd', {}, bicim.bos(s.sikayet_aciklama)),
            h('dt', {}, 'Tahmini teslim'), h('dd', {}, bicim.tarih(s.tahmini_teslim_tarihi),
              s.kalan_gun !== null && !s.kapandi_mi ? ` (${s.kalan_gun >= 0 ? `${s.kalan_gun} gün kaldı` : `${-s.kalan_gun} gün gecikti`})` : ''),
            s.cikis_kilometresi ? [h('dt', {}, 'Çıkış km'), h('dd', {}, bicim.sayi(s.cikis_kilometresi))] : null)),
        h('div', { class: 'kart' }, h('h2', {}, 'Masraflar'),
          h('div', { class: 'olcutler' },
            olcut('Toplam', bicim.para(s.toplam_masraf)),
            olcut('Müşteri', bicim.para(s.musteri_payi)),
            olcut('Garanti', bicim.para(s.garanti_payi)),
            olcut('Sigorta', bicim.para(s.sigorta_payi))),
          s.sigorta ? h('p', { class: 'soluk' },
            `Sigorta: ${s.sigorta.sirket} · dosya ${s.sigorta.dosya_no} · onaylanan ${bicim.para(s.sigorta.onaylanan_tutar)}`) : null)),
      h('div', { class: 'izgara' },
        h('div', { class: 'kart' }, h('h2', {}, 'Durum geçmişi'),
          h('ol', { class: 'cizelge' }, s.durum_gecmisi.map((d) => h('li', {},
            rozet(d.durum), ' ', h('span', { class: 'soluk' }, bicim.zaman(d.zaman)),
            d.aciklama ? h('div', {}, d.aciklama) : null))),
          s.kapandi_mi ? h('p', { class: 'soluk' }, 'Kayıt kapandı.') : durumFormu(s)),
        h('div', { class: 'kart' }, h('h2', {}, 'İşlemler'),
          tablo([
            { ad: 'İşlem', deger: (i) => [i.islem_adi, i.aciklama ? h('div', { class: 'soluk' }, i.aciklama) : null] },
            { ad: 'Ödeyen', deger: (i) => rozet(i.odeme_kaynagi) },
            { ad: 'Ücret', deger: (i) => bicim.para(i.ucret), sinif: 'sayi' },
          ], s.islemler, { bosMetin: 'İşlem girilmemiş.' }),
          s.kapandi_mi ? null : islemFormu(s))));
  }

  function durumFormu(s) {
    const durum = secim('durum', DURUMLAR.map((d) => [d, ETIKET[d]]), s.son_durum);
    const aciklama = h('input', { maxlength: 1000, placeholder: 'İsteğe bağlı' });
    const tahmin = h('input', { type: 'date', min: bugun(), value: s.tahmini_teslim_tarihi && s.tahmini_teslim_tarihi >= bugun() ? s.tahmini_teslim_tarihi : '' });
    return h('form', {
      class: 'form',
      onsubmit: (e) => gonder(e, `/panel/servis/${s.servis_kaydi_id}/durum`, {
        durum: durum.value,
        ...(aciklama.value.trim() ? { aciklama: aciklama.value.trim() } : {}),
        ...(tahmin.value && tahmin.value !== s.tahmini_teslim_tarihi ? { tahmini_teslim_tarihi: tahmin.value } : {}),
      }, 'Durum eklendi.'),
    }, alan('Yeni durum', durum), alan('Tahmini teslim', tahmin), alan('Açıklama', aciklama, { sinif: 'tam' }),
    h('div', { class: 'dugmeler tam' }, h('button', { class: 'ana', type: 'submit' }, 'Durum ekle')));
  }

  function islemFormu(s) {
    const ad = h('input', { required: true, maxlength: 128 });
    const ucret = h('input', { type: 'number', min: 0, step: 1, required: true });
    const odeme = secim('odeme_kaynagi', (ODEME[s.sebep] || ['MUSTERI']).map((o) => [o, ETIKET[o]]), 'MUSTERI');
    return h('form', {
      class: 'form',
      onsubmit: (e) => gonder(e, `/panel/servis/${s.servis_kaydi_id}/islem`, {
        islem_adi: ad.value.trim(), ucret: Number(ucret.value), odeme_kaynagi: odeme.value,
      }, 'İşlem eklendi.'),
    }, alan('İşlem', ad, { sinif: 'tam' }), alan('Ücret (₺)', ucret), alan('Ödeyen', odeme),
    h('div', { class: 'dugmeler tam' }, h('button', { class: 'ana', type: 'submit' }, 'İşlem ekle')));
  }

  async function gonder(e, yol, govdeVeri, basari) {
    e.preventDefault();
    const dugme = e.target.querySelector('button[type=submit]');
    dugme.disabled = true;
    yerlestir(mesaj);
    try {
      const s = await api(yol, { yontem: 'POST', govde: govdeVeri });
      yerlestir(mesaj, uyari('basari', basari));
      cizdir(s);
    } catch (err) {
      const ek = err.kod === 'GARANTI_GECERSIZ' ? ' Masraf müşteri ödemesi olarak girilebilir.' : '';
      yerlestir(mesaj, uyari('hata', err.message + ek));
      dugme.disabled = false;
    }
    mesaj.scrollIntoView({ block: 'nearest' });
  }

  yukle();
}

function olcut(ad, deger) {
  return h('div', { class: 'olcut' }, h('div', { class: 'deger' }, deger), h('div', { class: 'ad' }, ad));
}
