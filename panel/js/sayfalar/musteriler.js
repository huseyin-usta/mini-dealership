// Müşteriler: arama, müşteri kartı (iletişim, araçlar, randevu geçmişi)
// ve bot konuşmaları (salt-okunur, eskiye doğru sayfalı).

import { api, sorgu } from '../api.js';
import { h, yerlestir, bicim, rozet, tablo, sayfalama, alan, uyari, yukleniyor } from '../dom.js';

const LIMIT = 50;

export async function goster(kok, { parametre, baglam }) {
  if (parametre) return detay(kok, parametre);
  return liste(kok, baglam);
}

async function liste(kok, baglam) {
  const durum = { ara: '', sayfa: 1 };
  const sonuc = h('div');
  const ara = h('input', { type: 'search', placeholder: 'Telefon (+90…) veya ad soyad', maxlength: 64, size: 32 });
  let zamanlayici;
  ara.addEventListener('input', () => {
    clearTimeout(zamanlayici);
    zamanlayici = setTimeout(() => { durum.ara = ara.value.trim(); durum.sayfa = 1; yukle(); }, 300);
  });

  async function yukle(sessiz = false) {
    if (!sessiz) yerlestir(sonuc, yukleniyor());
    try {
      const v = await api(`/panel/musteri${sorgu({ ara: durum.ara, limit: LIMIT, sayfa: durum.sayfa })}`);
      yerlestir(sonuc,
        tablo([
          { ad: 'Ad soyad', deger: (m) => h('a', { href: `#/musteri/${m.musteri_id}` },
            [m.ad, m.soyad].filter(Boolean).join(' ') || 'Adı bilinmiyor') },
          { ad: 'Telefon', deger: (m) => m.telefon, sinif: 'sayi' },
          { ad: 'Kayıt', deger: (m) => bicim.tarih(m.kayit_zamani) },
          { ad: 'Son randevu', deger: (m) => m.son_randevu_zamani
            ? [bicim.zaman(m.son_randevu_zamani), ' · ', m.son_randevu_turu, ' ', rozet(m.son_randevu_durumu)]
            : '—' },
          { ad: '', deger: (m) => h('a', { href: `#/randevu-ekle/${m.musteri_id}` }, 'Randevu ekle') },
        ], v.musteriler, {
          satirTik: (m) => { location.hash = `#/musteri/${m.musteri_id}`; },
          bosMetin: 'Müşteri bulunamadı.',
        }),
        sayfalama(v.toplam, LIMIT, durum.sayfa, (s) => { durum.sayfa = s; yukle(); }));
    } catch (e) {
      yerlestir(sonuc, uyari('hata', e.message));
    }
  }

  yerlestir(kok, h('h1', {}, 'Müşteriler'), h('div', { class: 'filtre' }, alan('Ara', ara)), h('div', { class: 'kart' }, sonuc));
  yukle();
  baglam.otomatikYenile(() => yukle(true));
}

async function detay(kok, id) {
  yerlestir(kok, yukleniyor());
  let m;
  try {
    m = await api(`/panel/musteri/${encodeURIComponent(id)}`);
  } catch (e) {
    yerlestir(kok, h('p', {}, h('a', { href: '#/musteriler' }, '‹ Müşteriler')), uyari('hata', e.message));
    return;
  }
  const adSoyad = [m.ad, m.soyad].filter(Boolean).join(' ') || 'Adı bilinmiyor';
  const mesajlar = h('div', { class: 'mesajlar' });
  const dahaFazla = h('button', { class: 'kucuk', hidden: true }, 'Daha eski mesajlar');
  let imlec = null;

  async function mesajYukle() {
    dahaFazla.disabled = true;
    try {
      const v = await api(`/panel/musteri/${m.musteri_id}/mesaj${sorgu({ once: imlec, limit: 50 })}`);
      // Yanıt yeniden eskiye gelir; ekranda eskiden yeniye (sohbet sırası) gösterilir.
      const balonlar = v.mesajlar.slice().reverse().map((x) => h('div', { class: `balon ${x.yon === 'GELEN' ? 'gelen' : 'giden'}` },
        x.icerik, h('span', { class: 'zaman' }, `${x.yon === 'GELEN' ? 'Müşteri' : 'Bot'} · ${bicim.zaman(x.zaman)}`)));
      const ilk = imlec === null;
      if (ilk && balonlar.length === 0) mesajlar.append(h('p', { class: 'soluk' }, 'Bot konuşması yok.'));
      mesajlar.prepend(...balonlar);
      if (ilk) mesajlar.scrollTop = mesajlar.scrollHeight;
      imlec = v.sonraki_once;
      dahaFazla.hidden = imlec === null;
    } catch (e) {
      mesajlar.prepend(uyari('hata', e.message));
    }
    dahaFazla.disabled = false;
  }
  dahaFazla.addEventListener('click', mesajYukle);

  yerlestir(kok,
    h('p', {}, h('a', { href: '#/musteriler' }, '‹ Müşteriler')),
    h('h1', {}, adSoyad),
    h('div', { class: 'izgara' },
      h('div', { class: 'kart' }, h('h2', {}, 'İletişim'),
        h('dl', { class: 'bilgi' },
          h('dt', {}, 'Telefon'), h('dd', { class: 'sayi' }, m.telefon),
          h('dt', {}, 'Kayıt'), h('dd', {}, bicim.zaman(m.kayit_zamani))),
        h('p', {}, h('a', { href: `#/randevu-ekle/${m.musteri_id}` }, 'Bu müşteriye randevu ekle'))),
      h('div', { class: 'kart' }, h('h2', {}, 'Araçları'),
        m.araclar.length
          ? h('ul', {}, m.araclar.map((a) => h('li', {},
            h('a', { href: `#/arac/${a.vin}` }, `${a.model_adi} ${a.paket_adi}`), ` · ${a.renk} · ${a.plaka || a.vin}`)))
          : h('p', { class: 'soluk' }, 'Kayıtlı aracı yok.'))),
    h('div', { class: 'kart' }, h('h2', {}, 'Randevu geçmişi'),
      tablo([
        { ad: 'Zaman', deger: (r) => bicim.zaman(r.baslangic) },
        { ad: 'Tür', deger: (r) => r.tur_adi },
        { ad: 'Şube', deger: (r) => r.sube_adi },
        { ad: 'Çalışan', deger: (r) => r.calisan },
        { ad: 'Araç', deger: (r) => r.arac_vin ? h('a', { href: `#/arac/${r.arac_vin}` }, r.arac_vin) : '—', sinif: 'sayi' },
        { ad: 'Kaynak', deger: (r) => rozet(r.kaynak) },
        { ad: 'Durum', deger: (r) => rozet(r.durum) },
      ], m.randevular, { bosMetin: 'Randevusu yok.' })),
    h('div', { class: 'kart' }, h('h2', {}, 'Bot konuşmaları'),
      h('p', {}, dahaFazla), mesajlar));
  mesajYukle();
}
