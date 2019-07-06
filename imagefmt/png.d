// Copyright 2019 Tero Hänninen. All rights reserved.
// SPDX-License-Identifier: BSD-2-Clause
//
// https://tools.ietf.org/html/rfc2083
// https://www.w3.org/TR/2003/REC-PNG-20031110/
module imagefmt.png;

import etc.c.zlib;
import imagefmt;

@nogc nothrow package:

struct PNGHeader {
    int     w;
    int     h;
    ubyte   bpc;  // bits per component
    ubyte   colortype;
    ubyte   compression;
    ubyte   filter;
    ubyte   interlace;
}

enum CTYPE {
    y    = 0,
    rgb  = 2,
    idx  = 3,
    ya   = 4,
    rgba = 6,
}

enum FILTER { none, sub, up, average, paeth }

struct PNGDecoder {
    Reader* rc;

    int     w;
    int     h;
    ubyte   sbpc;
    ubyte   tbpc;
    ubyte   schans;
    ubyte   tchans;
    bool    indexed;
    bool    interlaced;

    ubyte[12] chunkmeta;
    CRC32   crc;
    union {
        ubyte[] buf8;
        ushort[] buf16;
    }
    ubyte[] palette;
    ubyte[] transparency;

    // decompression
    z_stream*   z;              // zlib stream
    uint        avail_idat;     // available bytes in current idat chunk
    ubyte[]     idat_window;    // slice of reader's buffer
}

immutable ubyte[8] SIGNATURE =
    [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

immutable ubyte[8] HEAD_CHUNK_SIG =
    [0x0, 0x0, 0x0, 0xd, 'I','H','D','R'];

bool detect_png(Reader* rc)
{
    ubyte[8] tmp;
    read_block(rc, tmp[0..$]);
    reset2start(rc);
    return !rc.fail && tmp == SIGNATURE;
}

IFInfo read_png_info(Reader* rc)
{
    PNGHeader head;
    IFInfo info;
    info.e = read_png_header(rc, head);
    info.w = head.w;
    info.h = head.h;
    info.c = channels(head.colortype);
    if (head.colortype == CTYPE.idx && have_tRNS(rc))
        info.c = 4;
    else if (info.c == 0 && !info.e)
        info.e = ERROR.data;
    return info;
}

bool have_tRNS(Reader* rc)
{
    ubyte[12] chunkmeta;
    read_block(rc, chunkmeta[4..$]);  // next chunk's len and type

    while (!rc.fail) {
        uint len = load_u32be(chunkmeta[4..8]);
        if (len > int.max)
            return false;
        switch (cast(char[]) chunkmeta[8..12]) {
            case "tRNS":
                return true;
            case "IDAT":
            case "IEND":
                return false;
            default:
                while (len > 0) {
                    ubyte[] slice = read_slice(rc, len);
                    if (!slice.length)
                        return false;
                    len -= slice.length;
                }
                read_block(rc, chunkmeta[0..$]); // crc | len, type
        }
    }
    return false;
}

ubyte read_png_header(Reader* rc, out PNGHeader head)
{
    ubyte[33] tmp;  // file header, IHDR len+type+data+crc
    read_block(rc, tmp[0..$]);
    if (rc.fail) return ERROR.stream;

    if (tmp[0..8] != SIGNATURE       ||
        tmp[8..16] != HEAD_CHUNK_SIG ||
        tmp[29..33] != CRC32.of(tmp[12..29]))
        return ERROR.data;

    head.w           = load_u32be(tmp[16..20]);
    head.h           = load_u32be(tmp[20..24]);
    head.bpc         = tmp[24];
    head.colortype   = tmp[25];
    head.compression = tmp[26];
    head.filter      = tmp[27];
    head.interlace   = tmp[28];

    return 0;
}

ubyte read_png(Reader* rc, out IFImage image, int reqchans, int reqbpc)
{
    if (cast(uint) reqchans > 4)
        return ERROR.arg;
    if (reqbpc != 0 && reqbpc != 8 && reqbpc != 16)
        return ERROR.unsupp;

    PNGHeader head;
    if (ubyte e = read_png_header(rc, head))
        return e;
    if (head.w < 1 || head.h < 1 || cast(ulong) head.w * head.h > int.max)
        return ERROR.dim;
    if (head.bpc != 8 && head.bpc != 16)
        return ERROR.unsupp;
    if (head.colortype != CTYPE.y    &&
        head.colortype != CTYPE.rgb  &&
        head.colortype != CTYPE.idx  &&
        head.colortype != CTYPE.ya   &&
        head.colortype != CTYPE.rgba)
        return ERROR.unsupp;
    if (head.colortype == CTYPE.idx && head.bpc != 8)
        return ERROR.unsupp;
    if (head.compression != 0 || head.filter != 0 || head.interlace > 1)
        return ERROR.unsupp;

    PNGDecoder dc = {
        rc         : rc,
        w          : head.w,
        h          : head.h,
        sbpc       : head.bpc,
        tbpc       : cast(ubyte) (reqbpc ? reqbpc : head.bpc),
        schans     : channels(head.colortype),  // +1 for indexed if tRNS found later
        tchans     : cast(ubyte) reqchans,  // adjust later
        indexed    : head.colortype == CTYPE.idx,
        interlaced : head.interlace == 1,
        // init the rest later
    };

    ubyte e = read_chunks(&dc);
    _free(dc.palette.ptr);
    _free(dc.transparency.ptr);
    if (e) return e;

    switch (32 * head.bpc + dc.tbpc) {
        case 32 *  8 +  8: image.buf8 = dc.buf8; break;
        case 32 * 16 + 16: image.buf16 = dc.buf16; break;
        case 32 *  8 + 16: image.buf16 = bpc8to16(dc.buf8); break;
        case 32 * 16 +  8: image.buf8 = bpc16to8(dc.buf16); break;
        default: assert(0);
    }
    if (!image.buf8.ptr)
        return ERROR.oom;

    image.w = dc.w;
    image.h = dc.h;
    image.c = cast(ubyte) dc.tchans;
    image.bpc = cast(ubyte) dc.tbpc;
    image.cinfile = cast(ubyte) dc.schans;
    return e;
}

ubyte read_chunks(PNGDecoder* dc)
{
    enum STAGE {
        IHDR_done,
        PLTE_done,
        IDAT_done,
        IEND_done,
    }

    auto stage = STAGE.IHDR_done;

    read_block(dc.rc, dc.chunkmeta[4..$]);  // next chunk's len and type

    while (stage != STAGE.IEND_done && !dc.rc.fail) {
        uint len = load_u32be(dc.chunkmeta[4..8]);
        if (len > int.max)
            return ERROR.data;

        dc.crc.put(dc.chunkmeta[8..12]);  // type
        switch (cast(char[]) dc.chunkmeta[8..12]) {
            case "IDAT":
                if (stage != STAGE.IHDR_done &&
                   (stage != STAGE.PLTE_done || !dc.indexed))
                   return ERROR.data;
                // fixup chans as needed. tRNS only supported for indexed by imagefmt
                dc.schans = dc.indexed && dc.transparency.length ? 4 : dc.schans;
                dc.tchans = dc.tchans ? dc.tchans : dc.schans;
                if (cast(ulong) dc.w * dc.h * dc.tchans > MAXIMUM_IMAGE_SIZE)
                    return ERROR.bigimg;
                ubyte e = read_idat_chunks(dc, len);
                if (e) return e;
                read_block(dc.rc, dc.chunkmeta[0..$]); // crc | len, type
                if (dc.crc.finish_be() != dc.chunkmeta[0..4])
                    return ERROR.data;
                stage = STAGE.IDAT_done;
                break;
            case "PLTE":
                if (stage != STAGE.IHDR_done)
                    return ERROR.data;
                const uint entries = len / 3;
                if (entries * 3 != len || entries > 256)
                    return ERROR.data;
                ubyte e;
                dc.palette = new_buffer(len, e);
                if (e) return e;
                read_block(dc.rc, dc.palette[0..$]);
                dc.crc.put(dc.palette);
                read_block(dc.rc, dc.chunkmeta[0..$]); // crc | len, type
                if (dc.crc.finish_be() != dc.chunkmeta[0..4])
                    return ERROR.data;
                stage = STAGE.PLTE_done;
                break;
            case "tRNS":
                if (! (stage == STAGE.IHDR_done ||
                      (stage == STAGE.PLTE_done && dc.indexed)) )
                    return ERROR.data;
                if (dc.indexed && len * 3 > dc.palette.length || len > 256)
                    return ERROR.data; // that is redundant really --^
                if (!dc.indexed)
                    return ERROR.unsupp;
                ubyte e;
                dc.transparency = new_buffer(256, e); if (e) return e;
                read_block(dc.rc, dc.transparency[0..len]);
                dc.transparency[len..$] = 255;
                read_block(dc.rc, dc.chunkmeta[0..$]);
                if (dc.rc.fail) return ERROR.stream;
                dc.crc.put(dc.transparency[0..$]);
                if (dc.crc.finish_be() != dc.chunkmeta[0..4])
                    return ERROR.data;
                break;
            case "IEND":
                if (stage != STAGE.IDAT_done)
                    return ERROR.data;
                static immutable ubyte[4] IEND_CRC = [0xae, 0x42, 0x60, 0x82];
                read_block(dc.rc, dc.chunkmeta[0..4]);
                if (len != 0 || dc.chunkmeta[0..4] != IEND_CRC)
                    return ERROR.data;
                stage = STAGE.IEND_done;
                break;
            case "IHDR":
                return ERROR.data;
            default:
                // unknown chunk, ignore but check crc
                while (len > 0) {
                    ubyte[] slice = read_slice(dc.rc, len);
                    if (!slice.length)
                        return ERROR.data;
                    len -= slice.length;
                    dc.crc.put(slice[0..$]);
                }
                read_block(dc.rc, dc.chunkmeta[0..$]); // crc | len, type
                if (dc.crc.finish_be() != dc.chunkmeta[0..4])
                    return ERROR.data;
        }
    }

    return 0;
}

ubyte read_idat_chunks(PNGDecoder* dc, in uint len)
{
    // initialize zlib stream
    z_stream z = { zalloc: null, zfree: null, opaque: null };
    if (inflateInit(&z) != Z_OK)
        return ERROR.zinit;
    dc.z = &z;
    dc.avail_idat = len;
    ubyte e;
    switch (dc.sbpc) {
        case 8: e = read_idat8(dc); break;
        case 16: e = read_idat16(dc); break;
        default: e = ERROR.unsupp; break;
    }
    inflateEnd(&z);
    return e;
}

void swap(ref ubyte[] a, ref ubyte[] b)
{
    ubyte[] swap = b;
    b = a;
    a = swap;
}

//; these guys are only used by the read_idat functions and their helpers
private ubyte _png_error = 0;
private void sete(ubyte e)     { if (!_png_error) _png_error = e; }
private bool gete(out ubyte e) { return _png_error ? (e = _png_error) != 0 : false; }

ubyte read_idat8(PNGDecoder* dc)
{
    auto convert = cast(conv8) getconv(dc.schans, dc.tchans, 8);

    const size_t filterstep = dc.indexed ? 1 : dc.schans;
    const size_t uclinesz   = dc.w * filterstep + 1; // uncompr, +1 for filter byte
    const size_t xlinesz    = dc.w * dc.schans * dc.indexed;
    const size_t redlinesz  = dc.w * dc.tchans * dc.interlaced;
    const size_t workbufsz  = 2 * uclinesz + xlinesz + redlinesz;

    ubyte e;
    ubyte[] cline;      // current line
    ubyte[] pline;      // previous line
    ubyte[] xline;      // intermediate buffer/slice for depaletting
    ubyte[] redline;    // reduced image line
    ubyte[] result  = new_buffer(dc.w * dc.h * dc.tchans, e);   if (e) return e;
    ubyte[] workbuf = new_buffer(workbufsz, e);                 if (e) goto fail;
    cline = workbuf[0 .. uclinesz];
    pline = workbuf[uclinesz .. 2*uclinesz];
    xline = dc.indexed ? workbuf[2*uclinesz .. 2*uclinesz + xlinesz] : null;
    redline = dc.interlaced ? workbuf[$-redlinesz .. $] : null;
    workbuf[0..$] = 0;

    sete(0);

    if (!dc.interlaced) {
        const size_t tlinelen = dc.w * dc.tchans;
        size_t ti;
        if (dc.indexed) {
            foreach (_; 0 .. dc.h) {
                uncompress(dc, cline); // cline[0] is the filter type
                recon(cline, pline, filterstep);
                depalette(dc.palette, dc.transparency, cline[1..$], xline);
                convert(xline, result[ti .. ti + tlinelen]);
                ti += tlinelen;
                swap(cline, pline);
            }
        } else {
            foreach (_; 0 .. dc.h) {
                uncompress(dc, cline); // cline[0] is the filter type
                recon(cline, pline, filterstep);
                convert(cline[1..$], result[ti .. ti + tlinelen]);
                ti += tlinelen;
                swap(cline, pline);
            }
        }
    } else {    // Adam7 interlacing
        const size_t[7] redw = a7_init_redw(dc.w);
        const size_t[7] redh = a7_init_redh(dc.h);

        foreach (pass; 0 .. 7) {
            const A7Catapult catapult = a7catapults[pass];
            const size_t slinelen = redw[pass] * dc.schans;
            const size_t tlinelen = redw[pass] * dc.tchans;
            ubyte[] cln = cline[0 .. redw[pass] * filterstep + 1];
            ubyte[] pln = pline[0 .. redw[pass] * filterstep + 1];
            pln[] = 0;  // must be done for defiltering (recon)

            if (dc.indexed) {
                foreach (j; 0 .. redh[pass]) {
                    uncompress(dc, cln); // cln[0] is the filter type
                    recon(cln, pln, filterstep);
                    depalette(dc.palette, dc.transparency, cln[1..$], xline);
                    convert(xline[0 .. slinelen], redline[0 .. tlinelen]);
                    sling(redline, result, catapult, redw[pass], j, dc.w, dc.tchans);
                    swap(cln, pln);
                }
            } else {
                foreach (j; 0 .. redh[pass]) {
                    uncompress(dc, cln); // cln[0] is the filter type
                    recon(cln, pln, filterstep);
                    convert(cln[1 .. 1 + slinelen], redline[0 .. tlinelen]);
                    sling(redline, result, catapult, redw[pass], j, dc.w, dc.tchans);
                    swap(cln, pln);
                }
            }
        }
    }

    if (gete(e)) goto fail;

finish:
    _free(workbuf.ptr);
    dc.buf8 = result[0..$];
    return e;
fail:
    _free(result.ptr);
    result = null;
    goto finish;
}

ubyte read_idat16(PNGDecoder* dc)     // 16-bit is never indexed
{
    auto convert = cast(conv16) getconv(dc.schans, dc.tchans, 16);

    // these are in bytes
    const size_t filterstep = dc.schans * 2;
    const size_t uclinesz   = dc.w * filterstep + 1; // uncompr, +1 for filter byte
    const size_t xlinesz    = dc.w * dc.schans * 2;
    const size_t redlinesz  = dc.w * dc.h * dc.tchans * 2 * dc.interlaced;
    const size_t workbufsz  = 2 * uclinesz + xlinesz + redlinesz;

    // xline is not quite necessary, it could be avoided if the conversion
    // functions were changed to do what line16_from_bytes does.

    ubyte e;
    ubyte[] cline;      // current line
    ubyte[] pline;      // previous line
    ushort[] xline;     // intermediate buffer to catch 16-bit samples
    ushort[] redline;   // reduced image line
    ushort[] result = new_buffer16(dc.w * dc.h * dc.tchans, e); if (e) return e;
    ubyte[] workbuf = new_buffer(workbufsz, e);                 if (e) goto fail;
    cline = workbuf[0 .. uclinesz];
    pline = workbuf[uclinesz .. 2*uclinesz];
    xline = cast(ushort[]) workbuf[2*uclinesz .. 2*uclinesz + xlinesz];
    redline = dc.interlaced ? cast(ushort[]) workbuf[$-redlinesz .. $] : null;
    workbuf[0..$] = 0;

    sete(0);

    if (!dc.interlaced) {
        const size_t tlinelen = dc.w * dc.tchans;
        size_t ti;
        foreach (_; 0 .. dc.h) {
            uncompress(dc, cline); // cline[0] is the filter type
            recon(cline, pline, filterstep);
            line16_from_bytes(cline[1..$], xline);
            convert(xline[0..$], result[ti .. ti + tlinelen]);
            ti += tlinelen;
            swap(cline, pline);
        }
    } else {    // Adam7 interlacing
        const size_t[7] redw = a7_init_redw(dc.w);
        const size_t[7] redh = a7_init_redh(dc.h);

        foreach (pass; 0 .. 7) {
            const A7Catapult catapult = a7catapults[pass];
            const size_t slinelen = redw[pass] * dc.schans;
            const size_t tlinelen = redw[pass] * dc.tchans;
            ubyte[] cln = cline[0 .. redw[pass] * filterstep + 1];
            ubyte[] pln = pline[0 .. redw[pass] * filterstep + 1];
            pln[] = 0;

            foreach (j; 0 .. redh[pass]) {
                uncompress(dc, cln); // cln[0] is the filter type
                recon(cln, pln, filterstep);
                line16_from_bytes(cln[1 .. $], xline[0 .. slinelen]);
                convert(xline[0 .. slinelen], redline[0 .. tlinelen]);
                sling16(redline, result, catapult, redw[pass], j, dc.w, dc.tchans);
                swap(cln, pln);
            }
        }
    }

    if (gete(e)) goto fail;

finish:
    _free(workbuf.ptr);
    dc.buf16 = result[0..$];
    return e;
fail:
    _free(result.ptr);
    result = null;
    goto finish;
}

void line16_from_bytes(in ubyte[] src, ushort[] tgt)
{
    for (size_t k, t;   k < src.length;   k+=2, t+=1) {
        tgt[t] = src[k] << 8 | src[k+1];
    }
}

void sling(in ubyte[] redline, ubyte[] result, A7Catapult cata, in size_t redw,
                                        in size_t j, in int dcw, in int tchans)
{
    for (size_t i, redi; i < redw; ++i, redi += tchans) {
        const size_t ti = cata(i, j, dcw) * tchans;
        result[ti .. ti + tchans] = redline[redi .. redi + tchans];
    }
}

void sling16(in ushort[] redline, ushort[] result, A7Catapult cata, in size_t redw,
                                        in size_t j, in int dcw, in int tchans)
{
    for (size_t i, redi; i < redw; ++i, redi += tchans) {
        const size_t ti = cata(i, j, dcw) * tchans;
        result[ti .. ti + tchans] = redline[redi .. redi + tchans];
    }
}

// Uncompresses a line from the IDAT stream into dst. Calls sete for errors.
void uncompress(PNGDecoder* dc, ubyte[] dst)
{
    dc.z.avail_out = cast(uint) dst.length;
    dc.z.next_out = dst.ptr;

    while (true) {
        if (!dc.z.avail_in) {
            if (!dc.avail_idat) {
                read_block(dc.rc, dc.chunkmeta[0..$]); // crc | len, type
                if (dc.crc.finish_be() != dc.chunkmeta[0..4])
                    return sete(ERROR.data);
                dc.avail_idat = load_u32be(dc.chunkmeta[4..8]);
                if (dc.rc.fail || !dc.avail_idat) return sete(ERROR.data);
                if (dc.chunkmeta[8..12] != "IDAT") return sete(ERROR.lackdata);
                dc.crc.put(dc.chunkmeta[8..12]);
            }
            dc.idat_window = read_slice(dc.rc, dc.avail_idat);
            if (!dc.idat_window) return sete(ERROR.stream);
            dc.crc.put(dc.idat_window);
            dc.avail_idat -= cast(uint) dc.idat_window.length;
            dc.z.avail_in = cast(uint) dc.idat_window.length;
            dc.z.next_in = dc.idat_window.ptr;
        }

        int q = inflate(dc.z, Z_NO_FLUSH);

        if (dc.z.avail_out == 0)
            return;
        if (q != Z_OK)
            return sete(ERROR.zstream);
    }
}

void depalette(in ubyte[] palette, in ubyte[] trns, in ubyte[] sline, ubyte[] dst)
{
    if (trns.length) {
        for (size_t s, d;  s < sline.length;  s+=1, d+=4) {
            const ubyte tidx = sline[s];
            size_t pidx = tidx * 3;
            if (pidx + 3 > palette.length)
                return sete(ERROR.data);
            dst[d .. d+3] = palette[pidx .. pidx+3];
            dst[d+3] = trns[tidx];
        }
    } else {
        for (size_t s, d;  s < sline.length;  s+=1, d+=3) {
            const size_t pidx = sline[s] * 3;
            if (pidx + 3 > palette.length)
                return sete(ERROR.data);
            dst[d .. d+3] = palette[pidx .. pidx+3];
        }
    }
}

void recon(ubyte[] cline, const(ubyte)[] pline, in size_t fstep)
{
    const ubyte ftype = cline[0];
    cline = cline[1..$];
    pline = pline[1..$];
    switch (ftype) {
        case FILTER.none:
            break;
        case FILTER.sub:
            foreach (k; fstep .. cline.length)
                cline[k] += cline[k-fstep];
            break;
        case FILTER.up:
            foreach (k; 0 .. cline.length)
                cline[k] += pline[k];
            break;
        case FILTER.average:
            foreach (k; 0 .. fstep)
                cline[k] += pline[k] / 2;
            foreach (k; fstep .. cline.length)
                cline[k] += cast(ubyte)
                    ((cast(uint) cline[k-fstep] + cast(uint) pline[k]) / 2);
            break;
        case FILTER.paeth:
            foreach (i; 0 .. fstep)
                cline[i] += paeth(0, pline[i], 0);
            foreach (i; fstep .. cline.length)
                cline[i] += paeth(cline[i-fstep], pline[i], pline[i-fstep]);
            break;
        default:
            return sete(ERROR.unsupp);
    }
}

ubyte paeth(in ubyte a, in ubyte b, in ubyte c)
{
    int pc = cast(int) c;
    int pa = cast(int) b - pc;
    int pb = cast(int) a - pc;
    pc = pa + pb;
    if (pa < 0) pa = -pa;
    if (pb < 0) pb = -pb;
    if (pc < 0) pc = -pc;

    if (pa <= pb && pa <= pc) {
        return a;
    } else if (pb <= pc) {
        return b;
    }
    return c;
}

alias A7Catapult = size_t function(size_t redx, size_t redy, size_t dstw);
immutable A7Catapult[7] a7catapults = [
    &a7_red1_to_dst,
    &a7_red2_to_dst,
    &a7_red3_to_dst,
    &a7_red4_to_dst,
    &a7_red5_to_dst,
    &a7_red6_to_dst,
    &a7_red7_to_dst,
];

size_t a7_red1_to_dst(size_t redx, size_t redy, size_t dstw) { return redy*8*dstw + redx*8;     }
size_t a7_red2_to_dst(size_t redx, size_t redy, size_t dstw) { return redy*8*dstw + redx*8+4;   }
size_t a7_red3_to_dst(size_t redx, size_t redy, size_t dstw) { return (redy*8+4)*dstw + redx*4; }
size_t a7_red4_to_dst(size_t redx, size_t redy, size_t dstw) { return redy*4*dstw + redx*4+2;   }
size_t a7_red5_to_dst(size_t redx, size_t redy, size_t dstw) { return (redy*4+2)*dstw + redx*2; }
size_t a7_red6_to_dst(size_t redx, size_t redy, size_t dstw) { return redy*2*dstw + redx*2+1;   }
size_t a7_red7_to_dst(size_t redx, size_t redy, size_t dstw) { return (redy*2+1)*dstw + redx;   }

size_t[7] a7_init_redw(in int w)
{
    const size_t[7] redw = [(w + 7) / 8,
                            (w + 3) / 8,
                            (w + 3) / 4,
                            (w + 1) / 4,
                            (w + 1) / 2,
                            (w + 0) / 2,
                            (w + 0) / 1];
    return redw;
}

size_t[7] a7_init_redh(in int h)
{
    const size_t[7] redh = [(h + 7) / 8,
                            (h + 7) / 8,
                            (h + 3) / 8,
                            (h + 3) / 4,
                            (h + 1) / 4,
                            (h + 1) / 2,
                            (h + 0) / 2];
    return redh;
}

uint load_u32be(in ubyte[4] s)
{
    return (s[0] << 24) + (s[1] << 16) + (s[2] << 8) + s[3];
}

ubyte[4] u32_to_be(in uint x)
{
    return [cast(ubyte) (x >> 24), cast(ubyte) (x >> 16),
            cast(ubyte) (x >> 8),  cast(ubyte) x];
}

ubyte channels(in ubyte colortype)
{
    switch (cast(CTYPE) colortype) {
        case CTYPE.y: return 1;
        case CTYPE.ya: return 2;
        case CTYPE.rgb: return 3;
        case CTYPE.rgba: return 4;
        case CTYPE.idx: return 3;   // +1 if tRNS chunk present
        default: return 0;
    }
}

ubyte write_png(Writer* wc, int w, int h, in ubyte[] buf, in int reqchans)
{
    if (w < 1 || h < 1)
        return ERROR.dim;
    const uint schans = cast(uint) (buf.length / w / h);
    if (schans < 1 || schans > 4 || schans * w * h != buf.length)
        return ERROR.dim;
    if (cast(uint) reqchans > 4)
        return ERROR.unsupp;

    const uint tchans = cast(uint) reqchans ? reqchans : schans;
    ubyte colortype;
    switch (tchans) {
        case 1: colortype = CTYPE.y; break;
        case 2: colortype = CTYPE.ya; break;
        case 3: colortype = CTYPE.rgb; break;
        case 4: colortype = CTYPE.rgba; break;
        default: assert(0);
    }

    ubyte[13] head; // data part of IHDR chunk
    head[0..4]   = u32_to_be(cast(uint) w);
    head[4..8]   = u32_to_be(cast(uint) h);
    head[8]      = 8; // bit depth
    head[9]      = colortype;
    head[10..13] = 0; // compression, filter and interlace methods

    CRC32 crc;
    crc.put(cast(ubyte[]) "IHDR");
    crc.put(head);

    write_block(wc, SIGNATURE);
    write_block(wc, HEAD_CHUNK_SIG);
    write_block(wc, head);
    write_block(wc, crc.finish_be());

    if (wc.fail) return ERROR.stream;

    PNGEncoder ec = {
        wc: wc,
        w: w,
        h: h,
        schans: schans,
        tchans: tchans,
        buf: buf,
    };

    ubyte e = write_idat(ec);
    if (e) return e;

    static immutable ubyte[12] IEND =
        [0, 0, 0, 0, 'I','E','N','D', 0xae, 0x42, 0x60, 0x82];
    write_block(wc, IEND);

    return wc.fail ? ERROR.stream : e;
}

struct PNGEncoder {
    Writer*     wc;
    size_t      w;
    size_t      h;
    uint        schans;
    uint        tchans;
    const(ubyte)[] buf;
    CRC32       crc;
    z_stream*   z;
    ubyte[]     idatbuf;
}

enum MAXIMUM_CHUNK_SIZE = 8192;

ubyte write_idat(ref PNGEncoder ec)
{
    // initialize zlib stream
    z_stream z = { zalloc: null, zfree: null, opaque: null };
    if (deflateInit(&z, Z_DEFAULT_COMPRESSION) != Z_OK)
        return ERROR.zinit;
    scope(exit)
        deflateEnd(ec.z);
    ec.z = &z;

    auto convert = cast(conv8) getconv(ec.schans, ec.tchans, 8);

    const size_t slinesz = ec.w * ec.schans;
    const size_t tlinesz = ec.w * ec.tchans + 1;
    const size_t filterstep = ec.tchans;
    const size_t workbufsz = 3 * tlinesz + MAXIMUM_CHUNK_SIZE;

    ubyte e;
    ubyte[] workbuf  = new_buffer(workbufsz, e);    if (e) return e;
    ubyte[] cline    = workbuf[0 .. tlinesz];
    ubyte[] pline    = workbuf[tlinesz .. 2 * tlinesz];
    ubyte[] filtered = workbuf[2 * tlinesz .. 3 * tlinesz];
    ec.idatbuf       = workbuf[$-MAXIMUM_CHUNK_SIZE .. $];
    workbuf[0..$] = 0;
    ec.z.avail_out = cast(uint) ec.idatbuf.length;
    ec.z.next_out = ec.idatbuf.ptr;

    sete(0);

    const size_t tsize = ec.w * ec.tchans * ec.h;

    for (size_t si; si < tsize; si += slinesz) {
        convert(ec.buf[si .. si + slinesz], cline[1..$]);

        // these loops could be merged with some extra space...
        foreach (i; 1 .. filterstep+1)
            filtered[i] = cast(ubyte) (cline[i] - paeth(0, pline[i], 0));
        foreach (i; filterstep+1 .. tlinesz)
            filtered[i] = cast(ubyte)
            (cline[i] - paeth(cline[i-filterstep], pline[i], pline[i-filterstep]));
        filtered[0] = FILTER.paeth;

        compress(ec, filtered);
        swap(cline, pline);
    }

    while (!gete(e)) {  // flush zlib
        int q = deflate(ec.z, Z_FINISH);
        if (ec.idatbuf.length - ec.z.avail_out > 0)
            flush_idat(ec);
        if (q == Z_STREAM_END) break;
        if (q == Z_OK) continue;    // not enough avail_out
        sete(ERROR.zstream);
    }

finish:
    _free(workbuf.ptr);
    return e;
}

void compress(ref PNGEncoder ec, in ubyte[] line)
{
    ec.z.avail_in = cast(uint) line.length;
    ec.z.next_in = line.ptr;
    while (ec.z.avail_in) {
        int q = deflate(ec.z, Z_NO_FLUSH);
        if (q != Z_OK) return sete(ERROR.zstream);
        if (ec.z.avail_out == 0)
            flush_idat(ec);
    }
}

void flush_idat(ref PNGEncoder ec)      // writes an idat chunk
{
    if (ec.wc.fail) return;
    const uint len = cast(uint) (ec.idatbuf.length - ec.z.avail_out);
    ec.crc.put(cast(const(ubyte)[]) "IDAT");
    ec.crc.put(ec.idatbuf[0 .. len]);
    write_block(ec.wc, u32_to_be(len));
    write_block(ec.wc, cast(const(ubyte)[]) "IDAT");
    write_block(ec.wc, ec.idatbuf[0 .. len]);
    write_block(ec.wc, ec.crc.finish_be());
    ec.z.next_out = ec.idatbuf.ptr;
    ec.z.avail_out = cast(uint) ec.idatbuf.length;
    if (ec.wc.fail) sete(ERROR.stream);
}

struct CRC32 {
    uint r = 0xffff_ffff;

    @nogc nothrow:

    void put(in ubyte[] data)
    {
        foreach (b; data) {
            const int i = b ^ cast(ubyte) r;
            r = (r >> 8) ^ CRC32TAB[i];
        }
    }

    ubyte[4] finish_be()
    {
        ubyte[4] result = u32_to_be(r ^ 0xffff_ffff);
        r = 0xffff_ffff;
        return result;
    }

    static ubyte[4] of(in ubyte[] data)
    {
        CRC32 c;
        c.put(data);
        return c.finish_be();
    }
}

immutable uint[256] CRC32TAB = [
    0x00000000, 0x77073096, 0xee0e612c, 0x990951ba,
    0x076dc419, 0x706af48f, 0xe963a535, 0x9e6495a3,
    0x0edb8832, 0x79dcb8a4, 0xe0d5e91e, 0x97d2d988,
    0x09b64c2b, 0x7eb17cbd, 0xe7b82d07, 0x90bf1d91,
    0x1db71064, 0x6ab020f2, 0xf3b97148, 0x84be41de,
    0x1adad47d, 0x6ddde4eb, 0xf4d4b551, 0x83d385c7,
    0x136c9856, 0x646ba8c0, 0xfd62f97a, 0x8a65c9ec,
    0x14015c4f, 0x63066cd9, 0xfa0f3d63, 0x8d080df5,
    0x3b6e20c8, 0x4c69105e, 0xd56041e4, 0xa2677172,
    0x3c03e4d1, 0x4b04d447, 0xd20d85fd, 0xa50ab56b,
    0x35b5a8fa, 0x42b2986c, 0xdbbbc9d6, 0xacbcf940,
    0x32d86ce3, 0x45df5c75, 0xdcd60dcf, 0xabd13d59,
    0x26d930ac, 0x51de003a, 0xc8d75180, 0xbfd06116,
    0x21b4f4b5, 0x56b3c423, 0xcfba9599, 0xb8bda50f,
    0x2802b89e, 0x5f058808, 0xc60cd9b2, 0xb10be924,
    0x2f6f7c87, 0x58684c11, 0xc1611dab, 0xb6662d3d,
    0x76dc4190, 0x01db7106, 0x98d220bc, 0xefd5102a,
    0x71b18589, 0x06b6b51f, 0x9fbfe4a5, 0xe8b8d433,
    0x7807c9a2, 0x0f00f934, 0x9609a88e, 0xe10e9818,
    0x7f6a0dbb, 0x086d3d2d, 0x91646c97, 0xe6635c01,
    0x6b6b51f4, 0x1c6c6162, 0x856530d8, 0xf262004e,
    0x6c0695ed, 0x1b01a57b, 0x8208f4c1, 0xf50fc457,
    0x65b0d9c6, 0x12b7e950, 0x8bbeb8ea, 0xfcb9887c,
    0x62dd1ddf, 0x15da2d49, 0x8cd37cf3, 0xfbd44c65,
    0x4db26158, 0x3ab551ce, 0xa3bc0074, 0xd4bb30e2,
    0x4adfa541, 0x3dd895d7, 0xa4d1c46d, 0xd3d6f4fb,
    0x4369e96a, 0x346ed9fc, 0xad678846, 0xda60b8d0,
    0x44042d73, 0x33031de5, 0xaa0a4c5f, 0xdd0d7cc9,
    0x5005713c, 0x270241aa, 0xbe0b1010, 0xc90c2086,
    0x5768b525, 0x206f85b3, 0xb966d409, 0xce61e49f,
    0x5edef90e, 0x29d9c998, 0xb0d09822, 0xc7d7a8b4,
    0x59b33d17, 0x2eb40d81, 0xb7bd5c3b, 0xc0ba6cad,
    0xedb88320, 0x9abfb3b6, 0x03b6e20c, 0x74b1d29a,
    0xead54739, 0x9dd277af, 0x04db2615, 0x73dc1683,
    0xe3630b12, 0x94643b84, 0x0d6d6a3e, 0x7a6a5aa8,
    0xe40ecf0b, 0x9309ff9d, 0x0a00ae27, 0x7d079eb1,
    0xf00f9344, 0x8708a3d2, 0x1e01f268, 0x6906c2fe,
    0xf762575d, 0x806567cb, 0x196c3671, 0x6e6b06e7,
    0xfed41b76, 0x89d32be0, 0x10da7a5a, 0x67dd4acc,
    0xf9b9df6f, 0x8ebeeff9, 0x17b7be43, 0x60b08ed5,
    0xd6d6a3e8, 0xa1d1937e, 0x38d8c2c4, 0x4fdff252,
    0xd1bb67f1, 0xa6bc5767, 0x3fb506dd, 0x48b2364b,
    0xd80d2bda, 0xaf0a1b4c, 0x36034af6, 0x41047a60,
    0xdf60efc3, 0xa867df55, 0x316e8eef, 0x4669be79,
    0xcb61b38c, 0xbc66831a, 0x256fd2a0, 0x5268e236,
    0xcc0c7795, 0xbb0b4703, 0x220216b9, 0x5505262f,
    0xc5ba3bbe, 0xb2bd0b28, 0x2bb45a92, 0x5cb36a04,
    0xc2d7ffa7, 0xb5d0cf31, 0x2cd99e8b, 0x5bdeae1d,
    0x9b64c2b0, 0xec63f226, 0x756aa39c, 0x026d930a,
    0x9c0906a9, 0xeb0e363f, 0x72076785, 0x05005713,
    0x95bf4a82, 0xe2b87a14, 0x7bb12bae, 0x0cb61b38,
    0x92d28e9b, 0xe5d5be0d, 0x7cdcefb7, 0x0bdbdf21,
    0x86d3d2d4, 0xf1d4e242, 0x68ddb3f8, 0x1fda836e,
    0x81be16cd, 0xf6b9265b, 0x6fb077e1, 0x18b74777,
    0x88085ae6, 0xff0f6a70, 0x66063bca, 0x11010b5c,
    0x8f659eff, 0xf862ae69, 0x616bffd3, 0x166ccf45,
    0xa00ae278, 0xd70dd2ee, 0x4e048354, 0x3903b3c2,
    0xa7672661, 0xd06016f7, 0x4969474d, 0x3e6e77db,
    0xaed16a4a, 0xd9d65adc, 0x40df0b66, 0x37d83bf0,
    0xa9bcae53, 0xdebb9ec5, 0x47b2cf7f, 0x30b5ffe9,
    0xbdbdf21c, 0xcabac28a, 0x53b39330, 0x24b4a3a6,
    0xbad03605, 0xcdd70693, 0x54de5729, 0x23d967bf,
    0xb3667a2e, 0xc4614ab8, 0x5d681b02, 0x2a6f2b94,
    0xb40bbe37, 0xc30c8ea1, 0x5a05df1b, 0x2d02ef8d
];
