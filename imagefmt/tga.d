// Copyright 2019 Tero Hänninen. All rights reserved.
// SPDX-License-Identifier: BSD-2-Clause
module imagefmt.tga;

import imagefmt;

@nogc nothrow package:

struct TGAHeader {
    int w;
    int h;
    ubyte idlen;
    ubyte palettetype;
    ubyte datatype;
    ubyte bitspp;
    ubyte flags;
}

enum DATATYPE {
    nodata        = 0,
    idx           = 1,
    truecolor     = 2,
    gray          = 3,
    idx_rle       = 9,
    truecolor_rle = 10,
    gray_rle      = 11,
}

bool detect_tga(Reader* rc)
{
    TGAHeader head;
    const bool result = read_tga_header(rc, head) == 0;
    reset2start(rc);
    return result;
}

IFInfo read_tga_info(Reader* rc)
{
    TGAHeader head;
    IFInfo info;
    info.e = read_tga_header(rc, head);
    if (info.e) return info;
    info.w = head.w;
    info.h = head.h;
    info.c = 0;
    const dt = head.datatype;
    if ((dt == DATATYPE.truecolor     || dt == DATATYPE.gray ||
         dt == DATATYPE.truecolor_rle || dt == DATATYPE.gray_rle)
         && (head.bitspp % 8) == 0)
    {
        info.c = head.bitspp / 8;
    }
    info.e = info.c ? 0 : ERROR.unsupp;
    return info;
}

// TGA doesn't have a signature so validate some values right here for detection.
ubyte read_tga_header(Reader* rc, out TGAHeader head)
{
    head.idlen        = read_u8(rc);
    head.palettetype  = read_u8(rc);
    head.datatype     = read_u8(rc);
    ushort palettebeg = read_u16le(rc);
    ushort palettelen = read_u16le(rc);
    ubyte palettebits = read_u8(rc);
    skip(rc, 2 + 2);    // x-origin, y-origin
    head.w            = read_u16le(rc);
    head.h            = read_u16le(rc);
    head.bitspp       = read_u8(rc);
    head.flags        = read_u8(rc);

    if (head.w < 1 || head.h < 1 || head.palettetype > 1
    || (head.palettetype == 0 && (palettebeg || palettelen || palettebits))
    || (head.datatype > 3 && head.datatype < 9) || head.datatype > 11)
        return ERROR.data;

    return 0;
}

ubyte read_tga(Reader* rc, out IFImage image, in int reqchans, in int reqbpc)
{
    if (cast(uint) reqchans > 4)
        return ERROR.arg;
    const ubyte tbpc = cast(ubyte) (reqbpc ? reqbpc : 8);
    if (tbpc != 8 && tbpc != 16)
        return ERROR.unsupp;
    TGAHeader head;
    if (ubyte e = read_tga_header(rc, head))
        return e;
    if (head.w < 1 || head.h < 1)
        return ERROR.dim;
    if (head.flags & 0xc0)  // interlaced; two bits
        return ERROR.unsupp;
    if (head.flags & 0x10)  // right-to-left
        return ERROR.unsupp;
    const ubyte attr_bitspp = (head.flags & 0xf);
    if (attr_bitspp != 0 && attr_bitspp != 8) // some set to 0 even if data has 8
        return ERROR.unsupp;
    if (head.palettetype)
        return ERROR.unsupp;

    switch (head.datatype) {
        case DATATYPE.truecolor:
        case DATATYPE.truecolor_rle:
            if (head.bitspp != 24 && head.bitspp != 32)
                return ERROR.unsupp;
            break;
        case DATATYPE.gray:
        case DATATYPE.gray_rle:
            if (head.bitspp != 8 && !(head.bitspp == 16 && attr_bitspp == 8))
                return ERROR.unsupp;
            break;
        default:
            return ERROR.unsupp;
    }

    const bool origin_at_top = (head.flags & 0x20) > 0;
    const bool rle           = head.datatype >= 9 && head.datatype <= 11;
    const int schans         = head.bitspp / 8;     // = bytes per pixel
    const int tchans         = reqchans ? reqchans : schans;
    const int slinesz        = head.w * schans;
    const int tlinesz        = head.w * tchans;
    const bool flip          = origin_at_top ^ (VERTICAL_ORIENTATION_READ == 1);
    const int tstride        = flip ? -tlinesz             : tlinesz;
    int ti                   = flip ? (head.h-1) * tlinesz : 0;

    if (cast(ulong) head.w * head.h * tchans > MAXIMUM_IMAGE_SIZE)
        return ERROR.bigimg;

    CHANS sfmt;
    switch (schans) {
        case 1: sfmt = CHANS.y; break;
        case 2: sfmt = CHANS.ya; break;
        case 3: sfmt = CHANS.bgr; break;
        case 4: sfmt = CHANS.bgra; break;
        default: assert(0);
    }

    auto convert = cast(conv8) getconv(sfmt, tchans, 8);

    ubyte e;
    ubyte[] result = new_buffer(head.w * head.h * tchans, e);
    ubyte[] sline = new_buffer(slinesz, e);

    if (head.idlen)
        skip(rc, head.idlen);

    if (e || rc.fail) {
        _free(result.ptr);
        _free(sline.ptr);
        return e ? e : ERROR.stream;
    }

    if (!rle) {
        foreach (_; 0 .. head.h) {
            read_block(rc, sline[0..$]);
            convert(sline[0..$], result[ti .. ti + tlinesz]);
            ti += tstride;
        }
        if (rc.fail) {
            _free(result.ptr);
            result = null;
        }
        _free(sline.ptr);

        image.w = head.w;
        image.h = head.h;
        image.c = cast(ubyte) tchans;
        image.cinfile = cast(ubyte) schans;
        image.bpc = 8;
        image.buf8 = result;
        return e;
    }

    // ----- RLE -----

    ubyte[4] pixel;
    int plen = 0;   // packet length
    bool its_rle = false;

    foreach (_; 0 .. head.h) {
        int wanted = slinesz;   // fill sline with unpacked data
        do {
            if (plen == 0) {
                const ubyte phead = read_u8(rc);
                its_rle = cast(bool) (phead & 0x80);
                plen = ((phead & 0x7f) + 1) * schans; // length in bytes
            }
            const int gotten = slinesz - wanted;
            const int copysize = wanted < plen ? wanted : plen;
            if (its_rle) {
                read_block(rc, pixel[0..schans]);
                for (int p = gotten; p < gotten+copysize; p += schans)
                    sline[p .. p + schans] = pixel[0 .. schans];
            } else // raw packet
                read_block(rc, sline[gotten .. gotten+copysize]);
            wanted -= copysize;
            plen -= copysize;
        } while (wanted);

        convert(sline[0..$], result[ti .. ti + tlinesz]);
        ti += tstride;
    }

    if (rc.fail)
        e = ERROR.stream;

    _free(sline.ptr);
    if (e) {
        _free(result.ptr);
        return e;
    }

    image.w = head.w;
    image.h = head.h;
    image.c = cast(ubyte) tchans;
    image.cinfile = schans;
    image.bpc = tbpc;
    if (tbpc == 8) {
        image.buf8 = result;
    } else {
        image.buf16 = bpc8to16(result);
        if (!image.buf16.ptr)
            return ERROR.oom;
    }
    return e;
}

ubyte write_tga(Writer* wc, int w, int h, in ubyte[] buf, in int reqchans)
{
    if (w < 1 || h < 1 || w > ushort.max || h > ushort.max)
        return ERROR.dim;
    const int schans = cast(int) (buf.length / w / h);
    if (schans < 1 || schans > 4 || schans * w * h != buf.length)
        return ERROR.dim;
    if (cast(uint) reqchans > 4)
        return ERROR.unsupp;

    const int tchans = reqchans ? reqchans : schans;
    const bool has_alpha = tchans == 2 || tchans == 4;
    const ubyte datatype = tchans == 3 || tchans == 4
                         ? DATATYPE.truecolor_rle
                         : DATATYPE.gray_rle;

    const ubyte[16] zeros = 0;

    write_u8(wc, 0);    // id length
    write_u8(wc, 0);    // palette type
    write_u8(wc, datatype);
    write_block(wc, zeros[0 .. 5+4]); // palette stuff + x&y-origin
    write_u16le(wc, cast(ushort) w);
    write_u16le(wc, cast(ushort) h);
    write_u8(wc, cast(ubyte) (tchans * 8)); // bitspp
    write_u8(wc, has_alpha ? 0x08 : 0x00);  // flags: attr_bitspp = 8

    if (wc.fail) return ERROR.stream;

    ubyte e = write_tga_idat(wc, w, h, buf, schans, tchans);

    write_block(wc, zeros[0..4+4]); // extension area + developer directory offsets
    write_block(wc, cast(const(ubyte[])) "TRUEVISION-XFILE.\0");

    return wc.fail ? ERROR.stream : e;
}

ubyte write_tga_idat(Writer* wc, in int w, in int h, in ubyte[] buf, in int schans,
                                                                     in int tchans)
{
    int tfmt;
    switch (tchans) {
        case 1: tfmt = CHANS.y; break;
        case 2: tfmt = CHANS.ya; break;
        case 3: tfmt = CHANS.bgr; break;
        case 4: tfmt = CHANS.bgra; break;
        default: assert(0);
    }

    auto convert = cast(conv8) getconv(schans, tfmt, 8);

    const int slinesz = w * schans;
    const int tlinesz = w * tchans;
    const int maxpckts = (tlinesz + 127) / 128;  // max packets per line
    const uint sbufsz = h * slinesz;
    const int sstride = -slinesz * VERTICAL_ORIENTATION_WRITE;
    uint si = (h - 1) * slinesz * (VERTICAL_ORIENTATION_WRITE == 1);

    ubyte e;
    ubyte[] workbuf    = new_buffer(tlinesz + tlinesz + maxpckts, e);
    ubyte[] tline      = workbuf[0..tlinesz];
    ubyte[] compressed = workbuf[tlinesz .. tlinesz + (tlinesz + maxpckts)];

    for (; cast(uint) si < sbufsz; si += sstride) {
        convert(buf[si .. si + slinesz], tline[0..$]);
        const size_t compsz = rle_compress(tline, compressed, w, tchans);
        write_block(wc, compressed[0..compsz]);
    }

    _free(workbuf.ptr);
    return wc.fail ? ERROR.stream : e;
}

size_t rle_compress(in ubyte[] line, ubyte[] cmpr, in size_t w, in int bytespp)
{
    const int rle_limit = 1 < bytespp ? 2 : 3;  // run length worth an RLE packet
    size_t runlen = 0;
    size_t rawlen = 0;
    size_t ri = 0; // start of raw packet data in line
    size_t ci = 0;
    size_t pixels_left = w;
    const(ubyte)[] px;

    for (size_t i = bytespp; pixels_left; i += bytespp) {
        runlen = 1;
        px = line[i-bytespp .. i];
        while (i < line.length && line[i .. i+bytespp] == px[0..$] && runlen < 128) {
            ++runlen;
            i += bytespp;
        }
        pixels_left -= runlen;

        if (runlen < rle_limit) {
            // data goes to raw packet
            rawlen += runlen;
            if (128 <= rawlen) {     // full packet, need to store it
                const size_t copysize = 128 * bytespp;
                cmpr[ci++] = 0x7f; // raw packet header
                cmpr[ci .. ci+copysize] = line[ri .. ri+copysize];
                ci += copysize;
                ri += copysize;
                rawlen -= 128;
            }
        } else { // RLE packet is worth it
            // store raw packet first, if any
            if (rawlen) {
                assert(rawlen < 128);
                const size_t copysize = rawlen * bytespp;
                cmpr[ci++] = cast(ubyte) (rawlen-1); // raw packet header
                cmpr[ci .. ci+copysize] = line[ri .. ri+copysize];
                ci += copysize;
                rawlen = 0;
            }

            // store RLE packet
            cmpr[ci++] = cast(ubyte) (0x80 | (runlen-1)); // packet header
            cmpr[ci .. ci+bytespp] = px[0..$];       // packet data
            ci += bytespp;
            ri = i;
        }
    }   // for

    if (rawlen) {   // last packet of the line
        const size_t copysize = rawlen * bytespp;
        cmpr[ci++] = cast(ubyte) (rawlen-1); // raw packet header
        cmpr[ci .. ci+copysize] = line[ri .. ri+copysize];
        ci += copysize;
    }

    return ci;
}
