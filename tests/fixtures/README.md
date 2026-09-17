# Synthetic HDR fixture

`hdr-gain-map.heic` is a generated 120×80 flat-colour image, containing an ISO HDR gain map. It contains no photograph or personal metadata. Core Image wrote an SDR colour of (0.2, 0.4, 0.6) in sRGB, paired with an extended-linear-sRGB HDR colour of (0.8, 1.6, 2.4) and content headroom 4, using `CIImageRepresentationOption.hdrImage`.

The regression test checks that the fixture contains a gain map, converts to ordinary image/PDF outputs, retains the SDR rendition and leaves the source untouched.
