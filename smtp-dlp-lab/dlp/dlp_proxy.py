#!/usr/bin/env python3
"""DLP engine for the SMTP DLP lab: a before-queue SMTP proxy for Postfix.

  client -> Postfix :25 --smtpd_proxy_filter--> this proxy 127.0.0.1:10024
              clean     -> relayed to Postfix 127.0.0.1:10025 (no filter) -> queue -> Mailpit
              violation -> "550 5.7.1" back through Postfix to the client, original saved
                           to the quarantine dir, notices sent to the sender and the auditor

Because the verdict is given before Postfix queues the message, a blocked mail is
never accepted (the sender's client sees the 550), like an inline DLP gateway.
Stdlib only, so it runs on the stock python:alpine image.
"""
import asyncio
import datetime
import io
import json
import os
import re
import smtplib
import sys
import unicodedata
import uuid
import zipfile
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser

LISTEN = (os.environ.get("LISTEN_HOST", "127.0.0.1"), int(os.environ.get("LISTEN_PORT", "10024")))
NEXT_HOP = (os.environ.get("NEXT_HOP_HOST", "127.0.0.1"), int(os.environ.get("NEXT_HOP_PORT", "10025")))
POLICY_FILE = os.environ.get("POLICY_FILE", "/opt/dlp/policy.json")
QUARANTINE_DIR = os.environ.get("QUARANTINE_DIR", "/quarantine")
HOSTNAME = os.environ.get("DLP_HOSTNAME", "dlp.corp.lab")
MAX_MESSAGE = 25 * 1024 * 1024
MAX_MEMBER = 10 * 1024 * 1024   # larger archive members are reported as unscannable
MAX_DEPTH = 3                   # nested archives deeper than this are unscannable
IDLE_TIMEOUT = 300

TEXT_EXTENSIONS = {".txt", ".csv", ".tsv", ".json", ".xml", ".html", ".htm", ".md", ".log", ".eml"}


def log(**fields):
    fields["ts"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    print(json.dumps(fields, ensure_ascii=False), flush=True)


# ---------------------------------------------------------------- extraction

class Content:
    """Everything the detectors look at, each piece tagged with where it came from."""

    def __init__(self):
        self.texts = []        # (where, text)
        self.files = []        # (where, filename)
        self.unscannable = []  # (where, reason)


def decode_bytes(data):
    for enc in ("utf-8", "cp932", "euc-jp"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            pass
    return data.decode("latin-1")


def looks_like_text(data):
    head = data[:4096]
    return b"\x00" not in head and all(b >= 0x09 for b in head if b < 0x20 and b not in (0x0a, 0x0d))


def strip_html(text):
    return re.sub(r"<[^>]+>", " ", text)


def scan_file(name, data, where, content, depth):
    ext = os.path.splitext(name.lower())[1]
    if data[:4] == b"PK\x03\x04":
        # .zip, and also .docx/.xlsx/.pptx, whose text lives in XML members
        if depth >= MAX_DEPTH:
            content.unscannable.append((where, "nested too deep"))
            return
        try:
            archive = zipfile.ZipFile(io.BytesIO(data))
        except zipfile.BadZipFile:
            content.unscannable.append((where, "broken archive"))
            return
        for info in archive.infolist():
            if info.is_dir():
                continue
            inner = f"{where} > {info.filename}"
            content.files.append((inner, info.filename))
            if info.flag_bits & 0x1:
                content.unscannable.append((inner, "password protected"))
            elif info.file_size > MAX_MEMBER:
                content.unscannable.append((inner, "too large"))
            else:
                scan_file(info.filename, archive.read(info), inner, content, depth + 1)
    elif ext in TEXT_EXTENSIONS or looks_like_text(data):
        text = decode_bytes(data)
        content.texts.append((where, strip_html(text) if ext in (".html", ".htm", ".xml") else text))


def extract(msg):
    content = Content()
    content.texts.append(("件名", str(msg.get("Subject", ""))))
    for part in msg.walk():
        if part.is_multipart():
            continue
        filename = part.get_filename()
        if filename:
            where = f"添付 {filename}"
            content.files.append((where, filename))
            scan_file(filename, part.get_payload(decode=True) or b"", where, content, 0)
        elif part.get_content_maintype() == "text":
            try:
                text = part.get_content()
            except (LookupError, UnicodeError):
                text = decode_bytes(part.get_payload(decode=True) or b"")
            content.texts.append(("本文", strip_html(text) if part.get_content_subtype() == "html" else text))
    return content


# ----------------------------------------------------------------- detectors

CARD_PATTERNS = [
    re.compile(r"(?<!\d)\d{4}([ -])\d{4}\1\d{4}\1\d{4}(?!\d)"),  # 4111 1111 1111 1111
    re.compile(r"(?<!\d)\d{4}([ -])\d{6}\1\d{5}(?!\d)"),         # Amex 3782 822463 10005
    re.compile(r"(?<!\d)\d{13,19}(?!\d)"),                       # 4111111111111111
]


def luhn_ok(digits):
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def find_cards(text):
    found = []
    for pattern in CARD_PATTERNS:
        for m in pattern.finditer(text):
            digits = re.sub(r"\D", "", m.group(0))
            # issuer prefix (Amex/Visa/Master/JCB/Discover...) + checksum, to cut false positives
            if 13 <= len(digits) <= 19 and digits[0] in "3456" and luhn_ok(digits) and digits not in found:
                found.append(digits)
    return [f"****{d[-4:]}" for d in found]


def find_keywords(text, keywords):
    lowered = text.casefold()
    hits = []
    for kw in keywords:
        hits += [kw] * lowered.count(unicodedata.normalize("NFKC", kw).casefold())
    return hits


def evaluate(content, rules):
    """Return the rules that fired, with masked samples and where they matched."""
    # NFKC folds full-width digits/letters (４１１１, ＣＯＮＦＩＤＥＮＴＩＡＬ) into ASCII first
    texts = [(where, unicodedata.normalize("NFKC", text)) for where, text in content.texts]
    violations = []
    for rule in rules:
        hits = []  # (where, sample)
        kind = rule["type"]
        if kind == "credit_card":
            hits = [(w, s) for w, t in texts for s in find_cards(t)]
        elif kind == "keyword":
            hits = [(w, s) for w, t in texts for s in find_keywords(t, rule["keywords"])]
        elif kind == "file_type":
            exts = tuple(e.lower() for e in rule["extensions"])
            hits = [(w, name) for w, name in content.files if name.lower().endswith(exts)]
        elif kind == "unscannable":
            hits = list(content.unscannable)
        if hits and len(hits) >= rule.get("min_matches", 1):
            violations.append({
                "rule": rule["name"],
                "action": rule.get("action", "block"),
                "count": len(hits),
                "samples": sorted({s for _, s in hits})[:5],
                "where": sorted({w for w, _ in hits}),
            })
    return violations


# -------------------------------------------------------------------- actions

def relay(mail_from, rcpts, data, mail_options):
    """Hand the message to Postfix's unfiltered listener; return its reply for our client."""
    with smtplib.SMTP(*NEXT_HOP, timeout=60) as smtp:
        smtp.ehlo(HOSTNAME)
        code, resp = smtp.mail(mail_from, mail_options)
        if code != 250:
            return f"{code} {resp.decode()}"
        accepted = 0
        for rcpt in rcpts:
            code, resp = smtp.rcpt(rcpt)
            if code in (250, 251):
                accepted += 1
            elif code >= 500 and len(rcpts) == 1:
                return f"{code} {resp.decode()}"
        if not accepted:
            return "451 4.3.0 next hop refused all recipients"
        code, resp = smtp.data(data)
        return f"{code} {resp.decode()}"


def send_notice(to, subject, body, attachment=None, attachment_name=None):
    msg = EmailMessage()
    msg["From"] = POLICY["notify"]["from"]
    msg["To"] = to
    msg["Subject"] = subject
    msg["Auto-Submitted"] = "auto-generated"
    msg.set_content(body)
    if attachment is not None:
        msg.add_attachment(attachment, maintype="application", subtype="octet-stream",
                           filename=attachment_name)
    with smtplib.SMTP(*NEXT_HOP, timeout=60) as smtp:
        smtp.send_message(msg)


def describe(violations):
    lines = []
    for v in violations:
        lines.append(f"- ルール: {v['rule']} (動作: {v['action']}, 一致 {v['count']} 件)")
        lines.append(f"  一致した値: {', '.join(v['samples'])}")
        lines.append(f"  場所: {', '.join(v['where'])}")
    return "\n".join(lines)


def handle(mail_from, rcpts, data, mail_options):
    """Inspect one message and return the SMTP reply line for the end of DATA."""
    msg = BytesParser(policy=policy.default).parsebytes(data)
    subject = str(msg.get("Subject", ""))
    violations = evaluate(extract(msg), POLICY["rules"])
    blocking = [v for v in violations if v["action"] == "block"]
    incident = None
    if violations:
        incident = f"DLP-{datetime.datetime.now():%Y%m%d-%H%M%S}-{uuid.uuid4().hex[:6]}"

    if blocking:
        os.makedirs(QUARANTINE_DIR, exist_ok=True)
        with open(os.path.join(QUARANTINE_DIR, f"{incident}.eml"), "wb") as f:
            f.write(data)
        meta = {"incident": incident, "from": mail_from, "rcpts": rcpts, "subject": subject,
                "violations": violations}
        with open(os.path.join(QUARANTINE_DIR, f"{incident}.json"), "w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)
        log(event="block", incident=incident, sender=mail_from, rcpts=rcpts, subject=subject,
            rules=[v["rule"] for v in violations])
        notify(incident, mail_from, rcpts, subject, violations, data, blocked=True)
        rules = ",".join(v["rule"] for v in blocking)
        return f"550 5.7.1 Message blocked by DLP policy ({rules}); incident {incident}"

    if violations:
        header = f"X-DLP-Result: monitor; incident={incident}; rules={','.join(v['rule'] for v in violations)}"
        log(event="monitor", incident=incident, sender=mail_from, rcpts=rcpts, subject=subject,
            rules=[v["rule"] for v in violations])
        notify(incident, mail_from, rcpts, subject, violations, data, blocked=False)
    else:
        header = "X-DLP-Result: pass"
        log(event="pass", sender=mail_from, rcpts=rcpts, subject=subject)
    reply = relay(mail_from, rcpts, header.encode() + b"\r\n" + data, mail_options)
    log(event="relayed", sender=mail_from, reply=reply)
    return reply


def notify(incident, mail_from, rcpts, subject, violations, data, blocked):
    conf = POLICY["notify"]
    verdict = "ブロックして隔離しました" if blocked else "通過させましたが記録しました (monitor)"
    summary = describe(violations)
    try:
        if blocked and conf.get("sender") and mail_from and mail_from != conf["from"]:
            send_notice(mail_from, f"[DLP] 送信したメールはブロックされました ({incident})",
                        f"あなたが送信したメールは、データ漏洩防止 (DLP) ポリシーに違反するため配送されませんでした。\n\n"
                        f"件名: {subject}\n宛先: {', '.join(rcpts)}\nインシデント ID: {incident}\n\n{summary}\n\n"
                        f"業務上必要な場合は、インシデント ID を添えて管理者に連絡してください。\n")
        if conf.get("auditor"):
            send_notice(conf["auditor"], f"[DLP] ポリシー違反 {incident}: {subject}",
                        f"DLP ポリシーに一致したメールを{verdict}。\n\n"
                        f"インシデント ID: {incident}\n送信者: {mail_from}\n宛先: {', '.join(rcpts)}\n"
                        f"件名: {subject}\n\n{summary}\n\n原本を添付します。\n",
                        attachment=data, attachment_name=f"{incident}.eml")
    except (OSError, smtplib.SMTPException) as e:
        log(event="notify_failed", incident=incident, error=str(e))


# ---------------------------------------------------------------- SMTP server

class Session:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.reset()

    def reset(self):
        self.mail_from, self.mail_options, self.rcpts = None, [], []

    async def send(self, line):
        self.writer.write(line.encode("utf-8", "replace") + b"\r\n")
        await self.writer.drain()

    async def readline(self):
        return await asyncio.wait_for(self.reader.readline(), IDLE_TIMEOUT)

    async def run(self):
        await self.send(f"220 {HOSTNAME} ESMTP DLP lab")
        while True:
            raw = await self.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            verb, _, arg = line.partition(" ")
            verb = verb.upper()
            if verb == "EHLO":
                self.reset()
                await self.send(f"250-{HOSTNAME}\r\n250-8BITMIME\r\n250-PIPELINING\r\n250 SIZE {MAX_MESSAGE}")
            elif verb == "HELO":
                self.reset()
                await self.send(f"250 {HOSTNAME}")
            elif verb == "MAIL":
                m = re.match(r"FROM:\s*<([^>]*)>\s*(.*)", arg, re.I)
                if not m:
                    await self.send("501 5.5.4 Syntax: MAIL FROM:<address>")
                    continue
                self.reset()
                self.mail_from, self.mail_options = m.group(1), m.group(2).split()
                await self.send("250 2.1.0 Ok")
            elif verb == "RCPT":
                m = re.match(r"TO:\s*<([^>]*)>", arg, re.I)
                if self.mail_from is None:
                    await self.send("503 5.5.1 Need MAIL first")
                elif not m:
                    await self.send("501 5.5.4 Syntax: RCPT TO:<address>")
                else:
                    self.rcpts.append(m.group(1))
                    await self.send("250 2.1.5 Ok")
            elif verb == "DATA":
                if not self.rcpts:
                    await self.send("503 5.5.1 Need RCPT first")
                    continue
                await self.send("354 End data with <CR><LF>.<CR><LF>")
                data = await self.read_data()
                if data is None:
                    await self.send("552 5.3.4 Message too big")
                else:
                    await self.send(await self.inspect(data))
                self.reset()
            elif verb == "RSET":
                self.reset()
                await self.send("250 2.0.0 Ok")
            elif verb == "NOOP":
                await self.send("250 2.0.0 Ok")
            elif verb == "QUIT":
                await self.send("221 2.0.0 Bye")
                return
            else:
                await self.send("502 5.5.2 Command not recognized")

    async def read_data(self):
        lines, size = [], 0
        while True:
            raw = await self.readline()
            if not raw:
                raise ConnectionError("client went away during DATA")
            if raw in (b".\r\n", b".\n"):
                break
            if raw.startswith(b"."):
                raw = raw[1:]                    # undo dot-stuffing
            size += len(raw)
            if size <= MAX_MESSAGE:
                lines.append(raw)
        return b"".join(lines) if size <= MAX_MESSAGE else None

    async def inspect(self, data):
        loop = asyncio.get_running_loop()
        try:
            return await loop.run_in_executor(None, handle, self.mail_from, list(self.rcpts),
                                              data, self.mail_options)
        except Exception as e:  # never accept a message we could not inspect
            log(event="error", sender=self.mail_from, error=repr(e))
            return "451 4.3.0 DLP engine error, try again later"


async def client_connected(reader, writer):
    try:
        await Session(reader, writer).run()
    except (asyncio.TimeoutError, ConnectionError, ValueError):
        pass
    finally:
        writer.close()


async def main():
    server = await asyncio.start_server(client_connected, *LISTEN, limit=1024 * 1024)
    log(event="start", listen=f"{LISTEN[0]}:{LISTEN[1]}", next_hop=f"{NEXT_HOP[0]}:{NEXT_HOP[1]}",
        rules=[r["name"] for r in POLICY["rules"]])
    async with server:
        await server.serve_forever()


with open(POLICY_FILE, encoding="utf-8") as f:
    POLICY = json.load(f)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
