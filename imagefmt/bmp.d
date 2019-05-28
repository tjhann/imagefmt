// Copyright 2019 Tero Hänninen. All rights reserved.
// SPDX-License-Identifier: BSD-2-Clause
module imagefmt.bmp;

import imagefmt;

//@nogc nothrow package:
nothrow:

struct BMPHeader {
    int w;              // can be negative
    int h;              // can be negative
    int planes;         // only checked, not otherwise used...
    int bitspp;
    uint dataoff;
    uint alphamask;     // alpha; from dibv3
    uint rmask;         // red
    uint gmask;         // green
    uint bmask;         // blue
    uint compress;
    uint palettelen;
    uint dibsize;
    ubyte dibv;         // dib header version
}

int abs(int x) { return x >= 0 ? x : -x; }

bool detect_bmp(Reader* rc)
{
    bool result;
    if (read_u8(rc) != 'B' || read_u8(rc) != 'M') {
        result = false;
    } else {
        skip(rc, 12);
        const uint ds = read_u32le(rc);
        result = ((ds == 12 || ds == 40 || ds == 52 ||
                   ds == 56 || ds == 108 || ds == 124) && !rc.fail);
    }
    reset2start(rc);
    return result;
}

IFInfo read_bmp_info(Reader* rc)
{
    BMPHeader head;
    IFInfo info;
    info.e = read_bmp_header(rc, head);
    if (info.e) return info;
    info.w = abs(head.w);
    info.h = abs(head.h);
    info.c = (head.dibv >= 3 && head.alphamask != 0 && head.bitspp == 32) ? 4 : 3;
    return info;
}

ubyte read_bmp_header(Reader* rc, out BMPHeader head)
{
    ubyte b = read_u8(rc);
    ubyte m = read_u8(rc);

    skip(rc, 8);    // filesize (4) + reserved bytes
    head.dataoff = read_u32le(rc);
    head.dibsize = read_u32le(rc);

    if (rc.fail)
        return ERROR.stream;

    if (b != 'B' || m != 'M')
        return ERROR.data;

    switch (head.dibsize) {
        case 12: head.dibv = 0; break;
        case 40: head.dibv = 1; break;
        case 52: head.dibv = 2; break;
        case 56: head.dibv = 3; break;
        case 108: head.dibv = 4; break;
        case 124: head.dibv = 5; break;
        default: return ERROR.unsupp;
    }

    if (head.dibsize <= 12) {
        head.w      = read_u16le(rc);
        head.h      = read_u16le(rc);
        head.planes = read_u16le(rc);
        head.bitspp = read_u16le(rc);
    } else {
        head.w      = cast(int) read_u32le(rc);
        head.h      = cast(int) read_u32le(rc);
        head.planes = read_u16le(rc);
        head.bitspp = read_u16le(rc);
    }

    if (head.dibsize >= 40) {
        head.compress = read_u32le(rc);
        skip(rc, 4 * 3); // image data size + pixels per meter x & y
        head.palettelen = read_u32le(rc);
        skip(rc, 4);    // important color count
    }

    if (head.dibsize >= 52) {
        head.rmask = read_u32le(rc);
        head.gmask = read_u32le(rc);
        head.bmask = read_u32le(rc);
    }

    if (head.dibsize >= 56)
        head.alphamask = read_u32le(rc);

    if (head.dibsize >= 108)
        skip(rc, 4 + 36 + 4*3); // color space type + endpoints + rgb-gamma

    if (head.dibsize >= 124)
        skip(rc, 8);    // icc profile data + size

    if (rc.fail)
        return ERROR.stream;

    if (head.w == int.min || head.h == int.min)
        return ERROR.data;  // make abs simple

    return 0;
}

enum CMP_RGB  = 0;
enum CMP_BITS = 3;

ubyte read_bmp(Reader* rc, out IFImage image, in int reqchans, in int reqbpc)
{
    if (cast(uint) reqchans > 4)
        return ERROR.arg;
    const ubyte tbpc = cast(ubyte) (reqbpc ? reqbpc : 8);
    if (tbpc != 8 && tbpc != 16)
        return ERROR.unsupp;
    BMPHeader head;
    if (ubyte e = read_bmp_header(rc, head))
        return e;
    if (head.w < 1 || head.h == 0)
        return ERROR.dim;
    if (head.dataoff < (14 + head.dibsize) || head.dataoff > 0xffffff)
        return ERROR.data;    // that upper limit is arbitrary --^
    if (head.planes != 1)
        return ERROR.unsupp;

    int bytes_pp    = 1;
    bool paletted   = true;
    int palettelen  = 256;
    bool rgb_masked = false;
    int pe_bytes_pp = 3;

    if (head.dibv >= 1) {
        if (head.palettelen > 256)
            return ERROR.dim;
        if (head.bitspp <= 8 && (head.palettelen == 0 || head.compress != CMP_RGB))
            return ERROR.unsupp;
        if (head.compress != CMP_RGB && head.compress != CMP_BITS)
            return ERROR.unsupp;

        switch (head.bitspp) {
            case 8  : bytes_pp = 1; paletted = true; break;
            case 24 : bytes_pp = 3; paletted = false; break;
            case 32 : bytes_pp = 4; paletted = false; break;
            default: return ERROR.unsupp;
        }

        palettelen = head.palettelen;
        rgb_masked = head.compress == CMP_BITS;
        pe_bytes_pp = 4;
    }

    int redi = 2;
    int grei = 1;
    int blui = 0;

    if (rgb_masked) {
        if (head.dibv < 2)
            return ERROR.data;
        if (mask2idx(head.rmask, redi)
         || mask2idx(head.gmask, grei)
         || mask2idx(head.bmask, blui))
            return ERROR.unsupp;
    }

    bool alphamasked = false;
    int alphai = 0;

    if (bytes_pp == 4 && head.dibv >= 3 && head.alphamask != 0) {
        alphamasked = true;
        if (mask2idx(head.alphamask, alphai))
            return ERROR.unsupp;
    }

    const int tchans = reqchans > 0 ? reqchans
                                    : alphamasked ? CHANS.rgba
                                                  : CHANS.rgb;

    // note: this does not directly match cinfile, see alphamasked
    const int sfmt = paletted && pe_bytes_pp == 3 ? CHANS.bgr
                                                  : CHANS.bgra;

    auto convert = cast(conv8) getconv(sfmt, tchans, 8);

    const int slinesz = head.w * bytes_pp;    // without padding
    const int srcpad  = 3 - ((slinesz-1) % 4);
    const int tlinesz = head.w * tchans;
    const int tstride = head.h < 0 ? tlinesz : -tlinesz;
    const int height  = abs(head.h);
    const int ti_start  = head.h < 0 ? 0 : (head.h-1) * tlinesz;
    const uint ti_limit = height * tlinesz;

    ubyte e;

    if (cast(ulong) head.w * height * tchans > MAXIMUM_IMAGE_SIZE)
        return ERROR.bigimg;

    ubyte[] result       = new_buffer(head.w * height * tchans, e);
    if (e) return e;
    ubyte[] sline        = null;
    ubyte[] xline        = null;  // intermediate buffer
    ubyte[] palette      = null;
    ubyte[] workbuf      = new_buffer(slinesz + srcpad + head.w * 4, e);
    if (e) goto failure;
    sline                = workbuf[0 .. slinesz + srcpad];
    xline                = workbuf[sline.length .. sline.length + head.w * 4];

    if (paletted) {
        palette = new_buffer(palettelen * pe_bytes_pp, e);
        if (e) goto failure;
        read_block(rc, palette[0..$]);
    }

    skipto(rc, head.dataoff);

    if (rc.fail) {
        e = ERROR.stream;
        goto failure;
    }

    if (!paletted) {
        for (int ti = ti_start; cast(uint) ti < ti_limit; ti += tstride) {
            read_block(rc, sline[0..$]);
            for (size_t si, di;   si < slinesz;   si+=bytes_pp, di+=4) {
                xline[di + 0] = sline[si + blui];
                xline[di + 1] = sline[si + grei];
                xline[di + 2] = sline[si + redi];
                xline[di + 3] = alphamasked ? sline[si + alphai]
                                            : 255;
            }
            convert(xline[0..$], result[ti .. ti + tlinesz]);
        }
    } else {
        const int ps = pe_bytes_pp;
        for (int ti = ti_start; cast(uint) ti < ti_limit; ti += tstride) {
            read_block(rc, sline[0..$]);
            int di = 0;
            foreach (idx; sline[0 .. slinesz]) {
                if (idx > palettelen) {
                    e = ERROR.data;
                    goto failure;
                }
                const int i = idx * ps;
                xline[di + 0] = palette[i + 0];
                xline[di + 1] = palette[i + 1];
                xline[di + 2] = palette[i + 2];
                if (ps == 4)
                    xline[di + 3] = 255;
                di += ps;
            }
            convert(xline[0..$], result[ti .. ti + tlinesz]);
        }
    }

    if (rc.fail) goto failure;
finish:
    _free(workbuf.ptr);
    _free(palette.ptr);
    image.w = head.w;
    image.h = abs(head.h);
    image.c = cast(ubyte) tchans;
    image.cinfile = head.dibv >= 3 && head.alphamask != 0 && head.bitspp == 32
                  ? 4 : 3;
    image.bpc = tbpc;
    if (tbpc == 8) {
        image.buf8 = result;
    } else if (result) {
        image.buf16 = bpc8to16(result);
        if (!image.buf16.ptr && !e)
            e = ERROR.oom;
    }
    return e;
failure:
    _free(result.ptr);
    result = null;
    goto finish;
}

bool mask2idx(in uint mask, out int index)
{
    switch (mask) {
        case 0xff00_0000: index = 3; return false;
        case 0x00ff_0000: index = 2; return false;
        case 0x0000_ff00: index = 1; return false;
        case 0x0000_00ff: index = 0; return false;
        default: return true;
    }
}

// Note: will only write RGB and RGBA images.
ubyte write_bmp(Writer* wc, int w, int h, in ubyte[] buf, int reqchans)
{
    if (w < 1 || h < 1 || w > 0x7fff || h > 0x7fff)
        return ERROR.dim;
    const int schans = cast(int) (buf.length / w / h);
    if (schans < 1 || schans > 4 || schans * w * h != buf.length)
        return ERROR.dim;
    if (reqchans != 0 && reqchans != 3 && reqchans != 4)
        return ERROR.unsupp;

    const int tchans = reqchans ? reqchans
                                : schans == 1 || schans == 3 ? 3 : 4;

    const uint dibsize = 108;
    const uint tlinesz = cast(size_t) (w * tchans);
    const uint pad = 3 - ((tlinesz-1) % 4);
    const uint idat_offset = 14 + dibsize;       // bmp file header + dib header
    const size_t filesize = idat_offset + cast(size_t) h * (tlinesz + pad);
    if (filesize > 0xffff_ffff)
        return ERROR.bigimg;
    const ubyte[64] zeros = 0;

    write_u8(wc, 'B');
    write_u8(wc, 'M');
    write_u32le(wc, cast(uint) filesize);
    write_u32le(wc, 0);     // reserved
    write_u32le(wc, idat_offset);
    write_u32le(wc, dibsize);
    write_u32le(wc, w);
    write_u32le(wc, h);     // positive -> bottom-up
    write_u16le(wc, 1);     // planes
    write_u16le(wc, cast(ushort) (tchans * 8));   // bitspp
    write_u32le(wc, tchans == 3 ? CMP_RGB : CMP_BITS);
    write_block(wc, zeros[0..20]);      // rest of dibv1
    if (tchans == 3) {
        write_block(wc, zeros[0..16]);  // dibv2 and dibv3
    } else {
        static immutable ubyte[16] masks = [
            0, 0, 0xff, 0,
            0, 0xff, 0, 0,
            0xff, 0, 0, 0,
            0, 0, 0, 0xff
        ];
        write_block(wc, masks[0..$]);
    }
    write_u8(wc, 'B');
    write_u8(wc, 'G');
    write_u8(wc, 'R');
    write_u8(wc, 's');
    write_block(wc, zeros[0..48]);

    if (wc.fail)
        return ERROR.stream;

    auto convert =
        cast(conv8) getconv(schans, tchans == 3 ? CHANS.bgr : CHANS.bgra, 8);

    const size_t slinesz = cast(size_t) w * schans;
    size_t si = cast(size_t) h * slinesz;

    ubyte e;
    ubyte[] tline = new_buffer(tlinesz + pad, e);

    if (e)
        goto finish;

    foreach (_; 0..h) {
        si -= slinesz;
        convert(buf[si .. si + slinesz], tline[0..tlinesz]);
        write_block(wc, tline[0..$]);
    }

    if (wc.fail)
        e = ERROR.stream;

finish:
    _free(tline.ptr);
    return e;
}
