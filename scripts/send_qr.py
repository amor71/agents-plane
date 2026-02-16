#!/usr/bin/env python3
"""
Atomic WhatsApp QR email delivery.
Takes a base64 PNG (from whatsapp_login tool) and emails it immediately.

Usage: python3 send_qr.py <owner_email> <base64_png_data>
   OR: echo <base64_png_data> | python3 send_qr.py <owner_email> -

The base64 data can optionally include the data:image/png;base64, prefix.
Designed to complete in <5 seconds — no LLM delay.
"""
import sys, os, base64, time, subprocess, re

def email_qr(owner_email, qr_png_path):
    """Email QR image using gmail.py."""
    gmail_py = os.path.expanduser("~/.config/agents-plane/gmail.py")
    html = (
        "<h2>⚡ Scan this QR code with WhatsApp NOW</h2>"
        "<p><b>Open WhatsApp → Settings → Linked Devices → Link a Device</b></p>"
        "<p><img src='cid:qrcode' width='300'/></p>"
        "<p>⚠️ This code expires in about 60 seconds! Scan it immediately.</p>"
        "<p>If it expired, just reply <b>connect</b> again and I'll send a fresh one.</p>"
    )
    result = subprocess.run([
        "python3", gmail_py, "send_html",
        owner_email, owner_email,
        "⚡ Scan this QR NOW — 60 seconds!",
        html,
        f"qrcode:{qr_png_path}"
    ], capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        print(f"Email error: {result.stderr}", file=sys.stderr)
    return result.returncode == 0

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 send_qr.py <owner_email> <base64_png_data>", file=sys.stderr)
        print("   OR: echo <data> | python3 send_qr.py <owner_email> -", file=sys.stderr)
        sys.exit(1)

    owner_email = sys.argv[1]
    
    # Get base64 data from arg or stdin
    if sys.argv[2] == "-":
        b64_data = sys.stdin.read().strip()
    else:
        b64_data = sys.argv[2]
    
    # Strip data URI prefix if present
    b64_data = re.sub(r'^data:image/png;base64,', '', b64_data)
    
    # Decode and save
    qr_path = "/tmp/whatsapp-qr.png"
    try:
        png_bytes = base64.b64decode(b64_data)
        with open(qr_path, 'wb') as f:
            f.write(png_bytes)
        print(f"[{time.strftime('%H:%M:%S')}] QR image saved ({len(png_bytes)} bytes)")
    except Exception as e:
        print(f"ERROR decoding base64: {e}", file=sys.stderr)
        sys.exit(1)

    # Email immediately
    print(f"[{time.strftime('%H:%M:%S')}] Emailing QR to {owner_email}...")
    if email_qr(owner_email, qr_path):
        print(f"[{time.strftime('%H:%M:%S')}] ✅ QR emailed successfully!")
    else:
        print(f"[{time.strftime('%H:%M:%S')}] ❌ Email failed", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
