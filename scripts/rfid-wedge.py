#!/usr/bin/env python3
"""kiosk RFID wedge: read cards on a USB PN532 NFC reader and type them.

Makes the PN532 behave like the barcode scanner: when a card is tapped it types
  <PREFIX><UID><Enter>
into whatever has focus (the dashboard), through a virtual keyboard (uinput),
so no dashboard or browser setup is needed.

Settings: /etc/kiosk-rfid.conf (KEY=value lines)
  PREFIX=RFID:     text typed before the card number ("" for none)
  FORMAT=hex       hex (uppercase, e.g. 04A1B2C3D4E5F6) or dec (UID as one
                   decimal number, most significant byte first)
  SUFFIX=enter     enter | tab | none
  REPEAT_SEC=3     the same card is typed again only after it has been away
                   this long (a card resting on the reader types once)
  PORT=auto        auto, or a fixed device such as /dev/ttyUSB0
Test without typing:  sudo /opt/kiosk/rfid-wedge.py --test
"""
import glob, os, sys, time

CONF = "/etc/kiosk-rfid.conf"
LOG = lambda *a: print(time.strftime("%F %T"), *a, flush=True)


def load_conf():
    c = {"PREFIX": "RFID:", "FORMAT": "hex", "SUFFIX": "enter",
         "REPEAT_SEC": "3", "PORT": "auto"}
    try:
        for line in open(CONF):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                c[k.strip().upper()] = v.strip().strip("'\"")
    except FileNotFoundError:
        pass
    return c


# ---------------------------------------------------------------- PN532 (HSU)
ACK = bytes([0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00])


def frame(cmd, data=b""):
    body = bytes([0xD4, cmd]) + bytes(data)
    ln = len(body)
    return (bytes([0x00, 0x00, 0xFF, ln, (-ln) & 0xFF]) + body
            + bytes([(-sum(body)) & 0xFF, 0x00]))


def parse_response(buf, cmd):
    """Return the data bytes of the D5 <cmd+1> response in buf, or None."""
    i = 0
    while True:
        i = buf.find(b"\x00\xff", i)
        if i < 0 or i + 4 > len(buf):
            return None
        ln, lcs = buf[i + 2], buf[i + 3]
        if ln == 0 and lcs == 0xFF:          # ACK frame
            i += 2
            continue
        if (ln + lcs) & 0xFF != 0 or i + 4 + ln + 1 > len(buf):
            i += 2
            continue
        body = buf[i + 4:i + 4 + ln]
        dcs = buf[i + 4 + ln]
        if (sum(body) + dcs) & 0xFF == 0 and len(body) >= 2 \
                and body[0] == 0xD5 and body[1] == cmd + 1:
            return bytes(body[2:])
        i += 2


class PN532:
    def __init__(self, port):
        import serial
        self.s = serial.Serial(port, 115200, timeout=0.05)
        self.port = port

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass

    def call(self, cmd, data=b"", wait=1.0):
        self.s.reset_input_buffer()
        # Wake-up preamble (HSU) then the command frame.
        self.s.write(b"\x55\x55" + b"\x00" * 14 + frame(cmd, data))
        buf, end = b"", time.time() + wait
        while time.time() < end:
            buf += self.s.read(64)
            r = parse_response(buf, cmd)
            if r is not None:
                return r
        return None

    def setup(self):
        fw = self.call(0x02)                         # GetFirmwareVersion
        if not fw or len(fw) < 4:
            return None
        self.call(0x14, b"\x01\x14\x01")             # SAMConfiguration: normal
        self.call(0x32, b"\x05\xff\x01\x02")         # few retries -> quick poll
        return "PN5%02x v%d.%d" % (fw[0], fw[1], fw[2])

    def read_uid(self):
        r = self.call(0x4A, b"\x01\x00", wait=0.6)  # InListPassiveTarget 106A
        if not r or r[0] < 1 or len(r) < 6:
            return None
        n = r[5]
        uid = r[6:6 + n]
        return uid if len(uid) == n and n > 0 else None


def find_reader(conf):
    ports = [conf["PORT"]] if conf["PORT"] != "auto" else sorted(
        set(glob.glob("/dev/ttyUSB*") + glob.glob("/dev/ttyACM*")))
    for p in ports:
        try:
            r = PN532(p)
            ver = r.setup()
            if ver:
                LOG("reader found on", p, ver)
                return r
            r.close()
        except Exception as e:
            LOG("skip", p, e)
    return None


# ------------------------------------------------------------- virtual keyboard
class Typer:
    def __init__(self):
        from evdev import UInput, ecodes as e
        self.e = e
        keys = [getattr(e, "KEY_%s" % k) for k in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"]
        keys += [e.KEY_ENTER, e.KEY_TAB, e.KEY_LEFTSHIFT, e.KEY_SEMICOLON,
                 e.KEY_MINUS, e.KEY_SPACE, e.KEY_DOT, e.KEY_SLASH]
        self.ui = UInput({e.EV_KEY: keys}, name="kiosk-rfid-wedge")
        time.sleep(1.0)  # let the desktop pick up the new keyboard

    def _tap(self, code, shift=False):
        e, ui = self.e, self.ui
        if shift:
            ui.write(e.EV_KEY, e.KEY_LEFTSHIFT, 1)
        ui.write(e.EV_KEY, code, 1); ui.syn()
        ui.write(e.EV_KEY, code, 0)
        if shift:
            ui.write(e.EV_KEY, e.KEY_LEFTSHIFT, 0)
        ui.syn()
        time.sleep(0.008)

    def type(self, text, suffix):
        e = self.e
        special = {":": (e.KEY_SEMICOLON, True), ";": (e.KEY_SEMICOLON, False),
                   "-": (e.KEY_MINUS, False), "_": (e.KEY_MINUS, True),
                   " ": (e.KEY_SPACE, False), ".": (e.KEY_DOT, False),
                   "/": (e.KEY_SLASH, False)}
        for ch in text:
            if ch.isdigit():
                self._tap(getattr(e, "KEY_" + ch))
            elif ch.isalpha() and ch.isascii():
                self._tap(getattr(e, "KEY_" + ch.upper()), shift=ch.isupper())
            elif ch in special:
                self._tap(*special[ch])
        if suffix == "enter":
            self._tap(e.KEY_ENTER)
        elif suffix == "tab":
            self._tap(e.KEY_TAB)


def fmt(uid, conf):
    if conf["FORMAT"].lower() == "dec":
        return str(int.from_bytes(uid, "big"))
    return uid.hex().upper()


def main():
    test = "--test" in sys.argv
    conf = load_conf()
    LOG("kiosk RFID wedge starting", "(test mode, nothing typed)" if test else "",
        "PREFIX=%r FORMAT=%s SUFFIX=%s" % (conf["PREFIX"], conf["FORMAT"], conf["SUFFIX"]))
    typer = None if test else Typer()
    reader, last_uid, last_seen = None, None, 0.0
    repeat = float(conf.get("REPEAT_SEC", "3") or 3)
    while True:
        if reader is None:
            reader = find_reader(conf)
            if reader is None:
                time.sleep(3)
                continue
        try:
            uid = reader.read_uid()
        except Exception as ex:            # unplugged or I/O error: rescan
            LOG("reader lost:", ex)
            reader.close(); reader = None
            continue
        now = time.time()
        if uid:
            if uid != last_uid or now - last_seen > repeat:
                text = conf["PREFIX"] + fmt(uid, conf)
                LOG("card", uid.hex().upper(), "->", text)
                if typer:
                    typer.type(text, conf["SUFFIX"].lower())
            last_uid, last_seen = uid, now
        time.sleep(0.15)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
