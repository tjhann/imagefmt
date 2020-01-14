// Copyright 2019 Tero Hänninen. All rights reserved.
// SPDX-License-Identifier: BSD-2-Clause
module imagefmt;

import core.stdc.stdio;
import cstd = core.stdc.stdlib;
import imagefmt.bmp;
import imagefmt.tga;
import imagefmt.png;
import imagefmt.jpeg;

@nogc nothrow:

/// Basic image information.
struct IFInfo {
    int w;              /// width
    int h;              /// height
    ubyte c;            /// channels
    ubyte e;            /// error code or zero
}

/// Image returned from the read functions. Data is in buf8 or buf16.
struct IFImage {
    int w;              /// width
    int h;              /// height
    ubyte c;            /// channels in buf, 1 = y, 2 = ya, 3 = rgb, 4 = rgba
    ubyte cinfile;      /// channels found in file
    ubyte bpc;          /// bits per channel, 8 or 16
    ubyte e;            /// error code or zero
    union {
        ubyte[] buf8;       ///
        ushort[] buf16;     ///
    }

    @nogc nothrow:

    /// Frees the image data.
    void free() {
        _free(buf8.ptr);
        buf8 = null;
    }
}

/// Read interface.
struct Read {
    void* stream;
    /// returns number of bytes read; tries to read n bytes
    int function(void* stream, ubyte* buf, int n) @nogc nothrow read;
    /// returns 0 on success, -1 on error;
    /// sets cursor to off(set) from current position
    int function(void* stream, int off) @nogc nothrow seek;
}

/// Write interface.
struct Write {
    void* stream;
    /// returns the number of bytes written; tries to write all of buf.
    int function(void* stream, ubyte[] buf) @nogc nothrow write;
    /// returns 0 on success, -1 on error; forces a write of still unwritten data.
    int function(void* stream) @nogc nothrow flush;
}

int fileread(void* st, ubyte* buf, int n)
{
    return cast(int) fread(buf, 1, n, cast(FILE*) st);
}

int fileseek(void* st, int off)
{
    return fseek(cast(FILE*) st, off, SEEK_CUR);
}

int filewrite(void* st, ubyte[] buf)
{
    return cast(int) fwrite(buf.ptr, 1, buf.length, cast(FILE*) st);
}

int fileflush(void* st)
{
    return fflush(cast(FILE*) st);
}

/// Maximum size for the result buffer the loader functions
/// don't reject with a "too large" error.
ulong MAXIMUM_IMAGE_SIZE = 0x7fff_ffff;

version(IF__CUSTOM_ALLOC) {
    void* if__allocator;
    void* function(void* al, size_t size)            if__malloc;
    void* function(void* al, void* ptr, size_t size) if__realloc;
    void function(void* al, void* ptr)               if__free;

    void* _malloc(size_t size)             { return if__malloc(if__allocator, size);       }
    void* _realloc(void* ptr, size_t size) { return if__realloc(if__allocator, ptr, size); }
    void _free(void* ptr)                  { return if__free(if__allocator, ptr);          }
} else {
    void* _malloc(size_t size)             { return cstd.malloc(size);       }
    void* _realloc(void* ptr, size_t size) { return cstd.realloc(ptr, size); }
    void _free(void* ptr)                  { return cstd.free(ptr);          }
}

/// Error values returned from the functions.
enum ERROR { fopen = 1, oom, stream, data, oddfmt, unsupp, dim, arg, bigimg,
             nodata, lackdata, zinit, zstream }

/// Descriptions for errors.
immutable string[ERROR.max + 1] IF_ERROR = [
    0              : "no error",
    ERROR.fopen    : "cannot open file",
    ERROR.oom      : "out of memory",
    ERROR.stream   : "stream error",
    ERROR.data     : "bad data",
    ERROR.oddfmt   : "unknown format",
    ERROR.unsupp   : "unsupported",
    ERROR.dim      : "invalid dimensions",
    ERROR.arg      : "bad argument",
    ERROR.bigimg   : "image too large",
    ERROR.nodata   : "no data", // at all
    ERROR.lackdata : "not enough data",
    ERROR.zinit    : "zlib init failed",
    ERROR.zstream  : "zlib stream error",
];

/// Reads basic information about an image.
IFInfo read_info(in char[] fname)
{
    IFInfo info;
    auto tmp = NTString(fname);
    if (!tmp.ptr) {
        info.e = ERROR.oom;
        return info;
    }
    FILE* f = fopen(tmp.ptr, "rb");
    tmp.drop();
    if (!f) {
        info.e = ERROR.fopen;
        return info;
    }
    info = read_info(f);
    fclose(f);
    return info;
}

/// Reads from f which must already be open. Does not close it afterwards.
IFInfo read_info(FILE* f)
{
    Read io = { cast(void*) f, &fileread, &fileseek };
    return read_info(io);
}

/// Reads basic information about an image.
IFInfo read_info(Read io)
{
    ubyte[256] iobuf;
    IFInfo info;
    Reader rc;
    info.e = init_reader(&rc, io, iobuf[0..$]);
    if (info.e) return info;
    if (detect_png(&rc)) return read_png_info(&rc);
    if (detect_bmp(&rc)) return read_bmp_info(&rc);
    if (detect_jpeg(&rc)) return read_jpeg_info(&rc);
    if (detect_tga(&rc)) return read_tga_info(&rc);
    info.e = ERROR.oddfmt;
    return info;
}

/// Reads basic information about an image.
IFInfo read_info(in ubyte[] buf)
{
    IFInfo info;
    Reader rc;
    Read io = { null, null, null };
    info.e = init_reader(&rc, io, cast(ubyte[]) buf); // the cast? care is taken!
    if (info.e) return info;
    if (detect_png(&rc)) return read_png_info(&rc);
    if (detect_bmp(&rc)) return read_bmp_info(&rc);
    if (detect_jpeg(&rc)) return read_jpeg_info(&rc);
    if (detect_tga(&rc)) return read_tga_info(&rc);
    info.e = ERROR.oddfmt;
    return info;
}

/// Reads an image file, detecting its type.
IFImage read_image(in char[] fname, in int c = 0, in int bpc = 8)
{
    IFImage image;
    auto tmp = NTString(fname);
    if (!tmp.ptr) {
        image.e = ERROR.oom;
        return image;
    }
    FILE* f = fopen(tmp.ptr, "rb");
    tmp.drop();
    if (f) {
        image = read_image(f, c, bpc);
        fclose(f);
    } else
        image.e = ERROR.fopen;
    return image;
}

/// Reads from f which must already be open. Does not close it afterwards.
IFImage read_image(FILE* f, in int c = 0, in int bpc = 8)
{
    IFImage image;
    Read io = { cast(void*) f, &fileread, &fileseek };
    image = read_image(io, c, bpc);
    return image;
}

/// Reads an image using given io functions.
IFImage read_image(Read io, in int c = 0, in int bpc = 8)
{
    IFImage image;
    Reader rc;
    if (!io.stream || !io.read || !io.seek) {
        image.e = ERROR.arg;
        return image;
    }
    ubyte e;
    ubyte[] iobuf = new_buffer(4096, e);    if (e) return image;
    scope(exit) _free(iobuf.ptr);
    image.e = init_reader(&rc, io, iobuf);  if (image.e) return image;
    if (detect_png(&rc))  { image.e = read_png(&rc, image, c, bpc);  return image; }
    if (detect_bmp(&rc))  { image.e = read_bmp(&rc, image, c, bpc);  return image; }
    if (detect_jpeg(&rc)) { image.e = read_jpeg(&rc, image, c, bpc); return image; }
    if (detect_tga(&rc))  { image.e = read_tga(&rc, image, c, bpc);  return image; }
    image.e = ERROR.oddfmt;
    return image;
}

/// Reads an image from buf.
IFImage read_image(in ubyte[] buf, in int c = 0, in int bpc = 8)
{
    IFImage image;
    Reader rc;
    Read io = { null, null, null };
    image.e = init_reader(&rc, io, cast(ubyte[]) buf); // the cast? care is taken!
    if (image.e) return image;
    if (detect_png(&rc))  { image.e = read_png(&rc, image, c, bpc);  return image; }
    if (detect_bmp(&rc))  { image.e = read_bmp(&rc, image, c, bpc);  return image; }
    if (detect_jpeg(&rc)) { image.e = read_jpeg(&rc, image, c, bpc); return image; }
    if (detect_tga(&rc))  { image.e = read_tga(&rc, image, c, bpc);  return image; }
    image.e = ERROR.oddfmt;
    return image;
}

/// Returns 0 on success, else an error code. Assumes RGB order for color components
/// in buf, if present.  Note: The file will remain even if the write fails.
ubyte write_image(in char[] fname, int w, int h, in ubyte[] buf, int reqchans = 0)
{
    const int fmt = fname2fmt(fname);
    if (fmt == -1)
        return ERROR.unsupp;
    auto tmp = NTString(fname);
    if (!tmp.ptr)
        return ERROR.oom;
    FILE* f = fopen(tmp.ptr, "wb");
    tmp.drop();
    if (!f)
        return ERROR.fopen;
    ubyte e = write_image(fmt, f, w, h, buf, reqchans);
    fclose(f);
    return e;
}

enum IF_BMP = 0;    /// the BMP format
enum IF_TGA = 1;    /// the TGA format
enum IF_PNG = 2;    /// the PNG format
enum IF_JPG = 3;    /// the JPEG format

/// Writes to f which must already be open. Does not close it afterwards. Returns 0
/// on success, else an error code. Assumes RGB order for color components in buf, if
/// present. Note: The file will remain even if the write fails.
ubyte write_image(int fmt, FILE* f, int w, int h, in ubyte[] buf, int reqchans = 0)
{
    Write io = { cast(void*) f, &filewrite, &fileflush };
    return write_image(fmt, io, w, h, buf, reqchans);
}

/// Returns 0 on success, else an error code. Assumes RGB order for color components
/// in buf, if present.
ubyte write_image(int fmt, Write io, int w, int h, in ubyte[] buf, int reqchans = 0)
{
    Writer wc;
    if (!io.stream || !io.write || !io.flush)
        return ERROR.arg;
    ubyte e;
    ubyte[] iobuf = new_buffer(4096, e);                if (e) return e;
    scope(exit) _free(iobuf.ptr);
    e = init_writer(&wc, io, iobuf);                    if (e) return e;
    e = _write_image(fmt, &wc, w, h, buf, reqchans);    if (e) return e;
    e = fullflush(&wc);
    return e;
}

/// Returns null on error and the error code through e. Assumes RGB order for color
/// components in buf, if present.
ubyte[] write_image_mem(int fmt, int w, int h, in ubyte[] buf, int reqchans, out int e)
{
    Writer wc;
    Write io = { null, null, null };
    e = init_writer(&wc, io, null);                     if (e) goto failure;
    e = _write_image(fmt, &wc, w, h, buf, reqchans);    if (e) goto failure;

    if ((wc.cap - wc.n) * 100 / wc.cap > 20) {  // max 20% waste
        ubyte* p = cast(ubyte*) _realloc(wc.buf, wc.n);
        if (!p) goto failure;
        wc.buf = p;
    }

    return wc.buf[0..wc.n];
failure:
    _free(wc.buf);
    return null;
}

/* ------------------ conversions ------------------ */

/// Converts an 8-bit buffer to a 16-bit buffer in place.
/// On error, returns null and frees the original buffer.
ushort[] bpc8to16(ubyte[] b8)
{
    ubyte* p8 = cast(ubyte*) _realloc(b8.ptr, b8.length * 2);
    if (!p8) {
        _free(b8.ptr);
        return null;
    }
    ushort[] b16 = (cast(ushort*) p8)[0 .. b8.length];
    for (size_t i = b8.length - 1; i < b8.length; --i)
        b16[i] = p8[i] * 257;
    return b16;
}

/// Converts a 16-bit buffer to an 8-bit buffer in place.
/// On error, returns null and frees the original buffer.
ubyte[] bpc16to8(ushort[] b16)
{
    ubyte[] b8 = (cast(ubyte*) b16.ptr)[0 .. b16.length];
    for (size_t i = 0; i < b16.length; i++)
        b8[i] = b16[i] >> 8;
    ubyte* p8 = cast(ubyte*) _realloc(b16.ptr, b16.length);
    if (!p8) {
        _free(b16.ptr);
        return null;
    }
    return p8[0 .. b8.length];
}

alias conv8 = void function(in ubyte[] src, ubyte[] tgt) @nogc nothrow;
alias conv16 = void function(in ushort[] src, ushort[] tgt) @nogc nothrow;

void* getconv(in int sc, in int tc, in int bpc)
{
    if (sc == tc)
        return bpc == 8 ? &copy : cast(void*) &copy16;
    switch (16*sc + tc) with(CHANS) {
        case 16*y    + ya   : return bpc == 8 ? &conv_y2ya      : cast(void*) &conv16_y2ya;
        case 16*y    + rgb  : return bpc == 8 ? &conv_y2rgb     : cast(void*) &conv16_y2rgb;
        case 16*y    + rgba : return bpc == 8 ? &conv_y2rgba    : cast(void*) &conv16_y2rgba;
        case 16*y    + bgr  : return bpc == 8 ? &conv_y2rgb     : cast(void*) &conv16_y2rgb;     // reuse
        case 16*y    + bgra : return bpc == 8 ? &conv_y2rgba    : cast(void*) &conv16_y2rgba;    // reuse
        case 16*ya   + y    : return bpc == 8 ? &conv_ya2y      : cast(void*) &conv16_ya2y;
        case 16*ya   + rgb  : return bpc == 8 ? &conv_ya2rgb    : cast(void*) &conv16_ya2rgb;
        case 16*ya   + rgba : return bpc == 8 ? &conv_ya2rgba   : cast(void*) &conv16_ya2rgba;
        case 16*ya   + bgr  : return bpc == 8 ? &conv_ya2rgb    : cast(void*) &conv16_ya2rgb;    // reuse
        case 16*ya   + bgra : return bpc == 8 ? &conv_ya2rgba   : cast(void*) &conv16_ya2rgba;   // reuse
        case 16*rgb  + y    : return bpc == 8 ? &conv_rgb2y     : cast(void*) &conv16_rgb2y;
        case 16*rgb  + ya   : return bpc == 8 ? &conv_rgb2ya    : cast(void*) &conv16_rgb2ya;
        case 16*rgb  + rgba : return bpc == 8 ? &conv_rgb2rgba  : cast(void*) &conv16_rgb2rgba;
        case 16*rgb  + bgr  : return bpc == 8 ? &conv_rgb2bgr   : cast(void*) &conv16_rgb2bgr;
        case 16*rgb  + bgra : return bpc == 8 ? &conv_rgb2bgra  : cast(void*) &conv16_rgb2bgra;
        case 16*rgba + y    : return bpc == 8 ? &conv_rgba2y    : cast(void*) &conv16_rgba2y;
        case 16*rgba + ya   : return bpc == 8 ? &conv_rgba2ya   : cast(void*) &conv16_rgba2ya;
        case 16*rgba + rgb  : return bpc == 8 ? &conv_rgba2rgb  : cast(void*) &conv16_rgba2rgb;
        case 16*rgba + bgr  : return bpc == 8 ? &conv_rgba2bgr  : cast(void*) &conv16_rgba2bgr;
        case 16*rgba + bgra : return bpc == 8 ? &conv_rgba2bgra : cast(void*) &conv16_rgba2bgra;
        case 16*bgr  + y    : return bpc == 8 ? &conv_bgr2y     : cast(void*) &conv16_bgr2y;
        case 16*bgr  + ya   : return bpc == 8 ? &conv_bgr2ya    : cast(void*) &conv16_bgr2ya;
        case 16*bgr  + rgb  : return bpc == 8 ? &conv_rgb2bgr   : cast(void*) &conv16_rgb2bgr;   // reuse
        case 16*bgr  + rgba : return bpc == 8 ? &conv_rgb2bgra  : cast(void*) &conv16_rgb2bgra;  // reuse
        case 16*bgra + y    : return bpc == 8 ? &conv_bgra2y    : cast(void*) &conv16_bgra2y;
        case 16*bgra + ya   : return bpc == 8 ? &conv_bgra2ya   : cast(void*) &conv16_bgra2ya;
        case 16*bgra + rgb  : return bpc == 8 ? &conv_rgba2bgr  : cast(void*) &conv16_rgba2bgr;  // reuse
        case 16*bgra + rgba : return bpc == 8 ? &conv_rgba2bgra : cast(void*) &conv16_rgba2bgra; // reuse
        default: assert(0);
    }
}

ubyte luminance(in ubyte r, in ubyte g, in ubyte b)
{
    return cast(ubyte) (0.21*r + 0.64*g + 0.15*b); // arbitrary weights
}

void copy(in ubyte[] src, ubyte[] tgt)
{
    tgt[0..$] = src[0..$];
}

void conv_y2ya(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=1, t+=2) {
        tgt[t] = src[k];
        tgt[t+1] = 255;
    }
}

void conv_y2rgb(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=1, t+=3)
        tgt[t .. t+3] = src[k];
}

void conv_y2rgba(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=1, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = 255;
    }
}

void conv_ya2y(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=2, t+=1)
        tgt[t] = src[k];
}

void conv_ya2rgb(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=2, t+=3)
        tgt[t .. t+3] = src[k];
}

void conv_ya2rgba(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=2, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = src[k+1];
    }
}

void conv_rgb2y(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
}

void conv_rgb2ya(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
        tgt[t+1] = 255;
    }
}

void conv_rgb2rgba(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t .. t+3] = src[k .. k+3];
        tgt[t+3] = 255;
    }
}

void conv_rgb2bgr(in ubyte[] src, ubyte[] tgt)
{
    for (int k;   k < src.length;   k+=3) {
        tgt[k  ] = src[k+2];
        tgt[k+1] = src[k+1];
        tgt[k+2] = src[k  ];
    }
}

void conv_rgb2bgra(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = 255;
    }
}

void conv_rgba2y(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
}

void conv_rgba2ya(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
        tgt[t+1] = src[k+3];
    }
}

void conv_rgba2rgb(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=3)
        tgt[t .. t+3] = src[k .. k+3];
}

void conv_rgba2bgr(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=3) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
    }
}

void conv_rgba2bgra(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = src[k+3];
    }
}

void conv_bgr2y(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance(src[k+2], src[k+1], src[k+1]);
}

void conv_bgr2ya(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance(src[k+2], src[k+1], src[k+1]);
        tgt[t+1] = 255;
    }
}

void conv_bgra2y(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance(src[k+2], src[k+1], src[k]);
}

void conv_bgra2ya(in ubyte[] src, ubyte[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance(src[k+2], src[k+1], src[k]);
        tgt[t+1] = 255;
    }
}

/* --------------- 16-bit --------------- */

ushort luminance16(in ushort r, in ushort g, in ushort b)
{
    return cast(ushort) (0.21*r + 0.64*g + 0.15*b); // arbitrary weights
}

void copy16(in ushort[] src, ushort[] tgt)
{
    tgt[0..$] = src[0..$];
}

void conv16_y2ya(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=1, t+=2) {
        tgt[t] = src[k];
        tgt[t+1] = 0xffff;
    }
}

void conv16_y2rgb(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=1, t+=3)
        tgt[t .. t+3] = src[k];
}

void conv16_y2rgba(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=1, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = 0xffff;
    }
}

void conv16_ya2y(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=2, t+=1)
        tgt[t] = src[k];
}

void conv16_ya2rgb(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=2, t+=3)
        tgt[t .. t+3] = src[k];
}

void conv16_ya2rgba(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=2, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = src[k+1];
    }
}

void conv16_rgb2y(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance16(src[k], src[k+1], src[k+2]);
}

void conv16_rgb2ya(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance16(src[k], src[k+1], src[k+2]);
        tgt[t+1] = 0xffff;
    }
}

void conv16_rgb2rgba(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t .. t+3] = src[k .. k+3];
        tgt[t+3] = 0xffff;
    }
}

void conv16_rgb2bgr(in ushort[] src, ushort[] tgt)
{
    for (int k;   k < src.length;   k+=3) {
        tgt[k  ] = src[k+2];
        tgt[k+1] = src[k+1];
        tgt[k+2] = src[k  ];
    }
}

void conv16_rgb2bgra(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = 0xffff;
    }
}

void conv16_rgba2y(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance16(src[k], src[k+1], src[k+2]);
}

void conv16_rgba2ya(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance16(src[k], src[k+1], src[k+2]);
        tgt[t+1] = src[k+3];
    }
}

void conv16_rgba2rgb(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=3)
        tgt[t .. t+3] = src[k .. k+3];
}

void conv16_rgba2bgr(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=3) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
    }
}

void conv16_rgba2bgra(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = src[k+3];
    }
}

void conv16_bgr2y(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance16(src[k+2], src[k+1], src[k+1]);
}

void conv16_bgr2ya(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance16(src[k+2], src[k+1], src[k+1]);
        tgt[t+1] = 0xffff;
    }
}

void conv16_bgra2y(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance16(src[k+2], src[k+1], src[k]);
}

void conv16_bgra2ya(in ushort[] src, ushort[] tgt)
{
    for (int k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance16(src[k+2], src[k+1], src[k]);
        tgt[t+1] = 0xffff;
    }
}

/*------------------------------*/ package: /*------------------------------*/

ubyte _write_image(int fmt, Writer* wc, int w, int h, in ubyte[] buf, int reqchans)
{
    switch (fmt) {
        case IF_BMP: return write_bmp(wc, w, h, buf, reqchans);
        case IF_TGA: return write_tga(wc, w, h, buf, reqchans);
        case IF_PNG: return write_png(wc, w, h, buf, reqchans);
//        case IF_JPG: return write_jpg(wc, w, h, buf, reqchans);
        default:
            return ERROR.unsupp;
    }
}

enum CHANS { unknown, y, ya, rgb, rgba, bgr, bgra }

struct Reader {
private:
    Read    io;
    ubyte*  buf;
    int     cap;
    int     a;
    int     b;
    int     bufpos;     // buffer's start position
    int     iopos;      // position of the io cursor
public:
    bool    fail;
}

void function(Reader* rc)        fillbuf;
void function(Reader* rc)        reset2start;
void function(Reader* rc, int n) skip;

ubyte init_reader(Reader* rc, Read io, ubyte[] buf)
{
    if (buf.length < 16) {
        if (io.stream) return ERROR.arg;
        if (!buf.length) return ERROR.nodata;
    }
    rc.io = io;
    rc.buf = buf.ptr;
    rc.cap = cast(int) buf.length;
    rc.a = 0;
    rc.b = cast(int) buf.length;
    rc.bufpos = 0;
    rc.iopos = 0;
    rc.fail = false;
    if (rc.io.stream) {
        fillbuf     = &fillbuf_io;
        reset2start = &reset2start_io;
        skip        = &skip_io;
        fillbuf(rc);
        if (rc.iopos == 0)
            return ERROR.nodata;
    } else {
        fillbuf     = &fillbuf_mem;
        reset2start = &reset2start_mem;
        skip        = &skip_mem;
    }
    return 0;
}

void fillbuf_mem(Reader* rc)
{
    rc.a = 0;
    rc.fail = true;
}

void reset2start_mem(Reader* rc)
{
    rc.a = 0;
    rc.fail = false;
}

void skip_mem(Reader* rc, int n)
{
    if (n <= rc.b - rc.a) {
        rc.a += n;
        return;
    }
    rc.fail = true;
}

void fillbuf_io(Reader* rc)
{
    rc.a = 0;
    if (rc.fail)
        return;
    int n = rc.io.read(rc.io.stream, rc.buf, rc.cap);
    rc.bufpos = rc.iopos;
    rc.iopos += n;
    rc.b = n;
    rc.fail = n == 0;
}

void reset2start_io(Reader* rc)
{
    rc.fail = false;
    rc.a = 0;

    // this assumes buffer has been filled
    const int off = -rc.iopos + rc.cap * (rc.bufpos == 0);

    if (rc.io.seek(rc.io.stream, off) == 0)
        rc.iopos += off;
    else
        rc.fail = true;
    if (rc.bufpos != 0)
        fillbuf(rc);
}

void skip_io(Reader* rc, int n)
{
    if (n <= rc.b - rc.a) {
        rc.a += n;
        return;
    }
    if (rc.a < rc.b) {
        n -= rc.b - rc.a;
        rc.a = rc.b;
    }
    if (rc.io.seek(rc.io.stream, n) == 0)
        rc.iopos += n;
    else
        rc.fail = true;
}

// does not allow jumping backwards
void skipto(Reader* rc, int pos)
{
    if (pos >= rc.bufpos + rc.b) {
        skip(rc, pos - rc.bufpos + rc.a);
        return;
    }
    if (pos >= rc.bufpos + rc.a) {
        rc.a = pos - rc.bufpos;
        return;
    }
    rc.fail = true;
}

void read_block(Reader* rc, ubyte[] tgt)
{
    int ti;
    while (true) {
        const size_t need = tgt.length - ti;
        if (rc.a + need <= rc.b) {
            tgt[ti .. $] = rc.buf[rc.a .. rc.a + need];
            rc.a += need;
            return;
        }
        if (rc.a < rc.b) {
            const int got = rc.b - rc.a;
            tgt[ti .. ti + got] = rc.buf[rc.a .. rc.b];
            rc.a += got;
            ti += got;
        }
        fillbuf(rc);
    }
}

// Returns a slice of fresh data in the buffer filling it
// first if no fresh bytes in it already.
ubyte[] read_slice(Reader* rc, in int maxn)
{
    do {
        if (rc.a < rc.b) {
            const int a = rc.a;
            const int avail = rc.b - rc.a;
            const int take = maxn < avail ? maxn : avail;
            rc.a += take;
            return rc.buf[a .. a + take];
        }
        fillbuf(rc);
    } while (!rc.fail);
    return null;
}

ubyte read_u8(Reader* rc)
{
    if (rc.a < rc.b)
        return rc.buf[rc.a++];
    if (rc.b == rc.cap) {
        fillbuf(rc);
        return rc.buf[rc.a++];
    }
    rc.fail = true;
    return 0;
}

ushort read_u16le(Reader* rc)
{
    ubyte a = read_u8(rc);
    return (read_u8(rc) << 8) + a;
}

ushort read_u16be(Reader* rc)
{
    ubyte a = read_u8(rc);
    return (a << 8) + read_u8(rc);
}

uint read_u32le(Reader* rc)
{
    ushort a = read_u16le(rc);
    return (read_u16le(rc) << 16) + a;
}

uint read_u32be(Reader* rc)
{
    ushort a = read_u16be(rc);
    return (a << 16) + read_u16be(rc);
}

struct Writer {
    Write   io;
    ubyte*  buf;
    int     cap;
    int     n;
    bool    fail;
}

ubyte init_writer(Writer* wc, Write io, ubyte[] iobuf)
{
    ubyte e = 0;
    wc.io = io;
    if (io.stream) {
        wc.buf = iobuf.ptr;
        wc.cap = cast(int) iobuf.length;
    } else {
        const int initcap = 32 * 1024;
        wc.buf = new_buffer(initcap, e).ptr;
        wc.cap = initcap;
    }
    wc.n = 0;
    wc.fail = false;
    return e;
}

// Flushes writer's buffer and calls io.flush.
ubyte fullflush(Writer* wc)
{
    if (!wc.io.stream)
        return 0;
    weakflush(wc);
    wc.fail |= wc.io.flush(wc.io.stream) != 0;
    return wc.fail ? ERROR.stream : 0;
}

// Only flushes writer's buffer, does not call io.flush.
void weakflush(Writer* wc)
{
    assert(wc.io.stream);
    int c = 0;
    while (c < wc.n) {
        int written = wc.io.write(wc.io.stream, wc.buf[c..wc.n]);
        c += written;
        if (!written) {
            wc.fail = true;
            return;
        }
    }
    wc.n = 0;
}

void morespace(Writer* wc)
{
    if (wc.io.stream) {
        weakflush(wc);
    } else if (wc.n == wc.cap) {
        const int newcap = 2 * wc.cap;
        ubyte* ptr = cast(ubyte*) _realloc(wc.buf, newcap);
        if (!ptr) {
            wc.fail = true;
        } else {
            wc.cap = newcap;
            wc.buf = ptr;
        }
    }
}

void write_u8(Writer* wc, in ubyte x)
{
    if (wc.n < wc.cap) {
        wc.buf[wc.n++] = x;
        return;
    }
    morespace(wc);
    if (wc.n < wc.cap)
        wc.buf[wc.n++] = x;
}

void write_u16le(Writer* wc, in ushort x)
{
    write_u8(wc, x & 0xff);
    write_u8(wc, x >> 8);
}

void write_u32le(Writer* wc, in uint x)
{
    write_u16le(wc, x & 0xffff);
    write_u16le(wc, x >> 16);
}

void write_block(Writer* wc, in ubyte[] block)
{
    int k = wc.cap - wc.n;
    int todo = cast(int) block.length;
    if (todo <= k) {
        wc.buf[wc.n .. wc.n + todo] = block[0..todo];
        wc.n += todo;
        return;
    }
    int amount = k;
    int bi = 0;
    do {
        wc.buf[wc.n .. wc.n + amount] = block[bi .. bi + amount];
        wc.n += amount;
        todo -= amount;
        if (!todo)
            return;
        bi += amount;
        morespace(wc);
        k = wc.cap - wc.n;
        amount = k < todo ? k : todo;
    } while (!wc.fail);
}

/* --------------- helper constructs --------------- */

int findlast(in char[] s, in char c)
{
    int i;
    for (i = cast(int) s.length - 1; i >= 0; i--) {
        if (s[i] == c)
            break;
    }
    return i;
}

int fname2fmt(in char[] fname)
{
    int i = findlast(fname, '.');
    const int extlen = cast(int) fname.length - i - 1;  // exclude dot
    if (i < 0 || extlen < 3 || extlen > 4)
        return -1;
    char[4] extbuf;
    foreach (k, char c; fname[i+1 .. $])
        extbuf[k] = cast(char) (c >= 'A' && c <= 'Z' ? c + 'a' - 'A' : c);
    char[] ext = extbuf[0..extlen];
    switch (ext[0]) {
        case 't': if (ext == "tga") return IF_TGA; else return -1;
        case 'b': if (ext == "bmp") return IF_BMP; else return -1;
        case 'p': if (ext == "png") return IF_PNG; else return -1;
        case 'j': if (ext == "jpg" || ext == "jpeg") return IF_JPG; return -1;
        default: return -1;
    }
}

ubyte[] new_buffer(in size_t count, ref ubyte err)
{
    ubyte* p = cast(ubyte*) _malloc(count);
    if (!p) {
        err = ERROR.oom;
        return null;
    }
    return p[0..count];
}

ushort[] new_buffer16(in size_t count, ref ubyte err)
{
    ushort* p = cast(ushort*) _malloc(count * ushort.sizeof);
    if (!p) {
        err = ERROR.oom;
        return null;
    }
    return p[0..count];
}

struct NTString {
    const(char)* ptr;
    char[255]    tmp;
    bool         heap;

    @nogc nothrow:

    // Leaves ptr null on malloc error.
    this(in char[] s)
    {
        tmp[0..$] = 0;
        heap = false;
        if (!s.length) {
            ptr = cast(const(char*)) tmp.ptr;
        } else if (s[$-1] == 0) {
            ptr = s.ptr;
        } else if (s.length < tmp.length) {
            tmp[0 .. s.length] = s[0 .. $];
            ptr = cast(const(char*)) tmp.ptr;
        } else {
            ptr = cast(char*) _malloc(s.length + 1);
            if (!ptr)
                return;
            heap = true;
            (cast(char*) ptr)[0..s.length] = s[0..$];
            (cast(char*) ptr)[s.length] = 0;
        }
    }

    void drop() {
        if (heap)
            _free(cast(void*) ptr);
    }
}

unittest {
    string png_path = "tests/pngsuite/";
    string tga_path = "tests/pngsuite-tga/";
    string bmp_path = "tests/pngsuite-bmp/";

    static files = [
        "basi0g08",    // PNG image data, 32 x 32, 8-bit grayscale, interlaced
        "basi2c08",    // PNG image data, 32 x 32, 8-bit/color RGB, interlaced
        "basi3p08",    // PNG image data, 32 x 32, 8-bit colormap, interlaced
        "basi4a08",    // PNG image data, 32 x 32, 8-bit gray+alpha, interlaced
        "basi6a08",    // PNG image data, 32 x 32, 8-bit/color RGBA, interlaced
        "basn0g08",    // PNG image data, 32 x 32, 8-bit grayscale, non-interlaced
        "basn2c08",    // PNG image data, 32 x 32, 8-bit/color RGB, non-interlaced
        "basn3p08",    // PNG image data, 32 x 32, 8-bit colormap, non-interlaced
        "basn4a08",    // PNG image data, 32 x 32, 8-bit gray+alpha, non-interlaced
        "basn6a08",    // PNG image data, 32 x 32, 8-bit/color RGBA, non-interlaced
    ];

    char[256] path;

    static char[] buildpath(ref char[256] path, in char[] dir, in char[] file, in char[] ext)
    {
        path[0 .. dir.length] = dir[0..$];
        path[dir.length .. dir.length + file.length] = file[0..$];
        const size_t ei = dir.length + file.length;
        path[ei .. ei + ext.length] = ext[0..$];
        return path[0 .. ei + ext.length];
    }

    foreach (file; files) {
        //writefln("%s", file);
        auto a = read_image(buildpath(path, png_path, file, ".png"), 4);
        auto b = read_image(buildpath(path, tga_path, file, ".tga"), 4);
        auto c = read_image(buildpath(path, bmp_path, file, ".bmp"), 4);
        scope(exit) {
            a.free();
            b.free();
            c.free();
        }
        assert(a.e + b.e + c.e == 0);
        assert(a.w == b.w && a.w == c.w);
        assert(a.h == b.h && a.h == c.h);
        assert(a.buf8.length == b.buf8.length && a.buf8.length == c.buf8.length);
        assert(a.buf8[0..$] == b.buf8[0..$], "png/tga");
        assert(a.buf8[0..$] == c.buf8[0..$], "png/bmp");
    }
}
