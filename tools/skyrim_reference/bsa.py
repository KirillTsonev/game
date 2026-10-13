# Reads a Skyrim SE archive (BSA v105) without changing it: lists paths, extracts some.
import struct, sys, os

def lz4_block(src, out, dict_start=0):
    i = 0
    n = len(src)
    while i < n:
        token = src[i]; i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = src[i]; i += 1; lit += b
                if b != 255: break
        out += src[i:i + lit]; i += lit
        if i >= n: break
        offset = src[i] | (src[i + 1] << 8); i += 2
        match = token & 15
        if match == 15:
            while True:
                b = src[i]; i += 1; match += b
                if b != 255: break
        match += 4
        start = len(out) - offset
        for k in range(match):
            out.append(out[start + k])
    return out

def lz4_frame(data):
    assert data[:4] == b"\x04\x22\x4d\x18", data[:4]
    flg = data[4]
    i = 6
    if flg & 0x08: i += 8      # content size
    if flg & 0x01: i += 4      # dictionary id
    i += 1                     # header checksum
    out = bytearray()
    while True:
        size, = struct.unpack_from("<I", data, i); i += 4
        if size == 0: break
        raw = size & 0x80000000
        size &= 0x7fffffff
        block = data[i:i + size]; i += size
        if raw: out += block
        else: lz4_block(block, out)
        if flg & 0x10: i += 4  # block checksum
    return bytes(out)

def read(path, wanted, out_dir):
    f = open(path, "rb")
    magic, version, offset, flags, folders, files, folder_names, file_names, file_flags, pad = struct.unpack("<4sIIIIIIIHH", f.read(36))
    assert magic == b"BSA\0" and version == 105, (magic, version)
    recs = [struct.unpack("<QIIQ", f.read(24)) for _ in range(folders)]
    entries = []
    for h, count, _p, off in recs:
        n = f.read(1)[0]
        name = f.read(n)[:-1].decode("latin1")
        for _ in range(count):
            fh, size, foff = struct.unpack("<QII", f.read(16))
            entries.append([name, size, foff])
    names = f.read(file_names).split(b"\0")
    found = 0
    for e, n in zip(entries, names):
        full = (e[0] + "\\" + n.decode("latin1")).lower()
        if not any(w in full for w in wanted):
            continue
        found += 1
        size = e[1]
        compressed = bool(flags & 4) != bool(size & 0x40000000)
        size &= 0x3fffffff
        f.seek(e[2])
        data = f.read(size)
        if flags & 0x100:
            n1 = data[0]; data = data[1 + n1:]
        if compressed:
            original, = struct.unpack_from("<I", data, 0)
            data = lz4_frame(data[4:])
            assert len(data) == original, (len(data), original)
        if out_dir:
            dst = os.path.join(out_dir, full.replace("\\", "__"))
            open(dst, "wb").write(data)
        print("%8d  %s" % (len(data), full))
    return found

if __name__ == "__main__":
    read(sys.argv[1], [w.lower() for w in sys.argv[3:]], sys.argv[2] if sys.argv[2] != "-" else None)
