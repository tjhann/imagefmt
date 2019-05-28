// Copyright 2019 Tero Hänninen. All rights reserved.
// SPDX-License-Identifier: BSD-2-Clause
module imagefmt.jpeg;

import std.math : ceil;
import imagefmt;

//@nogc nothrow package:
nothrow:

struct JPEGDecoder {
    Reader* rc;

    ubyte[64][4] qtables;
    HuffTab[2] ac_tables;
    HuffTab[2] dc_tables;

    int bits_left;   // num of unused bits in cb
    ubyte cb;  // current byte (next bit always at MSB)

    bool has_frame_header = false;
    bool eoi_reached = false;

    bool correct_comp_ids;
    ubyte[] compsbuf;
    Component[3] comps;
    ubyte num_comps;
    int tchans;

    int width;
    int height;
    int hmax;
    int vmax;
    int num_mcu_x;
    int num_mcu_y;

    ushort restart_interval;    // number of MCUs in restart interval
}

// image component
struct Component {
    size_t x;       // total num of samples, without fill samples
    size_t y;       // total num of samples, without fill samples
    ubyte[] data;   // reconstructed samples
    int pred;       // dc prediction
    ubyte sfx;      // sampling factor, aka. h
    ubyte sfy;      // sampling factor, aka. v
    ubyte qtable;
    ubyte ac_table;
    ubyte dc_table;
}

struct HuffTab {
    ubyte[256] values;
    ubyte[257] sizes;
    short[16] mincode;
    short[16] maxcode;
    short[16] valptr;
}

enum MARKER : ubyte {
    SOI = 0xd8,     // start of image
    SOF0 = 0xc0,    // start of frame / baseline DCT
    //SOF1 = 0xc1,    // start of frame / extended seq.
    //SOF2 = 0xc2,    // start of frame / progressive DCT
    SOF3 = 0xc3,    // start of frame / lossless
    SOF9 = 0xc9,    // start of frame / extended seq., arithmetic
    SOF11 = 0xcb,    // start of frame / lossless, arithmetic
    DHT = 0xc4,     // define huffman tables
    DQT = 0xdb,     // define quantization tables
    DRI = 0xdd,     // define restart interval
    SOS = 0xda,     // start of scan
    DNL = 0xdc,     // define number of lines
    RST0 = 0xd0,    // restart entropy coded data
    // ...
    RST7 = 0xd7,    // restart entropy coded data
    APP0 = 0xe0,    // application 0 segment
    // ...
    APPf = 0xef,    // application f segment
    //DAC = 0xcc,     // define arithmetic conditioning table
    COM = 0xfe,     // comment
    EOI = 0xd9,     // end of image
}

bool detect_jpeg(Reader* rc)
{
    auto info = read_jpeg_info(rc);
    reset2start(rc);
    return info.e == 0;
}

IFInfo infoerror(ubyte e)
{
    IFInfo info = { e: e };
    return info;
}

IFInfo read_jpeg_info(Reader* rc)
{
    if (read_u8(rc) != 0xff || read_u8(rc) != MARKER.SOI)
       return infoerror(rc.fail ? ERROR.stream : ERROR.data);

    while (true) {
        if (read_u8(rc) != 0xff)
            return infoerror(rc.fail ? ERROR.stream : ERROR.data);

        ubyte marker = read_u8(rc);
        while (marker == 0xff && !rc.fail)
            marker = read_u8(rc);

        if (rc.fail)
            return infoerror(ERROR.stream);

        switch (marker) with (MARKER) {
            case SOF0: .. case SOF3:
            case SOF9: .. case SOF11:
                skip(rc, 3); // len + some byte
                IFInfo info;
                info.h = read_u16be(rc);
                info.w = read_u16be(rc);
                info.c = read_u8(rc);
                info.e = rc.fail ? ERROR.stream : 0;
                return info;
            case SOS, EOI:
                return infoerror(ERROR.data);
            case DRI, DHT, DQT, COM:
            case APP0: .. case APPf:
                int len = read_u16be(rc) - 2;
                skip(rc, len);
                break;
            default:
                return infoerror(ERROR.unsupp);
        }
    }
    assert(0);
}

ubyte read_jpeg(Reader* rc, out IFImage image, in int reqchans, in int reqbpc)
{
    if (cast(uint) reqchans > 4)
        return ERROR.arg;
    const ubyte tbpc = cast(ubyte) (reqbpc ? reqbpc : 8);
    if (tbpc != 8 && tbpc != 16)
        return ERROR.unsupp;
    if (read_u8(rc) != 0xff || read_u8(rc) != MARKER.SOI)
       return rc.fail ? ERROR.stream : ERROR.data;
    if (rc.fail)
        return ERROR.stream;

    JPEGDecoder dc = { rc: rc };

    ubyte e = read_markers(dc);   // reads until first scan header or eoi

    if (e) return e;
    if (dc.eoi_reached) return ERROR.data;

    dc.tchans = reqchans == 0 ? dc.num_comps : reqchans;

    if (cast(ulong) dc.width * dc.height * dc.tchans > MAXIMUM_IMAGE_SIZE)
        return ERROR.bigimg;

    {
        size_t[3] csizes;
        size_t acc;
        foreach (i, ref comp; dc.comps[0..dc.num_comps]) {
            csizes[i] = dc.num_mcu_x * comp.sfx*8 * dc.num_mcu_y * comp.sfy*8;
            acc += csizes[i];
        }
        dc.compsbuf = new_buffer(acc, e);
        if (e) return e;
        acc = 0;
        foreach (i, ref comp; dc.comps[0..dc.num_comps]) {
            comp.data = dc.compsbuf[acc .. acc + csizes[i]];
            acc += csizes[i];
        }
    }
    scope(exit)
        _free(dc.compsbuf.ptr);

    // E.7 -- Multiple scans are for progressive images which are not supported
    //while (!dc.eoi_reached) {
        e = decode_scan(dc);    // E.2.3
        //read_markers(dc);   // reads until next scan header or eoi
    //}
    if (e) return e;

    // throw away fill samples and convert to target format
    ubyte[] buf = dc.reconstruct(e);
    if (e) return e;

    image.w   = dc.width;
    image.h   = dc.height;
    image.c   = cast(ubyte) dc.tchans;
    image.cinfile = dc.num_comps;
    image.bpc = tbpc;
    if (tbpc == 8) {
        image.buf8 = buf;
    } else {
        image.buf16 = bpc8to16(buf);
        if (!image.buf16.ptr)
            return ERROR.oom;
    }
    return 0;
}

ubyte read_markers(ref JPEGDecoder dc)
{
    bool has_next_scan_header = false;
    while (!has_next_scan_header && !dc.eoi_reached) {
        if (read_u8(dc.rc) != 0xff)
            return dc.rc.fail ? ERROR.stream : ERROR.data;

        ubyte marker = read_u8(dc.rc);
        while (marker == 0xff && !dc.rc.fail)
            marker = read_u8(dc.rc);

        if (dc.rc.fail)
            return ERROR.stream;

        ubyte e;
        switch (marker) with (MARKER) {
            case DHT:
                e = read_huffman_tables(dc);
                break;
            case DQT:
                e = read_quantization_tables(dc);
                break;
            case SOF0:
                if (dc.has_frame_header)
                    return ERROR.data;
                e = read_frame_header(dc);
                dc.has_frame_header = true;
                break;
            case SOS:
                if (!dc.has_frame_header)
                    return ERROR.data;
                e = read_scan_header(dc);
                has_next_scan_header = true;
                break;
            case DRI:
                if (read_u16be(dc.rc) != 4)  // len
                    return dc.rc.fail ? ERROR.stream : ERROR.unsupp;
                dc.restart_interval = read_u16be(dc.rc);
                break;
            case EOI:
                dc.eoi_reached = true;
                break;
            case APP0: .. case APPf:
            case COM:
                const int len = read_u16be(dc.rc) - 2;
                skip(dc.rc, len);
                break;
            default:
                return ERROR.unsupp;
        }
        if (e)
            return dc.rc.fail ? ERROR.stream : e;
    }
    return 0;
}

// DHT -- define huffman tables
ubyte read_huffman_tables(ref JPEGDecoder dc)
{
    ubyte[19] tmp;  // FIXME this could be just 17 bytes
    int len = read_u16be(dc.rc) - 2;
    if (dc.rc.fail) return ERROR.stream;

    ubyte e;
    while (len > 0) {
        read_block(dc.rc, tmp[0..17]);        // info byte & the BITS
        if (dc.rc.fail) return ERROR.stream;
        const ubyte tableslot  = tmp[0] & 0x0f; // must be 0 or 1 for baseline
        const ubyte tableclass = tmp[0] >> 4;   // 0 = dc table, 1 = ac table
        if (tableslot > 1 || tableclass > 1)
            return ERROR.unsupp;

        // compute total number of huffman codes
        int mt = 0;
        foreach (i; 1..17)
            mt += tmp[i];
        if (256 < mt)
            return ERROR.data;

        if (tableclass == 0) {
            read_block(dc.rc, dc.dc_tables[tableslot].values[0..mt]);
            derive_table(dc.dc_tables[tableslot], tmp[1..17], e);
        } else {
            read_block(dc.rc, dc.ac_tables[tableslot].values[0..mt]);
            derive_table(dc.ac_tables[tableslot], tmp[1..17], e);
        }

        len -= 17 + mt;
    }
    if (dc.rc.fail) return ERROR.stream;
    return e;
}

// num_values is the BITS
void derive_table(ref HuffTab table, in ref ubyte[16] num_values, ref ubyte e)
{
    short[256] codes;

    int k = 0;
    foreach (i; 0..16) {
        foreach (j; 0..num_values[i]) {
            if (k > table.sizes.length) {
                e = ERROR.data;
                return;
            }
            table.sizes[k] = cast(ubyte) (i + 1);
            ++k;
        }
    }
    table.sizes[k] = 0;

    k = 0;
    short code = 0;
    ubyte si = table.sizes[k];
    while (true) {
        do {
            codes[k] = code;
            ++code;
            ++k;
        } while (si == table.sizes[k]);

        if (table.sizes[k] == 0)
            break;

        assert(si < table.sizes[k]);
        do {
            code <<= 1;
            ++si;
        } while (si != table.sizes[k]);
    }

    derive_mincode_maxcode_valptr(
        table.mincode, table.maxcode, table.valptr,
        codes, num_values
    );
}

// F.15
void derive_mincode_maxcode_valptr(ref short[16] mincode, ref short[16] maxcode,
     ref short[16] valptr, in ref short[256] codes, in ref ubyte[16] num_values)
{
    mincode[] = -1;
    maxcode[] = -1;
    valptr[] = -1;

    int j = 0;
    foreach (i; 0..16) {
        if (num_values[i] != 0) {
            valptr[i] = cast(short) j;
            mincode[i] = codes[j];
            j += num_values[i] - 1;
            maxcode[i] = codes[j];
            j += 1;
        }
    }
}

// DQT -- define quantization tables
ubyte read_quantization_tables(ref JPEGDecoder dc)
{
    int len = read_u16be(dc.rc);
    if (len % 65 != 2)
        return dc.rc.fail ? ERROR.stream : ERROR.data;
    len -= 2;
    while (len > 0) {
        const ubyte info = read_u8(dc.rc);
        const ubyte tableslot = info & 0x0f;
        const ubyte precision = info >> 4;  // 0 = 8 bit, 1 = 16 bit
        if (tableslot > 3 || precision != 0) // only 8 bit for baseline
            return dc.rc.fail ? ERROR.stream : ERROR.unsupp;
        read_block(dc.rc, dc.qtables[tableslot][0..64]);
        len -= 1 + 64;
    }
    return dc.rc.fail ? ERROR.stream : 0;
}

// SOF0 -- start of frame
ubyte read_frame_header(ref JPEGDecoder dc)
{
    const int len = read_u16be(dc.rc);  // 8 + num_comps*3
    const ubyte precision = read_u8(dc.rc);
    dc.height = read_u16be(dc.rc);
    dc.width = read_u16be(dc.rc);
    dc.num_comps = read_u8(dc.rc);

    if ((dc.num_comps != 1 && dc.num_comps != 3)
     || precision != 8 || len != 8 + dc.num_comps*3)
        return ERROR.unsupp;

    dc.hmax = 0;
    dc.vmax = 0;
    int mcu_du = 0; // data units in one mcu
    ubyte[9] tmp;
    read_block(dc.rc, tmp[0..dc.num_comps*3]);
    if (dc.rc.fail) return ERROR.stream;
    foreach (i; 0..dc.num_comps) {
        ubyte ci = tmp[i*3];
        // JFIF says ci should be i+1, but there are images where ci is i. Normalize
        // ids so that ci == i, always. So much for standards...
        if (i == 0) { dc.correct_comp_ids = ci == i+1; }
        if ((dc.correct_comp_ids && ci != i+1)
        || (!dc.correct_comp_ids && ci != i))
            return ERROR.data;

        Component* comp = &dc.comps[i];
        const ubyte sampling_factors = tmp[i*3 + 1];
        comp.sfx = sampling_factors >> 4;
        comp.sfy = sampling_factors & 0xf;
        comp.qtable = tmp[i*3 + 2];
        if ( comp.sfy < 1 || 4 < comp.sfy ||
             comp.sfx < 1 || 4 < comp.sfx ||
             3 < comp.qtable )
            return ERROR.unsupp;

        if (dc.hmax < comp.sfx) dc.hmax = comp.sfx;
        if (dc.vmax < comp.sfy) dc.vmax = comp.sfy;

        mcu_du += comp.sfx * comp.sfy;
    }
    if (10 < mcu_du)
        return ERROR.unsupp;

    assert(dc.hmax * dc.vmax);
    foreach (i; 0..dc.num_comps) {
        dc.comps[i].x = cast(size_t) ceil(dc.width * (cast(double) dc.comps[i].sfx /
                    dc.hmax));
        dc.comps[i].y = cast(size_t) ceil(dc.height * (cast(double) dc.comps[i].sfy /
                    dc.vmax));
    }

    size_t mcu_w = dc.hmax * 8;
    size_t mcu_h = dc.vmax * 8;
    dc.num_mcu_x = cast(int) ((dc.width + mcu_w-1) / mcu_w);
    dc.num_mcu_y = cast(int) ((dc.height + mcu_h-1) / mcu_h);
    return 0;
}

// SOS -- start of scan
ubyte read_scan_header(ref JPEGDecoder dc)
{
    const ushort len = read_u16be(dc.rc);
    const ubyte num_scan_comps = read_u8(dc.rc);

    if ( num_scan_comps != dc.num_comps ||
         len != (6+num_scan_comps*2) )
        return dc.rc.fail ? ERROR.stream : ERROR.unsupp;

    ubyte[16] buf;
    ubyte e;
    read_block(dc.rc, buf[0..len-3]);
    if (dc.rc.fail) return ERROR.stream;

    foreach (i; 0..num_scan_comps) {
        const uint ci = buf[i*2] - (dc.correct_comp_ids ? 1 : 0);
        if (ci >= dc.num_comps)
            return ERROR.data;

        const ubyte tables = buf[i*2 + 1];
        dc.comps[ci].dc_table = tables >> 4;
        dc.comps[ci].ac_table = tables & 0x0f;
        if (dc.comps[ci].dc_table > 1 || dc.comps[ci].ac_table > 1)
            return ERROR.unsupp;
    }

    // ignore these
    //ubyte spectral_start = buf[$-3];
    //ubyte spectral_end = buf[$-2];
    //ubyte approx = buf[$-1];
    return 0;
}

// E.2.3 and E.8 and E.9
ubyte decode_scan(ref JPEGDecoder dc)
{
    int intervals, mcus;
    if (dc.restart_interval > 0) {
        int total_mcus = dc.num_mcu_x * dc.num_mcu_y;
        intervals = (total_mcus + dc.restart_interval-1) / dc.restart_interval;
        mcus = dc.restart_interval;
    } else {
        intervals = 1;
        mcus = dc.num_mcu_x * dc.num_mcu_y;
    }

    ubyte e;
    foreach (mcu_j; 0 .. dc.num_mcu_y) {
        foreach (mcu_i; 0 .. dc.num_mcu_x) {

            // decode mcu
            foreach (c; 0..dc.num_comps) {
                auto comp = &dc.comps[c];
                foreach (du_j; 0 .. comp.sfy) {
                    foreach (du_i; 0 .. comp.sfx) {
                        // decode entropy, dequantize & dezigzag
                        short[64] data;
                        e = decode_block(dc, *comp, dc.qtables[comp.qtable], data);
                        if (e) return e;
                        // idct & level-shift
                        int outx = (mcu_i * comp.sfx + du_i) * 8;
                        int outy = (mcu_j * comp.sfy + du_j) * 8;
                        int dst_stride = dc.num_mcu_x * comp.sfx*8;
                        ubyte* dst = comp.data.ptr + outy*dst_stride + outx;
                        stbi__idct_block(dst, dst_stride, data);
                    }
                }
            }

            --mcus;

            if (!mcus) {
                --intervals;
                if (!intervals)
                    return e;

                e = read_restart(dc.rc);    // RSTx marker

                if (intervals == 1) {
                    // last interval, may have fewer MCUs than defined by DRI
                    mcus = (dc.num_mcu_y - mcu_j - 1)
                         * dc.num_mcu_x + dc.num_mcu_x - mcu_i - 1;
                } else {
                    mcus = dc.restart_interval;
                }

                // reset decoder
                dc.cb = 0;
                dc.bits_left = 0;
                foreach (k; 0..dc.num_comps)
                    dc.comps[k].pred = 0;
            }

        }
    }
    return e;
}

// RST0-RST7
ubyte read_restart(Reader* rc) {
    ubyte a = read_u8(rc);
    ubyte b = read_u8(rc);
    if (rc.fail) return ERROR.stream;
    if (a != 0xff || b < MARKER.RST0 || b > MARKER.RST7)
        return ERROR.data;
    return 0;
    // the markers should cycle 0 through 7, could check that here...
}

immutable ubyte[64] dezigzag = [
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
];

// decode entropy, dequantize & dezigzag (see section F.2)
ubyte decode_block(ref JPEGDecoder dc, ref Component comp, in ref ubyte[64] qtable,
                                                              out short[64] result)
{
    result = 0; // FIXME delete
    ubyte e;
    const ubyte t = decode_huff(dc, dc.dc_tables[comp.dc_table], e);
    if (e) return e;
    const int diff = t ? dc.receive_and_extend(t, e) : 0;

    comp.pred = comp.pred + diff;
    result[0] = cast(short) (comp.pred * qtable[0]);

    int k = 1;
    do {
        ubyte rs = decode_huff(dc, dc.ac_tables[comp.ac_table], e);
        if (e) return e;
        ubyte rrrr = rs >> 4;
        ubyte ssss = rs & 0xf;

        if (ssss == 0) {
            if (rrrr != 0xf)
                break;      // end of block
            k += 16;    // run length is 16
            continue;
        }

        k += rrrr;

        if (63 < k)
            return ERROR.data;
        result[dezigzag[k]] = cast(short) (dc.receive_and_extend(ssss, e) * qtable[k]);
        k += 1;
    } while (k < 64);

    return 0;
}

int receive_and_extend(ref JPEGDecoder dc, in ubyte s, ref ubyte e)
{
    // receive
    int symbol = 0;
    foreach (_; 0..s)
        symbol = (symbol << 1) + nextbit(dc, e);
    // extend
    int vt = 1 << (s-1);
    if (symbol < vt)
        return symbol + (-1 << s) + 1;
    return symbol;
}

// F.16 -- the DECODE
ubyte decode_huff(ref JPEGDecoder dc, in ref HuffTab tab, ref ubyte e)
{
    short code = nextbit(dc, e);

    int i = 0;
    while (tab.maxcode[i] < code) {
        code = cast(short) ((code << 1) + nextbit(dc, e));
        i += 1;
        if (i >= tab.maxcode.length) {
            e = ERROR.data;
            return 0;
        }
    }
    const uint j = cast(uint) (tab.valptr[i] + code - tab.mincode[i]);
    if (j >= tab.values.length) {
        e = ERROR.data;
        return 0;
    }
    return tab.values[j];
}

// F.2.2.5 and F.18
ubyte nextbit(ref JPEGDecoder dc, ref ubyte e)
{
    if (!dc.bits_left) {
        dc.cb = read_u8(dc.rc);
        dc.bits_left = 8;

        if (dc.cb == 0xff) {
            if (read_u8(dc.rc) != 0x0) {
                e = dc.rc.fail ? ERROR.stream : ERROR.data; // unexpected marker
                return 0;
            }
        }
    }
    if (dc.rc.fail) e = ERROR.stream;   // TODO remove?

    ubyte r = dc.cb >> 7;
    dc.cb <<= 1;
    dc.bits_left -= 1;
    return r;
}

ubyte[] reconstruct(in ref JPEGDecoder dc, ref ubyte e)
{
    ubyte[] result = new_buffer(dc.width * dc.height * dc.tchans, e);
    if (e) return null;

    switch (dc.num_comps * 10 + dc.tchans) {
        case 34, 33:
            // Use specialized bilinear filtering functions for the frequent cases where
            // Cb & Cr channels have half resolution.
            if (dc.comps[0].sfx <= 2 && dc.comps[0].sfy <= 2 &&
                dc.comps[0].sfx + dc.comps[0].sfy >= 3       &&
                dc.comps[1].sfx == 1 && dc.comps[1].sfy == 1 &&
                dc.comps[2].sfx == 1 && dc.comps[2].sfy == 1)
            {
                void function(in ubyte[], in ubyte[], ubyte[]) nothrow resample;
                switch (dc.comps[0].sfx * 10 + dc.comps[0].sfy) {
                    case 22: resample = &upsample_h2_v2; break;
                    case 21: resample = &upsample_h2_v1; break;
                    case 12: resample = &upsample_h1_v2; break;
                    default: assert(0);
                }

                ubyte[] comps1n2 = new_buffer(dc.width * 2, e);
                if (e) return null;
                scope(exit) _free(comps1n2.ptr);
                ubyte[] comp1 = comps1n2[0..dc.width];
                ubyte[] comp2 = comps1n2[dc.width..$];

                size_t s = 0;
                size_t di = 0;
                foreach (j; 0 .. dc.height) {
                    const size_t mi = j / dc.comps[0].sfy;
                    const size_t si = (mi == 0 || mi >= (dc.height-1)/dc.comps[0].sfy)
                              ? mi : mi - 1 + s * 2;
                    s = s ^ 1;

                    const size_t cs = dc.num_mcu_x * dc.comps[1].sfx * 8;
                    const size_t cl0 = mi * cs;
                    const size_t cl1 = si * cs;
                    resample(dc.comps[1].data[cl0 .. cl0 + dc.comps[1].x],
                             dc.comps[1].data[cl1 .. cl1 + dc.comps[1].x],
                             comp1[]);
                    resample(dc.comps[2].data[cl0 .. cl0 + dc.comps[2].x],
                             dc.comps[2].data[cl1 .. cl1 + dc.comps[2].x],
                             comp2[]);

                    foreach (i; 0 .. dc.width) {
                        result[di .. di+3] = ycbcr_to_rgb(
                            dc.comps[0].data[j * dc.num_mcu_x * dc.comps[0].sfx * 8 + i],
                            comp1[i],
                            comp2[i],
                        );
                        if (dc.tchans == 4)
                            result[di+3] = 255;
                        di += dc.tchans;
                    }
                }

                return result;
            }

            foreach (const ref comp; dc.comps[0..dc.num_comps]) {
                if (comp.sfx != dc.hmax || comp.sfy != dc.vmax)
                    return dc.upsample(result);
            }

            size_t si, di;
            foreach (j; 0 .. dc.height) {
                foreach (i; 0 .. dc.width) {
                    result[di .. di+3] = ycbcr_to_rgb(
                        dc.comps[0].data[si+i],
                        dc.comps[1].data[si+i],
                        dc.comps[2].data[si+i],
                    );
                    if (dc.tchans == 4)
                        result[di+3] = 255;
                    di += dc.tchans;
                }
                si += dc.num_mcu_x * dc.comps[0].sfx * 8;
            }
            return result;
        case 32, 12, 31, 11:
            const comp = &dc.comps[0];
            if (comp.sfx == dc.hmax && comp.sfy == dc.vmax) {
                size_t si, di;
                if (dc.tchans == 2) {
                    foreach (j; 0 .. dc.height) {
                        foreach (i; 0 .. dc.width) {
                            result[di++] = comp.data[si+i];
                            result[di++] = 255;
                        }
                        si += dc.num_mcu_x * comp.sfx * 8;
                    }
                } else {
                    foreach (j; 0 .. dc.height) {
                        result[di .. di+dc.width] = comp.data[si .. si+dc.width];
                        si += dc.num_mcu_x * comp.sfx * 8;
                        di += dc.width;
                    }
                }
                return result;
            } else {
                // need to resample (haven't tested this...)
                return dc.upsample_luma(result);
            }
        case 14, 13:
            const comp = &dc.comps[0];
            size_t si, di;
            foreach (j; 0 .. dc.height) {
                foreach (i; 0 .. dc.width) {
                    result[di .. di+3] = comp.data[si+i];
                    if (dc.tchans == 4)
                        result[di+3] = 255;
                    di += dc.tchans;
                }
                si += dc.num_mcu_x * comp.sfx * 8;
            }
            return result;
        default:
            assert(0);
    }
}

void upsample_h2_v2(in ubyte[] line0, in ubyte[] line1, ubyte[] result)
{
    ubyte mix(ubyte mm, ubyte ms, ubyte sm, ubyte ss)
    {
        return cast(ubyte) (( cast(uint) mm * 3 * 3
                            + cast(uint) ms * 3 * 1
                            + cast(uint) sm * 1 * 3
                            + cast(uint) ss * 1 * 1
                            + 8) / 16);
    }

    result[0] = cast(ubyte) (( cast(uint) line0[0] * 3
                             + cast(uint) line1[0] * 1
                             + 2) / 4);
    if (line0.length == 1)
        return;
    result[1] = mix(line0[0], line0[1], line1[0], line1[1]);

    size_t di = 2;
    foreach (i; 1 .. line0.length) {
        result[di] = mix(line0[i], line0[i-1], line1[i], line1[i-1]);
        di += 1;
        if (i == line0.length-1) {
            if (di < result.length) {
                result[di] = cast(ubyte) (( cast(uint) line0[i] * 3
                                          + cast(uint) line1[i] * 1
                                          + 2) / 4);
            }
            return;
        }
        result[di] = mix(line0[i], line0[i+1], line1[i], line1[i+1]);
        di += 1;
    }
}

void upsample_h2_v1(in ubyte[] line0, in ubyte[] _line1, ubyte[] result)
{
    result[0] = line0[0];
    if (line0.length == 1)
        return;
    result[1] = cast(ubyte) (( cast(uint) line0[0] * 3
                             + cast(uint) line0[1] * 1
                             + 2) / 4);
    size_t di = 2;
    foreach (i; 1 .. line0.length) {
        result[di] = cast(ubyte) (( cast(uint) line0[i-1] * 1
                                  + cast(uint) line0[i+0] * 3
                                  + 2) / 4);
        di += 1;
        if (i == line0.length-1) {
            if (di < result.length) result[di] = line0[i];
            return;
        }
        result[di] = cast(ubyte) (( cast(uint) line0[i+0] * 3
                                  + cast(uint) line0[i+1] * 1
                                  + 2) / 4);
        di += 1;
    }
}

void upsample_h1_v2(in ubyte[] line0, in ubyte[] line1, ubyte[] result)
{
    foreach (i; 0 .. result.length) {
        result[i] = cast(ubyte) (( cast(uint) line0[i] * 3
                                 + cast(uint) line1[i] * 1
                                 + 2) / 4);
    }
}

// Nearest neighbor
ubyte[] upsample_luma(in ref JPEGDecoder dc, ubyte[] result)
{
    const size_t stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    const y_step0 = cast(float) dc.comps[0].sfy / cast(float) dc.vmax;
    const x_step0 = cast(float) dc.comps[0].sfx / cast(float) dc.hmax;

    float y0 = y_step0 * 0.5;
    size_t y0i = 0;

    size_t di;

    foreach (j; 0 .. dc.height) {
        float x0 = x_step0 * 0.5;
        size_t x0i = 0;
        foreach (i; 0 .. dc.width) {
            result[di] = dc.comps[0].data[y0i + x0i];
            if (dc.tchans == 2)
                result[di+1] = 255;
            di += dc.tchans;
            x0 += x_step0;
            if (x0 >= 1.0) {
                x0 -= 1.0;
                x0i += 1;
            }
        }
        y0 += y_step0;
        if (y0 >= 1.0) {
            y0 -= 1.0;
            y0i += stride0;
        }
    }
    return result;
}

// Nearest neighbor
ubyte[] upsample(in ref JPEGDecoder dc, ubyte[] result)
{
    const size_t stride0 = dc.num_mcu_x * dc.comps[0].sfx * 8;
    const size_t stride1 = dc.num_mcu_x * dc.comps[1].sfx * 8;
    const size_t stride2 = dc.num_mcu_x * dc.comps[2].sfx * 8;

    const y_step0 = cast(float) dc.comps[0].sfy / cast(float) dc.vmax;
    const y_step1 = cast(float) dc.comps[1].sfy / cast(float) dc.vmax;
    const y_step2 = cast(float) dc.comps[2].sfy / cast(float) dc.vmax;
    const x_step0 = cast(float) dc.comps[0].sfx / cast(float) dc.hmax;
    const x_step1 = cast(float) dc.comps[1].sfx / cast(float) dc.hmax;
    const x_step2 = cast(float) dc.comps[2].sfx / cast(float) dc.hmax;

    float y0 = y_step0 * 0.5;
    float y1 = y_step1 * 0.5;
    float y2 = y_step2 * 0.5;
    size_t y0i = 0;
    size_t y1i = 0;
    size_t y2i = 0;

    size_t di;

    foreach (_j; 0 .. dc.height) {
        float x0 = x_step0 * 0.5;
        float x1 = x_step1 * 0.5;
        float x2 = x_step2 * 0.5;
        size_t x0i = 0;
        size_t x1i = 0;
        size_t x2i = 0;
        foreach (i; 0 .. dc.width) {
            result[di .. di+3] = ycbcr_to_rgb(
                dc.comps[0].data[y0i + x0i],
                dc.comps[1].data[y1i + x1i],
                dc.comps[2].data[y2i + x2i],
            );
            if (dc.tchans == 4)
                result[di+3] = 255;
            di += dc.tchans;
            x0 += x_step0;
            x1 += x_step1;
            x2 += x_step2;
            if (x0 >= 1.0) { x0 -= 1.0; x0i += 1; }
            if (x1 >= 1.0) { x1 -= 1.0; x1i += 1; }
            if (x2 >= 1.0) { x2 -= 1.0; x2i += 1; }
        }
        y0 += y_step0;
        y1 += y_step1;
        y2 += y_step2;
        if (y0 >= 1.0) { y0 -= 1.0; y0i += stride0; }
        if (y1 >= 1.0) { y1 -= 1.0; y1i += stride1; }
        if (y2 >= 1.0) { y2 -= 1.0; y2i += stride2; }
    }
    return result;
}

ubyte[3] ycbcr_to_rgb(in ubyte y, in ubyte cb, in ubyte cr) pure {
    ubyte[3] rgb = void;
    rgb[0] = clamp(y + 1.402*(cr-128));
    rgb[1] = clamp(y - 0.34414*(cb-128) - 0.71414*(cr-128));
    rgb[2] = clamp(y + 1.772*(cb-128));
    return rgb;
}

ubyte clamp(in float x) pure {
    if (x < 0) return 0;
    if (255 < x) return 255;
    return cast(ubyte) x;
}

// ------------------------------------------------------------
// The IDCT stuff here (to the next dashed line) is copied and adapted from
// stb_image which is released under public domain.  Many thanks to stb_image
// author, Sean Barrett.
// Link: https://github.com/nothings/stb/blob/master/stb_image.h

pure int f2f(float x) { return cast(int) (x * 4096 + 0.5); }
pure int fsh(int x) { return x << 12; }

// from stb_image, derived from jidctint -- DCT_ISLOW
pure void STBI__IDCT_1D(ref int t0, ref int t1, ref int t2, ref int t3,
                        ref int x0, ref int x1, ref int x2, ref int x3,
        int s0, int s1, int s2, int s3, int s4, int s5, int s6, int s7)
{
   int p1,p2,p3,p4,p5;
   //int t0,t1,t2,t3,p1,p2,p3,p4,p5,x0,x1,x2,x3;
   p2 = s2;
   p3 = s6;
   p1 = (p2+p3) * f2f(0.5411961f);
   t2 = p1 + p3 * f2f(-1.847759065f);
   t3 = p1 + p2 * f2f( 0.765366865f);
   p2 = s0;
   p3 = s4;
   t0 = fsh(p2+p3);
   t1 = fsh(p2-p3);
   x0 = t0+t3;
   x3 = t0-t3;
   x1 = t1+t2;
   x2 = t1-t2;
   t0 = s7;
   t1 = s5;
   t2 = s3;
   t3 = s1;
   p3 = t0+t2;
   p4 = t1+t3;
   p1 = t0+t3;
   p2 = t1+t2;
   p5 = (p3+p4)*f2f( 1.175875602f);
   t0 = t0*f2f( 0.298631336f);
   t1 = t1*f2f( 2.053119869f);
   t2 = t2*f2f( 3.072711026f);
   t3 = t3*f2f( 1.501321110f);
   p1 = p5 + p1*f2f(-0.899976223f);
   p2 = p5 + p2*f2f(-2.562915447f);
   p3 = p3*f2f(-1.961570560f);
   p4 = p4*f2f(-0.390180644f);
   t3 += p1+p4;
   t2 += p2+p3;
   t1 += p2+p4;
   t0 += p1+p3;
}

// idct and level-shift
pure void stbi__idct_block(ubyte* dst, in int dst_stride, in ref short[64] data)
{
   int i;
   int[64] val;
   int* v = val.ptr;
   const(short)* d = data.ptr;

   // columns
   for (i=0; i < 8; ++i,++d, ++v) {
      // if all zeroes, shortcut -- this avoids dequantizing 0s and IDCTing
      if (d[ 8]==0 && d[16]==0 && d[24]==0 && d[32]==0
           && d[40]==0 && d[48]==0 && d[56]==0) {
         //    no shortcut                 0     seconds
         //    (1|2|3|4|5|6|7)==0          0     seconds
         //    all separate               -0.047 seconds
         //    1 && 2|3 && 4|5 && 6|7:    -0.047 seconds
         int dcterm = d[0] << 2;
         v[0] = v[8] = v[16] = v[24] = v[32] = v[40] = v[48] = v[56] = dcterm;
      } else {
         int t0,t1,t2,t3,x0,x1,x2,x3;
         STBI__IDCT_1D(
             t0, t1, t2, t3,
             x0, x1, x2, x3,
             d[ 0], d[ 8], d[16], d[24],
             d[32], d[40], d[48], d[56]
         );
         // constants scaled things up by 1<<12; let's bring them back
         // down, but keep 2 extra bits of precision
         x0 += 512; x1 += 512; x2 += 512; x3 += 512;
         v[ 0] = (x0+t3) >> 10;
         v[56] = (x0-t3) >> 10;
         v[ 8] = (x1+t2) >> 10;
         v[48] = (x1-t2) >> 10;
         v[16] = (x2+t1) >> 10;
         v[40] = (x2-t1) >> 10;
         v[24] = (x3+t0) >> 10;
         v[32] = (x3-t0) >> 10;
      }
   }

   ubyte* o = dst;
   for (i=0, v=val.ptr; i < 8; ++i,v+=8,o+=dst_stride) {
      // no fast case since the first 1D IDCT spread components out
      int t0,t1,t2,t3,x0,x1,x2,x3;
      STBI__IDCT_1D(
          t0, t1, t2, t3,
          x0, x1, x2, x3,
          v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7]
      );
      // constants scaled things up by 1<<12, plus we had 1<<2 from first
      // loop, plus horizontal and vertical each scale by sqrt(8) so together
      // we've got an extra 1<<3, so 1<<17 total we need to remove.
      // so we want to round that, which means adding 0.5 * 1<<17,
      // aka 65536. Also, we'll end up with -128 to 127 that we want
      // to encode as 0-255 by adding 128, so we'll add that before the shift
      x0 += 65536 + (128<<17);
      x1 += 65536 + (128<<17);
      x2 += 65536 + (128<<17);
      x3 += 65536 + (128<<17);
      // tried computing the shifts into temps, or'ing the temps to see
      // if any were out of range, but that was slower
      o[0] = stbi__clamp((x0+t3) >> 17);
      o[7] = stbi__clamp((x0-t3) >> 17);
      o[1] = stbi__clamp((x1+t2) >> 17);
      o[6] = stbi__clamp((x1-t2) >> 17);
      o[2] = stbi__clamp((x2+t1) >> 17);
      o[5] = stbi__clamp((x2-t1) >> 17);
      o[3] = stbi__clamp((x3+t0) >> 17);
      o[4] = stbi__clamp((x3-t0) >> 17);
   }
}

// clamp to 0-255
pure ubyte stbi__clamp(int x) {
   if (cast(uint) x > 255) {
      if (x < 0) return 0;
      if (x > 255) return 255;
   }
   return cast(ubyte) x;
}

// ------------------------------------------------------------
