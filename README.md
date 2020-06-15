# imagefmt

Image loader and saver for simple needs with support for custom IO
and allocators.  Independent of the garbage collector.

**Decoders:**
- PNG, 8-bit and 16-bit interlaced and paletted (+`tRNS` chunk)
- BMP, 8-bit
- TGA, 8-bit non-paletted
- JPEG, baseline

**Encoders:**
- PNG, 8-bit non-paletted non-interlaced
- BMP, 8-bit RGB RGBA
- TGA, 8-bit

Returned buffers are 8-bit by default, other options are 16-bit and 8/16-bit
based on source data. The top-left corner is always at (0, 0).

```D
import imagefmt;

IFImage a = read_image("aya.jpg", 3);     // convert to rgb
if (a.e) {
    printf("*** load error: %s\n", IF_ERROR[a.e].ptr);
    return;
}
scope(exit) a.free();

IFInfo info = read_info("vine.tga");
printf("size: %d x %d   components: %d\n", info.w, info.h, info.c);
```
