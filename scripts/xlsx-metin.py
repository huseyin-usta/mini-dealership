"""Bir .xlsx dosyasındaki sayfa adlarını ve tüm hücre metnini yazdırır (test yardımcısı).

Kullanım: python3 scripts/xlsx-metin.py dosya.xlsx
Dosya geçerli bir xlsx (zip) değilse çıkış kodu 1.
"""
import html
import re
import sys
import zipfile


def main():
    try:
        z = zipfile.ZipFile(sys.argv[1])
    except (zipfile.BadZipFile, FileNotFoundError, IndexError):
        print("GECERSIZ_XLSX")
        sys.exit(1)
    with z:
        # XML karakter referansları (&#xd6; gibi) çözülür: Excel de böyle okur.
        sayfalar = re.findall(r'<sheet [^>]*name="([^"]+)"', z.read("xl/workbook.xml").decode("utf-8"))
        print("SAYFALAR:" + "|".join(html.unescape(s) for s in sayfalar))
        for ad in sorted(z.namelist()):
            if ad.endswith(".xml") and (ad.startswith("xl/worksheets/") or ad == "xl/sharedStrings.xml"):
                xml = z.read(ad).decode("utf-8")
                print(" ".join(html.unescape(t)
                               for t in re.findall(r"<(?:t|v)[^>]*>([^<]*)</(?:t|v)>", xml)))


main()
