// Raporlar: istatistikler ve randevuların Excel'e aktarımı (tek yönlü).
// Veriler rapor rolüyle maskeli view'dan gelir; müşteri bilgisi görünmez.

import { api, sorgu, indir } from '../api.js';
import { h, yerlestir, bicim, rozet, tablo, secim, alan, uyari, yukleniyor, bugun } from '../dom.js';

export async function goster(kok, { baglam }) {
  const { katalog } = baglam;
  const ayBasi = `${bugun().slice(0, 8)}01`;
  const baslangic = h('input', { type: 'date', value: ayBasi, required: true });
  const bitis = h('input', { type: 'date', value: bugun(), required: true });
  const sube = secim('sube_id', katalog.subeler.map((s) => [s.sube_id, `${s.sehir} – ${s.ad}`]), '', { bos: 'Tüm şubeler' });
  const sonuc = h('div');
  const mesaj = h('div');
  const goster_ = h('button', { class: 'ana', type: 'submit' }, 'Göster');
  const excel = h('button', { type: 'button' }, 'Excel indir');

  const parametreler = () => sorgu({ baslangic: baslangic.value, bitis: bitis.value, sube_id: sube.value });

  async function yukle(e) {
    e?.preventDefault();
    yerlestir(mesaj);
    yerlestir(sonuc, yukleniyor());
    try {
      cizdir(await api(`/panel/rapor/ozet${parametreler()}`));
    } catch (err) {
      yerlestir(sonuc);
      yerlestir(mesaj, uyari('hata', err.message));
    }
  }

  excel.addEventListener('click', async () => {
    excel.disabled = true;
    yerlestir(mesaj);
    try {
      await indir(`/panel/rapor/randevu.xlsx${parametreler()}`, 'randevular.xlsx');
    } catch (err) {
      yerlestir(mesaj, uyari('hata', err.message));
    }
    excel.disabled = false;
  });

  function cizdir(v) {
    const o = v.ozet;
    yerlestir(sonuc,
      h('div', { class: 'olcutler' },
        olcut('Toplam randevu', bicim.sayi(o.toplam)),
        olcut('Tamamlandı', bicim.sayi(o.tamamlandi)),
        olcut('Planlandı', bicim.sayi(o.planlandi)),
        olcut('İptal', `${bicim.sayi(o.iptal)} (${bicim.yuzde(o.iptal_yuzde)})`),
        olcut('Gelmedi', `${bicim.sayi(o.gelmedi)} (${bicim.yuzde(o.gelmeme_yuzde)})`)),
      h('div', { class: 'izgara' },
        h('div', { class: 'kart' }, h('h2', {}, 'Şube doluluk sıralaması'),
          tablo([
            { ad: 'Sıra', deger: (s) => s.sira, sinif: 'sayi' },
            { ad: 'Şube', deger: (s) => `${s.sehir} – ${s.sube_adi}` },
            { ad: 'Randevu', deger: (s) => bicim.sayi(s.randevu), sinif: 'sayi' },
            { ad: 'Tamamlanan', deger: (s) => bicim.sayi(s.tamamlanan), sinif: 'sayi' },
          ], v.sube_doluluk)),
        h('div', { class: 'kart' }, h('h2', {}, 'Randevu türleri'),
          tablo([
            { ad: 'Tür', deger: (t) => t.tur_adi },
            { ad: 'Departman', deger: (t) => (t.departman === 'SATIS' ? 'Satış' : 'Servis') },
            { ad: 'Adet', deger: (t) => bicim.sayi(t.adet), sinif: 'sayi' },
          ], v.tur_dagilimi))),
      h('div', { class: 'izgara' },
        h('div', { class: 'kart' }, h('h2', {}, 'Randevu kaynağı'),
          tablo([
            { ad: 'Kaynak', deger: (k) => rozet(k.kaynak) },
            { ad: 'Adet', deger: (k) => bicim.sayi(k.adet), sinif: 'sayi' },
            { ad: 'Pay', deger: (k) => bicim.yuzde(k.yuzde), sinif: 'sayi' },
          ], v.kaynak_dagilimi)),
        h('div', { class: 'kart' }, h('h2', {}, 'Test sürüşünden satışa dönüşüm'),
          h('p', { class: 'soluk' }, '60 gün içinde aynı modelden teslimat randevusu verilen test sürüşleri.'),
          tablo([
            { ad: 'Model', deger: (d) => d.model_adi },
            { ad: 'Test sürüşü', deger: (d) => bicim.sayi(d.test_surusu), sinif: 'sayi' },
            { ad: 'Satışa dönen', deger: (d) => bicim.sayi(d.satisa_donen), sinif: 'sayi' },
            { ad: 'Oran', deger: (d) => bicim.yuzde(Math.round((1000 * d.satisa_donen) / d.test_surusu) / 10), sinif: 'sayi' },
          ], v.test_surusu_donusum, { bosMetin: 'Bu aralıkta tamamlanmış test sürüşü yok.' }))));
  }

  yerlestir(kok,
    h('h1', {}, 'Raporlar'),
    h('form', { class: 'filtre', onsubmit: yukle },
      alan('Başlangıç', baslangic), alan('Bitiş', bitis), alan('Şube', sube),
      h('div', { class: 'dugmeler' }, goster_, excel)),
    h('p', { class: 'soluk' }, 'Excel dosyası yalnızca dışa aktarımdır; müşteri adı ve telefonu maskeli çıkar.'),
    mesaj,
    sonuc);
  yukle();
}

function olcut(ad, deger) {
  return h('div', { class: 'olcut' }, h('div', { class: 'deger' }, deger), h('div', { class: 'ad' }, ad));
}
