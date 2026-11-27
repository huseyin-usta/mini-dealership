// Araçlar: stoktaki ve yoldaki araçlar, VIN/plaka arama, araç detayı
// (özellikler, garanti durumu, stok hareketleri, servis geçmişi).

import { api, sorgu } from '../api.js';
import { h, yerlestir, bicim, rozet, tablo, sayfalama, secim, alan, uyari, yukleniyor, ETIKET } from '../dom.js';

const LIMIT = 50;

export async function goster(kok, { parametre, baglam }) {
  if (parametre) return detay(kok, parametre);
  return liste(kok, baglam);
}

async function liste(kok, { katalog, oturum }) {
  const durum = { sube_id: String(oturum.calisan.sube_id), durum: '', model_id: '', ara: '', tumu: '', sayfa: 1 };
  const sonuc = h('div');
  const ara = h('input', { type: 'search', placeholder: 'VIN veya plaka', maxlength: 17 });
  const sube = secim('sube_id', katalog.subeler.map((s) => [s.sube_id, `${s.sehir} – ${s.ad}`]), durum.sube_id, { bos: 'Tüm şubeler' });
  const drm = secim('durum', ['STOKTA', 'YOLDA', 'SATILDI'].map((d) => [d, ETIKET[d]]), '', { bos: 'Tümü' });
  const model = secim('model_id', katalog.modeller.map((m) => [m.model_id, m.ad]), '', { bos: 'Tümü' });

  const oku = () => {
    Object.assign(durum, { sube_id: sube.value, tumu: sube.value ? '' : 'true', durum: drm.value, model_id: model.value, ara: ara.value.trim(), sayfa: 1 });
    yukle();
  };
  for (const el of [sube, drm, model]) el.addEventListener('change', oku);
  let zamanlayici;
  ara.addEventListener('input', () => { clearTimeout(zamanlayici); zamanlayici = setTimeout(oku, 300); });

  async function yukle() {
    yerlestir(sonuc, yukleniyor());
    try {
      const { sayfa, ...f } = durum;
      // Arama tüm şubelerde yapılır (sube_id boşsa); seçili şube varsa daraltır.
      const v = await api(`/panel/arac${sorgu({ ...f, limit: LIMIT, sayfa })}`);
      yerlestir(sonuc,
        tablo([
          { ad: 'VIN', deger: (a) => h('a', { href: `#/arac/${a.vin}` }, a.vin), sinif: 'sayi' },
          { ad: 'Plaka', deger: (a) => bicim.bos(a.plaka) },
          { ad: 'Model', deger: (a) => `${a.model_adi} ${a.paket_adi} (${a.model_yili})` },
          { ad: 'Renk', deger: (a) => a.renk },
          { ad: 'Şube', deger: (a) => a.sube_adi },
          { ad: 'Durum', deger: (a) => [rozet(a.durum), a.tahmini_varis_tarihi ? ` ${bicim.tarih(a.tahmini_varis_tarihi)}` : ''] },
          { ad: 'Liste fiyatı', deger: (a) => bicim.para(a.liste_fiyati), sinif: 'sayi' },
        ], v.araclar, { satirTik: (a) => { location.hash = `#/arac/${a.vin}`; }, bosMetin: 'Araç bulunamadı.' }),
        sayfalama(v.toplam, LIMIT, durum.sayfa, (s) => { durum.sayfa = s; yukle(); }));
    } catch (e) {
      yerlestir(sonuc, uyari('hata', e.message));
    }
  }

  yerlestir(kok,
    h('h1', {}, 'Araçlar'),
    h('div', { class: 'filtre' }, alan('Ara', ara), alan('Şube', sube), alan('Durum', drm), alan('Model', model)),
    h('div', { class: 'kart' }, sonuc));
  yukle();
}

async function detay(kok, vin) {
  yerlestir(kok, yukleniyor());
  let a;
  try {
    a = await api(`/panel/arac/${encodeURIComponent(vin)}`);
  } catch (e) {
    yerlestir(kok, h('p', {}, h('a', { href: '#/araclar' }, '‹ Araçlar')), uyari('hata', e.message));
    return;
  }
  const g = a.garanti;
  yerlestir(kok,
    h('p', {}, h('a', { href: '#/araclar' }, '‹ Araçlar')),
    h('h1', {}, `${a.model_adi} ${a.paket_adi} · `, h('span', { class: 'sayi' }, a.plaka || a.vin), ' ', rozet(a.durum)),
    h('div', { class: 'izgara' },
      h('div', { class: 'kart' }, h('h2', {}, 'Araç'),
        h('dl', { class: 'bilgi' },
          h('dt', {}, 'VIN'), h('dd', { class: 'sayi' }, a.vin),
          h('dt', {}, 'Plaka'), h('dd', {}, bicim.bos(a.plaka)),
          h('dt', {}, 'Model yılı'), h('dd', {}, a.model_yili),
          h('dt', {}, 'Renk'), h('dd', {}, a.renk),
          h('dt', {}, 'Şube'), h('dd', {}, a.sube_adi),
          h('dt', {}, 'Liste fiyatı'), h('dd', {}, bicim.para(a.liste_fiyati)),
          a.tahmini_varis_tarihi ? [h('dt', {}, 'Tahmini varış'), h('dd', {}, bicim.tarih(a.tahmini_varis_tarihi))] : null,
          h('dt', {}, 'Sahibi'),
          h('dd', {}, a.sahip
            ? [h('a', { href: `#/musteri/${a.sahip.musteri_id}` }, a.sahip.ad_soyad || 'Adı bilinmiyor'), ` · ${a.sahip.telefon}`]
            : '—'))),
      h('div', { class: 'kart' }, h('h2', {}, 'Garanti'),
        g ? h('dl', { class: 'bilgi' },
          h('dt', {}, 'Durum'), h('dd', {}, rozet(g.garanti_durumu)),
          h('dt', {}, 'Başlangıç'), h('dd', {}, bicim.tarih(g.garanti_baslangic)),
          h('dt', {}, 'Bitiş'), h('dd', {}, bicim.tarih(g.garanti_bitis)),
          h('dt', {}, 'Km sınırı'), h('dd', {}, `${bicim.sayi(g.garanti_km)} km`),
          h('dt', {}, 'Son bilinen km'), h('dd', {}, `${bicim.sayi(g.son_bilinen_km)} km`),
          h('dt', {}, 'Son bakım'), h('dd', {}, bicim.tarih(g.son_bakim_tarihi)),
          h('dt', {}, 'Sonraki bakım'), h('dd', {},
            g.sonraki_bakim_son_tarih
              ? `${bicim.tarih(g.sonraki_bakim_son_tarih)} veya ${bicim.sayi(g.sonraki_bakim_son_km)} km`
              : '—'))
          : h('p', { class: 'soluk' }, 'Garanti satıştan sonra başlar.')),
      h('div', { class: 'kart' }, h('h2', {}, 'Özellikler'),
        a.ozellikler.length
          ? h('dl', { class: 'bilgi' }, a.ozellikler.map((o) => [h('dt', {}, o.ozellik_adi), h('dd', {}, o.deger)]))
          : h('p', { class: 'soluk' }, 'Özellik girilmemiş.'))),
    h('div', { class: 'kart' }, h('h2', {}, 'Servis geçmişi'),
      tablo([
        { ad: 'No', deger: (s) => h('a', { href: `#/servis-kaydi/${s.servis_kaydi_id}` }, `#${s.servis_kaydi_id}`) },
        { ad: 'Giriş', deger: (s) => bicim.zaman(s.giris_zamani) },
        { ad: 'Sebep', deger: (s) => rozet(s.sebep) },
        { ad: 'Km', deger: (s) => bicim.sayi(s.giris_kilometresi), sinif: 'sayi' },
        { ad: 'Durum', deger: (s) => [rozet(s.son_durum), s.gecikti_mi ? [' ', h('span', { class: 'rozet kirmizi' }, 'Gecikti')] : null] },
        { ad: 'Masraf', deger: (s) => bicim.para(s.toplam_masraf), sinif: 'sayi' },
      ], a.servis_kayitlari, {
        satirTik: (s) => { location.hash = `#/servis-kaydi/${s.servis_kaydi_id}`; },
        bosMetin: 'Servis kaydı yok.',
      })),
    h('div', { class: 'kart' }, h('h2', {}, 'Stok hareketleri'),
      tablo([
        { ad: 'Zaman', deger: (s) => bicim.zaman(s.zaman) },
        { ad: 'Hareket', deger: (s) => rozet(s.hareket_turu) },
        { ad: 'Nereden', deger: (s) => bicim.bos(s.kaynak_sube) },
        { ad: 'Nereye', deger: (s) => bicim.bos(s.hedef_sube) },
      ], a.stok_hareketleri)));
}
