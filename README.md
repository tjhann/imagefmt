# imagefmt

Image loader and saver for simple needs with support for custom IO
and allocators.  Independent of the garbage collector.

API/behaviour still needs some minor details worked out...
and this will be @nogc when etc.c.zlib gets it.

**Decoders:**
- PNG, 8-bit and 16-bit interlaced and paletted (+`tRNS` chunk)
- BMP, 8-bit
- TGA, 8-bit non-paletted
- JPEG, baseline

**Encoders:**
- PNG, 8-bit non-paletted non-interlaced
- BMP, 8-bit RGB RGBA
- TGA, 8-bit

Returned buffers are 8-bit by default, 16-bit being another option and 8/16-bit
based on source data another.

```D
import imagefmt;

IFImage a = read_image("broke.jpg", 3);     // convert to rgb
if (a.e) {
    printf("*** load error: %s\n", IF_ERROR[a.e].ptr);
    return;
}
scope(exit) a.free();

IFInfo info = read_info("fsoc.tga");
printf("size: %d x %d   components: %d\n", info.w, info.h, info.c);
```

**Tipjar**: `nano_1xeof5x1ukki4awa7fp9gyb3qsymmrr4s3i8o63okzdq3bhsdj56nefm9shs`
