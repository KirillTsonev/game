# Reads Skyrim SE Havok packfiles (hk_2010.2.0-r1, 64-bit): a skeleton, and a spline-compressed
# animation sampled per frame. Written from the publicly described layout; checked against the
# skeleton's own rest pose (look.py).
import struct, math


class Pack:
    def __init__(self, path):
        b = open(path, "rb").read()
        self.b = b
        assert b[0x10] == 8 and b[0x11] == 1, "not 64-bit little-endian"
        nsec, = struct.unpack_from("<i", b, 0x14)
        self.sections = []
        for i in range(nsec):
            o = 0x40 + i * 0x30
            tag = b[o:o + 19].split(b"\0")[0].decode()
            vals = struct.unpack_from("<7I", b, o + 20)
            self.sections.append((tag, vals))
        names = dict((t, v) for t, v in self.sections)
        self.cls_abs = names["__classnames__"][0]
        self.abs, loc, glob, virt, exp, imp, end = names["__data__"]
        self.fix = {}
        for o in range(self.abs + loc, self.abs + glob - 7, 8):
            s, d = struct.unpack_from("<II", b, o)
            if s != 0xFFFFFFFF:
                self.fix[s] = d
        for o in range(self.abs + glob, self.abs + virt - 11, 12):
            s, sec, d = struct.unpack_from("<III", b, o)
            if s != 0xFFFFFFFF:
                self.fix[s] = d
        self.objects = []
        for o in range(self.abs + virt, self.abs + exp - 11, 12):
            s, sec, d = struct.unpack_from("<III", b, o)
            if s != 0xFFFFFFFF:
                self.objects.append((self.cstr_abs(self.cls_abs + d), s))

    def cstr_abs(self, o):
        return self.b[o:self.b.index(b"\0", o)].decode("latin1")

    def u(self, fmt, o):
        return struct.unpack_from("<" + fmt, self.b, self.abs + o)

    def ptr(self, o):
        return self.fix.get(o)

    def string(self, o):
        p = self.ptr(o)
        return None if p is None else self.cstr_abs(self.abs + p)

    def array(self, o):
        return self.ptr(o), self.u("I", o + 8)[0]

    def find(self, cls):
        return [o for c, o in self.objects if c == cls]


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz)


def qrot(q, v):
    x, y, z, w = q
    vx, vy, vz = v
    tx = 2 * (y * vz - z * vy)
    ty = 2 * (z * vx - x * vz)
    tz = 2 * (x * vy - y * vx)
    return (vx + w * tx + (y * tz - z * ty), vy + w * ty + (z * tx - x * tz), vz + w * tz + (x * ty - y * tx))


def qnorm(q):
    n = math.sqrt(sum(c * c for c in q)) or 1.0
    return tuple(c / n for c in q)


class Skeleton:
    def __init__(self, path):
        p = Pack(path)
        o = p.find("hkaSkeleton")[0]
        self.name = p.string(o + 16)
        pa, pn = p.array(o + 24)
        ba, bn = p.array(o + 40)
        ra, rn = p.array(o + 56)
        self.parents = list(p.u("%dh" % pn, pa))
        self.bones = [p.string(ba + 16 * i) for i in range(bn)]
        self.rest = []
        for i in range(rn):
            v = p.u("12f", ra + 48 * i)
            self.rest.append(((v[0], v[1], v[2]), (v[4], v[5], v[6], v[7]), (v[8], v[9], v[10])))

    def index(self, part):
        hits = [i for i, n in enumerate(self.bones) if part.lower() in n.lower()]
        assert len(hits) == 1, (part, [self.bones[i] for i in hits])
        return hits[0]

    def world(self, local):
        """local: per bone (t, q, s) -> per bone (position, rotation) in the model's space (scale ignored)."""
        out = [None] * len(self.bones)
        for i, (t, q, s) in enumerate(local):
            pi = self.parents[i]
            if pi < 0:
                out[i] = (t, qnorm(q))
            else:
                pt, pq = out[pi]
                r = qrot(pq, t)
                out[i] = ((pt[0] + r[0], pt[1] + r[1], pt[2] + r[2]), qnorm(qmul(pq, q)))
        return out


def find_span(n, degree, t, knots):
    if t >= knots[n + 1]:
        return n
    low, high = degree, n + 1
    mid = (low + high) // 2
    while t < knots[mid] or t >= knots[mid + 1]:
        if t < knots[mid]:
            high = mid
        else:
            low = mid
        mid = (low + high) // 2
    return mid


def nurbs(knots, points, degree, t):
    n = len(points) - 1
    if n == 0:
        return points[0]
    span = find_span(n, degree, t, knots)
    N = [0.0] * (degree + 1)
    N[0] = 1.0
    for i in range(1, degree + 1):
        for j in range(i - 1, -1, -1):
            denom = knots[span + i - j] - knots[span - j]
            A = (t - knots[span - j]) / denom if denom else 0.0
            tmp = N[j] * A
            N[j + 1] += N[j] - tmp
            N[j] = tmp
    dim = len(points[0])
    out = [0.0] * dim
    for i in range(degree + 1):
        pt = points[span - i]
        for d in range(dim):
            out[d] += pt[d] * N[i]
    return tuple(out)


def quat40(b, o):
    v = int.from_bytes(b[o:o + 5], "little")
    mask = 0xfff
    half = mask >> 1
    fractal = 0.000345436
    c = [(((v >> s) & mask) - half) * fractal for s in (0, 12, 24)]
    shift = (v >> 36) & 3
    w = math.sqrt(max(0.0, 1.0 - sum(x * x for x in c)))
    if (v >> 38) & 1:
        w = -w
    c.insert(shift, w)
    return tuple(c)


def quat48(b, o):
    x, y, z = struct.unpack_from("<3H", b, o)
    mask = 0x7fff
    half = mask >> 1
    fractal = 0.000043161
    shift = ((y >> 14) & 2) | ((x >> 15) & 1)
    c = [((x & mask) - half) * fractal, ((y & mask) - half) * fractal, ((z & mask) - half) * fractal]
    w = math.sqrt(max(0.0, 1.0 - sum(v * v for v in c)))
    if z >> 15:
        w = -w
    c.insert(shift, w)
    return tuple(c)


class Animation:
    def __init__(self, path):
        p = Pack(path)
        self.p = p
        o = p.find("hkaSplineCompressedAnimation")[0]
        self.duration, self.ntracks, self.nfloat = p.u("fii", o + 20)
        self.frames, self.blocks, self.max_per_block, self.mask_size = p.u("4i", o + 56)
        self.block_duration, self.block_inv, self.frame_duration = p.u("3f", o + 72)
        ba, bn = p.array(o + 88)
        self.block_offsets = list(p.u("%dI" % bn, ba))
        self.data, self.data_size = p.array(o + 152)
        self.buf = p.b[p.abs + self.data:p.abs + self.data + self.data_size]
        aa, an = p.array(o + 40)
        self.events = []
        for i in range(an):
            ea, en = p.array(aa + 24 * i + 8)
            for k in range(en):
                self.events.append((round(p.u("f", ea + 16 * k)[0], 3), p.string(ea + 16 * k + 8)))
        self.events.sort()
        b = p.find("hkaAnimationBinding")
        self.track_bones = None
        self.skeleton_name = None
        if b:
            self.skeleton_name = p.string(b[0] + 16)
            ta, tn = p.array(b[0] + 32)
            if tn:
                self.track_bones = list(p.u("%dh" % tn, ta))
        self._blocks = {}

    def _vec(self, o, types, quant, default):
        """A position or scale sub-track: a static value, or (knots, degree, points). And the new offset."""
        b = self.buf
        dyn = [(types >> (4 + i)) & 1 for i in range(3)]
        sta = [(types >> i) & 1 for i in range(3)]
        if any(dyn):
            items, degree = struct.unpack_from("<HB", b, o)
            o += 3
            knots = list(b[o:o + items + degree + 2])
            o += items + degree + 2
            o = (o + 3) & ~3
            lo = [default] * 3
            hi = [default] * 3
            for i in range(3):
                if dyn[i]:
                    lo[i], hi[i] = struct.unpack_from("<2f", b, o)
                    o += 8
                elif sta[i]:
                    lo[i], = struct.unpack_from("<f", b, o)
                    hi[i] = lo[i]
                    o += 4
            pts = []
            for k in range(items + 1):
                pt = list(lo)
                for i in range(3):
                    if dyn[i]:
                        if quant == 0:
                            q = b[o] / 255.0
                            o += 1
                        else:
                            q = struct.unpack_from("<H", b, o)[0] / 65535.0
                            o += 2
                        pt[i] = lo[i] + (hi[i] - lo[i]) * q
                pts.append(tuple(pt))
            return ("spline", knots, degree, pts), (o + 3) & ~3
        val = [default] * 3
        for i in range(3):
            if sta[i]:
                val[i], = struct.unpack_from("<f", b, o)
                o += 4
        return ("static", tuple(val)), (o + 3) & ~3

    def _rot(self, o, types, quant):
        b = self.buf
        size, read, align = {3: (5, quat40, 1), 4: (6, quat48, 2)}[quant]
        if types & 0xf0:
            items, degree = struct.unpack_from("<HB", b, o)
            o += 3
            knots = list(b[o:o + items + degree + 2])
            o += items + degree + 2
            o = (o + align - 1) & ~(align - 1)
            pts = []
            for k in range(items + 1):
                pts.append(read(b, o))
                o += size
            return ("spline", knots, degree, pts), (o + 3) & ~3
        if types & 0x0f:
            q = read(b, o)
            o += size
            return ("static", q), (o + 3) & ~3
        return ("static", (0.0, 0.0, 0.0, 1.0)), (o + 3) & ~3

    def block(self, index):
        if index in self._blocks:
            return self._blocks[index]
        b = self.buf
        o = self.block_offsets[index]
        masks = [b[o + 4 * i:o + 4 * i + 4] for i in range(self.ntracks)]
        o += 4 * self.ntracks + self.nfloat
        o = (o + 3) & ~3
        tracks = []
        for m in masks:
            pos, o = self._vec(o, m[1], m[0] & 3, 0.0)
            rot, o = self._rot(o, m[2], ((m[0] >> 2) & 0xf) + 2)
            scl, o = self._vec(o, m[3], (m[0] >> 6) & 3, 1.0)
            tracks.append((pos, rot, scl))
        self._blocks[index] = (tracks, o)
        return self._blocks[index]

    @staticmethod
    def _at(sub, local, quat=False):
        if sub[0] == "static":
            return sub[1]
        v = nurbs(sub[1], sub[3], sub[2], local)
        return qnorm(v) if quat else v

    def sample(self, frame):
        """Per track (t, q, s) at a frame (may be fractional)."""
        frame = min(max(frame, 0.0), self.frames - 1)
        per = self.max_per_block - 1
        index = min(int(frame // per), self.blocks - 1)
        local = frame - index * per
        return [(self._at(pos, local), self._at(rot, local, True), self._at(scl, local)) for pos, rot, scl in self.block(index)[0]]

    def pose(self, skeleton, frame):
        """The skeleton's local pose at a frame: rest where the clip has no track."""
        local = list(skeleton.rest)
        for i, tr in enumerate(self.sample(frame)):
            bone = self.track_bones[i] if self.track_bones else i
            if 0 <= bone < len(local):
                local[bone] = tr
        return local
