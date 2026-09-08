#!/usr/bin/env python3
"""สังเคราะห์เสียงลูกแมวเป็น WAV — ไม่ใช้ไฟล์เสียงจากข้างนอก แอปจึงยังเป็นก้อนเดียว

เสียงแมวจริงคือ f0 ที่ไถลขึ้น-ลง + ฮาร์มอนิก ผ่าน formant ของช่องปาก
ลูกแมวเสียงเล็กเพราะ f0 สูงและ formant สูงตาม เราเลยตั้งค่าไปทางนั้น
"""
import math, struct, wave, pathlib

RATE = 22050


def formant_gain(freq, formants):
    """ความดังของฮาร์มอนิกหนึ่งเส้น เมื่อผ่านยอด resonance หลายยอด"""
    g = 0.03
    for center, width, peak in formants:
        g += peak / (1.0 + ((freq - center) / width) ** 2)
    return g


def voiced(dur, f0_at, formants, harmonics=14, vibrato=(5.5, 0.02)):
    """สร้างเสียงจากสายเสียง: ฮาร์มอนิกซ้อนกันตาม f0 ที่เปลี่ยนตามเวลา"""
    n = int(RATE * dur)
    out = [0.0] * n
    phase = [0.0] * (harmonics + 1)
    vib_rate, vib_depth = vibrato
    for i in range(n):
        t = i / RATE
        p = t / dur
        f0 = f0_at(p) * (1.0 + vib_depth * math.sin(2 * math.pi * vib_rate * t))
        s = 0.0
        for h in range(1, harmonics + 1):
            f = f0 * h
            if f > RATE / 2.2:
                break
            phase[h] += 2 * math.pi * f / RATE
            s += (formant_gain(f, formants) / (h ** 1.05)) * math.sin(phase[h])
        out[i] = s
    return out


def envelope(buf, attack, release, curve=1.0):
    n = len(buf)
    a = max(1, int(RATE * attack))
    r = max(1, int(RATE * release))
    for i in range(n):
        e = 1.0
        if i < a:
            e = (i / a) ** curve
        if i > n - r:
            e *= ((n - i) / r) ** curve
        buf[i] *= e
    return buf


def normalize(buf, peak=0.82):
    m = max(abs(v) for v in buf) or 1.0
    return [v * peak / m for v in buf]


def write_wav(path, buf):
    data = b''.join(struct.pack('<h', int(max(-1.0, min(1.0, v)) * 32767)) for v in buf)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(data)
    return len(data) + 44


# formant ของลูกแมว: (ความถี่กลาง, ความกว้าง, ความสูงยอด)
KITTEN = [(920, 260, 1.0), (2250, 520, 0.55), (3400, 700, 0.22)]

sounds = {}

# เหมียว — ไถลขึ้นแล้วตกลง เหมือน "มี-ยาว"
sounds['meow'] = envelope(voiced(
    0.42, lambda p: 560 + 300 * math.sin(math.pi * min(p * 1.35, 1.0)) - 130 * p * p,
    KITTEN), 0.035, 0.16, curve=1.4)

# เหมียวสั้น ทักทาย — สดใสกว่า
sounds['mew'] = envelope(voiced(
    0.26, lambda p: 700 + 260 * math.sin(math.pi * p) - 90 * p,
    KITTEN, vibrato=(7.0, 0.015)), 0.02, 0.10, curve=1.3)

# ครืดๆ ดีใจ (trill) — สั่นเร็ว ๆ ตอนพอใจ
trill = voiced(0.30, lambda p: 620 + 200 * p, KITTEN, harmonics=10, vibrato=(0, 0))
for i in range(len(trill)):
    trill[i] *= 0.55 + 0.45 * math.sin(2 * math.pi * 34 * (i / RATE))
sounds['trill'] = envelope(trill, 0.02, 0.09, curve=1.2)

# เมี้ยว! ตกใจ — ตกลงเร็ว
sounds['mrrp'] = envelope(voiced(
    0.22, lambda p: 880 - 380 * p ** 0.7, KITTEN, vibrato=(9.0, 0.03)), 0.008, 0.07, curve=1.1)

# ครางตอนลูบ (purr) — พัลส์ต่ำ ๆ ประมาณ 26 Hz
n = int(RATE * 0.70)
purr = [0.0] * n
ph = [0.0] * 9
for i in range(n):
    t = i / RATE
    pulse = 0.5 + 0.5 * math.sin(2 * math.pi * 26 * t)
    s = 0.0
    for h in range(1, 9):
        f = 105 * h
        ph[h] += 2 * math.pi * f / RATE
        s += (formant_gain(f, [(180, 120, 1.0), (600, 400, 0.3)]) / h) * math.sin(ph[h])
    purr[i] = s * (pulse ** 2.2)
sounds['purr'] = envelope(purr, 0.09, 0.16, curve=1.0)

out = pathlib.Path('voice')
out.mkdir(exist_ok=True)
for name, buf in sounds.items():
    size = write_wav(str(out / f'{name}.wav'), normalize(buf))
    print(f'  {name:6s} {len(buf)/RATE:.2f}s  {size/1024:.1f} KB')
print('เขียนไฟล์เสียงลง voice/ แล้ว')

# ฝัง WAV ลง Swift แบบเดียวกับสไปรต์ชีท แอปจึงยังเป็นไฟล์เดียวไม่ต้องพก resource
import base64
lines = ["// CatVoiceData",
         "// เสียงลูกแมวสังเคราะห์เอง สร้างซ้ำได้ด้วย make-cat-voice.py",
         "",
         "import Foundation",
         "",
         "let CAT_VOICE_WAV: [String: String] = ["]
for name in ['meow', 'mew', 'trill', 'mrrp', 'purr']:
    b64 = base64.b64encode((out / f'{name}.wav').read_bytes()).decode()
    lines.append(f'    "{name}": "{b64}",')
lines.append("]")
pathlib.Path('Sources/CatVoiceData.swift').write_text("\n".join(lines) + "\n")
print('ฝังลง Sources/CatVoiceData.swift แล้ว (%d KB)'
      % (pathlib.Path('Sources/CatVoiceData.swift').stat().st_size / 1024))
