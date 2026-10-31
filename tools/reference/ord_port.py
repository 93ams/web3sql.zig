"""Port of ord's published rules: RawEnvelope::from_tapscript (src/inscriptions/envelope.rs),
Runestone::payload and integers (crates/ordinals/src/runestone.rs) and varint::decode. A port shares
its author's reading of the source, so this is weaker than running ord itself.
"""

OP_0, OP_IF, OP_ENDIF, OP_RETURN, OP_13 = 0x00, 0x63, 0x68, 0x6a, 0x5d


def instructions(s):
    """rust-bitcoin's non-minimal iterator: yields ('push', bytes) or ('op', n); ('err',) ends it."""
    i = 0
    while i < len(s):
        op = s[i]
        i += 1
        if op <= 0x4b:
            n = op
        elif op <= 0x4e:
            w = {0x4c: 1, 0x4d: 2, 0x4e: 4}[op]
            if i + w > len(s):
                yield ("err",)
                return
            n = int.from_bytes(s[i:i + w], "little")
            i += w
        else:
            yield ("op", op)
            continue
        if i + n > len(s):
            yield ("err",)
            return
        yield ("push", bytes(s[i:i + n]))
        i += n


class ScriptError(Exception):
    pass


class Peek:
    def __init__(self, s):
        self.it = instructions(s)
        self.buf = None

    def peek(self):
        if self.buf is None:
            self.buf = next(self.it, ("end",))
        return self.buf

    def next(self):
        x = self.peek()
        self.buf = None
        if x[0] == "err":
            raise ScriptError
        return None if x[0] == "end" else x


def from_instructions(ins):
    if ins.peek() != ("op", OP_IF):
        return None
    ins.next()
    if ins.peek() != ("push", b"ord"):
        return None
    ins.next()
    payload = []
    while True:
        x = ins.next()
        if x is None:
            return None
        if x == ("op", OP_ENDIF):
            return payload
        if x[0] == "push":
            payload.append(x[1])
        elif x[1] == 0x4f:
            payload.append(b"\x81")
        elif 0x51 <= x[1] <= 0x60:
            payload.append(bytes([x[1] - 0x50]))
        else:
            return None


def ord_inscription(s):
    """(content_type or None, body) of the first envelope, or None."""
    ins = Peek(s)
    found = []
    try:
        while (x := ins.next()) is not None:
            if x == ("push", b""):
                e = from_instructions(ins)
                if e is not None:
                    found.append(e)
    except ScriptError:
        return None
    if not found:
        return None
    payload = found[0]
    body = next((i for i, p in enumerate(payload) if i % 2 == 0 and not p), None)
    ct = None
    head = payload[:len(payload) if body is None else body]
    for i in range(0, len(head) - 1, 2):
        if head[i] == b"\x01" and ct is None:
            ct = head[i + 1]
    return ct, b"".join(payload[body + 1:]) if body is not None else b""


def varint(b, i):
    n = 0
    for k in range(len(b) - i):
        if k > 18:
            raise ValueError("overlong")
        byte = b[i + k]
        v = byte & 0x7f
        if k == 18 and v & 0x7c:
            raise ValueError("overflow")
        n |= v << (7 * k)
        if not byte & 0x80:
            return n, k + 1
    raise ValueError("unterminated")


def ord_runestone(s):
    """None if no runestone, 'flaw' if ord flags it before semantics, else its integer list."""
    it = instructions(s)
    if next(it, None) != ("op", OP_RETURN) or next(it, None) != ("op", OP_13):
        return None
    payload = bytearray()
    for x in it:
        if x[0] != "push":
            return "flaw"
        payload += x[1]
    ints, i = [], 0
    try:
        while i < len(payload):
            v, n = varint(payload, i)
            ints.append(v)
            i += n
    except ValueError:
        return "flaw"
    # ord flags a tag with no value as TruncatedField; we report it as a NULL row.
    i = 0
    while i < len(ints):
        if ints[i] == 0:
            return ints
        if i + 1 >= len(ints):
            return "flaw"
        i += 2
    return ints
