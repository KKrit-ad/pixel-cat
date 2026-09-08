#!/usr/bin/env python3
"""ตัดเสียงแมวจริงจาก voice/source/ มาเป็นเสียงของน้อง แล้วฝังลง Swift

เสียงต้นทางมาจาก BigSoundBank (CC0, บันทึกโดย Joseph SARDIN) โหลดเป็น MP3
แล้วแปลงเป็น WAV 22050 Hz mono ด้วย afconvert ที่ macOS มีให้อยู่แล้ว
ที่ต้องตัดเองเพราะไฟล์ต้นทางเป็นเสียงยาวหลายพยางค์ เราอยากได้พยางค์เดียวสั้น ๆ
"""
import base64, math, pathlib, struct, subprocess, sys, wave

RATE = 22050
SRC = pathlib.Path('voice/source')
OUT = pathlib.Path('voice')

# (ไฟล์ต้นทาง, เริ่ม, จบ, ระดับความดังเป้าหมาย) — ช่วงเวลาได้จากการวิเคราะห์ burst
CUTS = {
    'meow':  ('1891', 0.02, 1.10, 0.30),   # เหมียวเต็มเสียง ใช้ตอนทัก
    'mew':   ('0494', 0.02, 0.50, 0.30),   # เหมียวสั้นเสียงสูง ลูกแมว
    'trill': ('0390', 1.50, 1.88, 0.26),   # เสียงลูกแมวสั้นสดใส ใช้ตอนดีใจ
    'mrrp':  ('0390', 9.66, 9.86, 0.28),   # สั้นมาก ใช้ตอนตกใจ
    'purr':  ('0436', 8.60, 9.80, 0.22),   # ครางตอนถูกลูบ
}


def ensure_wav(stem):
    """แปลง mp3 ต้นทางเป็น wav ครั้งเดียว ใช้เครื่องมือที่ macOS มีอยู่แล้ว"""
    wav = SRC / f'{stem}.wav'
    if not wav.exists():
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', f'LEI16@{RATE}', '-c', '1',
                        str(SRC / f'{stem}.mp3'), str(wav)], check=True)
    return wav


def load(path):
    with wave.open(str(path), 'rb') as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        data = w.readframes(w.getnframes())
    return [v / 32768 for (v,) in struct.iter_unpack('<h', data)]


def cut(buf, start, end):
    return buf[int(start * RATE):int(end * RATE)]


def fade(buf, ms_in=6, ms_out=25):
    """ตัดกลางคลื่นจะได้เสียง 'ปั้ก' ต้องเฟดหัวท้ายเสมอ"""
    a, b = int(RATE * ms_in / 1000), int(RATE * ms_out / 1000)
    n = len(buf)
    for i in range(min(a, n)):
        buf[i] *= i / a
    for i in range(min(b, n)):
        buf[n - 1 - i] *= i / b
    return buf


def soft_limit(v, knee=0.70, ceiling=0.95):
    """บีบเฉพาะยอดคลื่น ต่ำกว่า knee ปล่อยผ่านหมด เสียงเลยไม่เพี้ยน"""
    a = abs(v)
    if a <= knee:
        return v
    room = ceiling - knee
    return math.copysign(knee + room * math.tanh((a - knee) / room), v)


def level(buf, target_rms):
    """ปรับด้วย RMS ไม่ใช่ peak เสียงแต่ละแบบจะได้ 'ดังเท่ากัน' ตอนฟังจริง

    เสียงแมวมียอดแหลมสูงกว่าค่าเฉลี่ยมาก ถ้าหั่นด้วย peak อย่างเดียว
    เสียงสั้น ๆ อย่าง mew จะเบากว่าเพื่อนจนฟังไม่ออกว่าน้องส่งเสียง
    """
    rms = math.sqrt(sum(v * v for v in buf) / len(buf)) or 1e-9
    gain = target_rms / rms
    return [soft_limit(v * gain) for v in buf]


def write(path, buf):
    data = b''.join(struct.pack('<h', int(max(-1.0, min(1.0, v)) * 32767)) for v in buf)
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(data)
    return len(data) + 44


if not SRC.exists():
    sys.exit('ไม่พบ voice/source/ — ดูวิธีโหลดเสียงต้นทางใน CREDITS.md')

OUT.mkdir(exist_ok=True)
lines = ['// CatVoiceData',
         '// เสียงแมวจริงจาก BigSoundBank (CC0) ตัดและปรับด้วย import-cat-voice.py',
         '// ที่มาและสัญญาอนุญาตอยู่ใน CREDITS.md',
         '',
         'import Foundation',
         '',
         'let CAT_VOICE_WAV: [String: String] = [']
for name, (stem, a, b, target) in CUTS.items():
    buf = level(fade(cut(load(ensure_wav(stem)), a, b)), target)
    size = write(OUT / f'{name}.wav', buf)
    rms = math.sqrt(sum(v * v for v in buf) / len(buf))
    print(f'  {name:6s} {stem}  {len(buf)/RATE:.2f}s  {size/1024:5.1f} KB  rms={rms:.3f}')
    lines.append(f'    "{name}": "{base64.b64encode((OUT / f"{name}.wav").read_bytes()).decode()}",')
lines.append(']')
pathlib.Path('Sources/CatVoiceData.swift').write_text('\n'.join(lines) + '\n')
print('ฝังลง Sources/CatVoiceData.swift แล้ว (%.0f KB)'
      % (pathlib.Path('Sources/CatVoiceData.swift').stat().st_size / 1024))
