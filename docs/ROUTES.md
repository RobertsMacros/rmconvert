# rmconvert delivered routes

Generated from the bundled manifest: 47 actions, 64 explicit rules. Eligibility is rechecked against file contents after selection.

| Menu | Action | Source extensions | Handler / requirements |
|---|---|---|---|
| Convert | JPEG (`convert.jpg`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image / native |
| Convert | PNG (`convert.png`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image / native |
| Convert | HEIC (`convert.heic`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image / native |
| Convert | TIFF (`convert.tiff`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image / native |
| Convert | WebP (`convert.webp`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image.extra / magick |
| Convert | AVIF (`convert.avif`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image.extra / magick |
| Convert | ICNS (`convert.icns`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image.extra / magick |
| Convert | ICO (`convert.ico`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image.extra / magick |
| Convert | PDF, one per image (`convert.pdf`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image.pdf / native |
| Convert | PNG (`convert.png`) | svg | image.extra / magick |
| Convert | JPEG (`convert.jpg`) | svg | image.extra / magick |
| Convert | PDF, rasterised (`convert.pdf`) | svg | image.extra / magick |
| PDF | Combine into one PDF (`pdf.combine-images`) | jpg, png, tiff, heic, bmp, webp, gif, avif, psd | image.pdf / native |
| PDF | Combine PDFs (`pdf.combine`) | pdf | pdf / native |
| PDF | Split into separate PDFs (`pdf.split`) | pdf | pdf / native |
| PDF | Extract pages… (`pdf.extract`) | pdf | pdf / native |
| PDF | Remove pages… (`pdf.remove`) | pdf | pdf / native |
| PDF | Rotate clockwise (`pdf.rotate-right`) | pdf | pdf / native |
| PDF | Rotate anticlockwise (`pdf.rotate-left`) | pdf | pdf / native |
| Convert | PNG, one per page (`convert.png`) | pdf | pdf.raster / pdftoppm |
| Convert | JPEG, one per page (`convert.jpg`) | pdf | pdf.raster / pdftoppm |
| Convert | Plain text (`convert.txt`) | pdf | pdf.text / pdftotext |
| PDF | Compress PDF (`pdf.compress`) | pdf | pdf.compress / qpdf |
| Convert | PDF (`convert.pdf`) | docx, doc, odt, rtf, txt, pptx, ppt, odp, xlsx, xls, ods | office / soffice |
| Convert | PNG, one per slide (`convert.png`) | pptx, ppt, odp | office.raster / soffice, pdftoppm |
| Convert | PDF (`convert.pdf`) | rtfd | rtfd.pdf / soffice |
| Convert | PDF (`convert.pdf`) | md, html, epub | pandoc.pdf / pandoc, soffice |
| Convert | Plain text (`convert.txt`) | txt, rtf, rtfd, doc, docx, html | textutil / textutil |
| Convert | RTF (`convert.rtf`) | txt, rtf, rtfd, doc, docx, html | textutil / textutil |
| Convert | DOC (`convert.doc`) | txt, rtf, rtfd, doc, docx, html | textutil / textutil |
| Convert | DOCX (`convert.docx`) | txt, rtf, rtfd, doc, docx, html | textutil / textutil |
| Convert | RTFD (`convert.rtfd`) | txt, rtf, rtfd, doc, docx, html | textutil / textutil |
| Convert | HTML (`convert.html`) | txt, rtf, rtfd, doc, docx, html | textutil / textutil |
| Convert | Markdown (`convert.md`) | docx, odt, html, epub, rst, tex, md | pandoc / pandoc |
| Convert | HTML (`convert.html`) | docx, odt, html, epub, rst, tex, md | pandoc / pandoc |
| Convert | Plain text (`convert.txt`) | docx, odt, html, epub, rst, tex, md | pandoc / pandoc |
| Convert | EPUB (`convert.epub`) | md, html, docx, odt | pandoc / pandoc |
| Convert | CSV, one per sheet (`convert.csv`) | xlsx, xls, ods | office / soffice |
| Convert | XLSX (`convert.xlsx`) | csv, tsv | office / soffice |
| Convert | CSV (`convert.csv`) | csv, tsv | data / native |
| Convert | TSV (`convert.tsv`) | csv, tsv | data / native |
| Convert | JSON (`convert.json`) | csv, tsv | data / native |
| Convert | Markdown (`convert.md`) | csv, tsv | data / native |
| Convert | YAML (`convert.yaml`) | json | data / yq |
| Convert | XML (`convert.xml`) | json | data / native |
| Convert | CSV (`convert.csv`) | json | data / native |
| Convert | TOML (`convert.toml`) | json | data / yq |
| Convert | JSON (`convert.json`) | yaml, toml | data / yq |
| Convert | JSON (`convert.json`) | xml | data / native |
| Convert | XML property list (`plist.xml`) | plist | plist / native |
| Convert | Binary property list (`plist.binary`) | plist | plist / native |
| Convert | MP4 (`convert.mp4`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv, gif | media / ffmpeg, ffprobe |
| Convert | MOV (`convert.mov`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv | media / ffmpeg, ffprobe |
| Convert | MKV (`convert.mkv`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv | media / ffmpeg, ffprobe |
| Convert | WebM (`convert.webm`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv | media / ffmpeg, ffprobe |
| Convert | GIF (`convert.gif`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv | media / ffmpeg, ffprobe |
| Convert | MP3 (`convert.mp3`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv, mp3, wav, flac, aiff, m4a, ogg, opus, wma | media / ffmpeg, ffprobe |
| Convert | M4A (`convert.m4a`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv, mp3, wav, flac, aiff, m4a, ogg, opus, wma | media / ffmpeg, ffprobe |
| Convert | WAV (`convert.wav`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv, mp3, wav, flac, aiff, m4a, ogg, opus, wma | media / ffmpeg, ffprobe |
| Convert | FLAC (`convert.flac`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv, mp3, wav, flac, aiff, m4a, ogg, opus, wma | media / ffmpeg, ffprobe |
| Convert | AIFF (`convert.aiff`) | mov, mp4, mkv, avi, webm, m4v, flv, wmv, mp3, wav, flac, aiff, m4a, ogg, opus, wma | media / ffmpeg, ffprobe |
| Convert | Ringtone, first 40 seconds (`convert.m4r`) | mp3, m4a, wav | media / ffmpeg, ffprobe |
| Convert | SRT (`convert.srt`) | srt, vtt, ass | media / ffmpeg, ffprobe |
| Convert | WebVTT (`convert.vtt`) | srt, vtt, ass | media / ffmpeg, ffprobe |
