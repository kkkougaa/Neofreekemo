"""Lists the Objective-C classes of an arm64 Mach-O binary: superclass, ivars,
properties, class and instance methods with their type encodings, categories.

For reading X's own classes when a hook has to be written without guessing
(which method lays a row out, what a view's parts are called). Pure Python,
no dependencies.

    unzip the decrypted X IPA, then for each of
    Payload/Twitter.app/Frameworks/{T1Twitter,TwitterSPMMigration,TwitterAppSPMMigration}.framework/<name>:

    python docs/objc_class_dump.py <binary> <out.txt>
    grep -n "^@class TFNLayoutMetrics " out.txt
"""
import struct
import sys


class MachO:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        magic = struct.unpack_from("<I", d, 0)[0]
        self.base = 0
        if magic in (0xBEBAFECA, 0xBFBAFECA):  # fat (big endian header)
            n = struct.unpack_from(">I", d, 4)[0]
            for i in range(n):
                cpu, sub, off, size, align = struct.unpack_from(">IIIII", d, 8 + i * 20)
                if cpu == 0x0100000C:
                    self.base = off
        self.segs = []
        self.sects = {}
        ncmds = struct.unpack_from("<I", d, self.base + 16)[0]
        p = self.base + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", d, p)
            if cmd == 0x19:
                segname = d[p + 8:p + 24].rstrip(b"\0").decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", d, p + 24)
                nsects = struct.unpack_from("<I", d, p + 64)[0]
                self.segs.append((vmaddr, vmsize, fileoff, filesize))
                q = p + 72
                for _ in range(nsects):
                    sname = d[q:q + 16].rstrip(b"\0").decode()
                    addr, ssize = struct.unpack_from("<QQ", d, q + 32)
                    self.sects[(segname, sname)] = (addr, ssize)
                    q += 80
            p += size

    def off(self, vm):
        for vmaddr, vmsize, fileoff, filesize in self.segs:
            if vmaddr <= vm < vmaddr + vmsize:
                o = vm - vmaddr
                if o >= filesize:
                    return None
                return self.base + fileoff + o
        return None

    def u32(self, vm):
        o = self.off(vm)
        return struct.unpack_from("<I", self.data, o)[0] if o is not None else 0

    def i32(self, vm):
        o = self.off(vm)
        return struct.unpack_from("<i", self.data, o)[0] if o is not None else 0

    def ptr(self, vm):
        """Returns (target vm, is_bind)."""
        o = self.off(vm)
        if o is None:
            return 0, False
        raw = struct.unpack_from("<Q", self.data, o)[0]
        if raw >> 63:
            return 0, True
        return raw & 0xFFFFFFFFF, False

    def cstr(self, vm):
        o = self.off(vm)
        if o is None or vm == 0:
            return ""
        end = self.data.find(b"\0", o)
        return self.data[o:end].decode("utf-8", "replace")

    def methods(self, vm):
        out = []
        if not vm:
            return out
        ent = self.u32(vm)
        count = self.u32(vm + 4)
        relative = bool(ent & 0x80000000)
        direct_sel = bool(ent & 0x40000000)
        p = vm + 8
        for i in range(count):
            if relative:
                name_at = p + self.i32(p)
                if direct_sel:
                    name = self.cstr(name_at)
                else:
                    target, _ = self.ptr(name_at)
                    name = self.cstr(target)
                types = self.cstr(p + 4 + self.i32(p + 4))
                p += 12
            else:
                n, _ = self.ptr(p)
                t, _ = self.ptr(p + 8)
                name, types = self.cstr(n), self.cstr(t)
                p += 24
            out.append((name, types))
        return out

    def ivars(self, vm):
        out = []
        if not vm:
            return out
        count = self.u32(vm + 4)
        p = vm + 8
        for i in range(count):
            n, _ = self.ptr(p + 8)
            t, _ = self.ptr(p + 16)
            out.append((self.cstr(n), self.cstr(t)))
            p += 32
        return out

    def props(self, vm):
        out = []
        if not vm:
            return out
        count = self.u32(vm + 4)
        p = vm + 8
        for i in range(count):
            n, _ = self.ptr(p)
            a, _ = self.ptr(p + 8)
            out.append((self.cstr(n), self.cstr(a)))
            p += 16
        return out

    def class_ro(self, cls_vm):
        data, _ = self.ptr(cls_vm + 32)
        return data & ~7

    def class_name(self, cls_vm):
        if not cls_vm:
            return "?"
        ro = self.class_ro(cls_vm)
        n, _ = self.ptr(ro + 24)
        return self.cstr(n)

    def dump(self, out):
        for key in (("__DATA_CONST", "__objc_classlist"), ("__DATA", "__objc_classlist")):
            if key not in self.sects:
                continue
            addr, size = self.sects[key]
            for i in range(size // 8):
                cls, _ = self.ptr(addr + i * 8)
                if not cls:
                    continue
                ro = self.class_ro(cls)
                name = self.class_name(cls)
                sup, bind = self.ptr(cls + 8)
                supname = "(ext)" if bind or not sup else self.class_name(sup)
                out.write(f"@class {name} : {supname}\n")
                iv, _ = self.ptr(ro + 48)
                for n, t in self.ivars(iv):
                    out.write(f"  ivar {n} {t}\n")
                pr, _ = self.ptr(ro + 64)
                for n, a in self.props(pr):
                    out.write(f"  prop {n} {a}\n")
                meta, mbind = self.ptr(cls)
                if meta and not mbind:
                    mro = self.class_ro(meta)
                    ml, _ = self.ptr(mro + 32)
                    for n, t in self.methods(ml):
                        out.write(f"  + {n} {t}\n")
                ml, _ = self.ptr(ro + 32)
                for n, t in self.methods(ml):
                    out.write(f"  - {n} {t}\n")
        for key in (("__DATA_CONST", "__objc_catlist"), ("__DATA", "__objc_catlist")):
            if key not in self.sects:
                continue
            addr, size = self.sects[key]
            for i in range(size // 8):
                cat, _ = self.ptr(addr + i * 8)
                if not cat:
                    continue
                n, _ = self.ptr(cat)
                cls, bind = self.ptr(cat + 8)
                clsname = "(ext)" if bind or not cls else self.class_name(cls)
                out.write(f"@category {clsname} ({self.cstr(n)})\n")
                im, _ = self.ptr(cat + 16)
                cm, _ = self.ptr(cat + 24)
                for nn, t in self.methods(cm):
                    out.write(f"  + {nn} {t}\n")
                for nn, t in self.methods(im):
                    out.write(f"  - {nn} {t}\n")


if __name__ == "__main__":
    m = MachO(sys.argv[1])
    with open(sys.argv[2], "w", encoding="utf-8") as out:
        m.dump(out)
