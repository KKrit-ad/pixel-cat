# ที่มาของทรัพย์สินในโปรเจกต์

## เสียง

เสียงทั้งหมดของน้องมาจาก **[BigSoundBank](https://bigsoundbank.com/)**
บันทึกโดย **Joseph SARDIN** เผยแพร่ภายใต้ **CC0 1.0 Universal (Public Domain)**
ใช้ได้ทั้งงานส่วนตัวและงานค้าโดยไม่ต้องขออนุญาต ไม่ต้องให้เครดิต และไม่ต้องจ่ายค่าสิทธิ์
— แต่เราให้เครดิตไว้เพราะเจ้าของบอกว่า "ยินดีถ้าใส่ให้"

| เสียงในแอป | ไฟล์ต้นทาง | หน้าเว็บ |
|---|---|---|
| `meow` เหมียวเต็มเสียง | `1891.mp3` | [Meow cat #3](https://bigsoundbank.com/meow-cat-3-s1891.html) |
| `mew` เหมียวสั้นเสียงสูง | `0494.mp3` | [Little Meow of a Cat #1](https://bigsoundbank.com/little-meow-of-a-cat-s0494.html) |
| `trill` ดีใจ | `0390.mp3` | [Mewing kitten 3 weeks](https://bigsoundbank.com/mewing-kitten-3-weeks-s0390.html) |
| `mrrp` ตกใจ | `0390.mp3` | [Mewing kitten 3 weeks](https://bigsoundbank.com/mewing-kitten-3-weeks-s0390.html) |
| `purr` คราง | `0436.mp3` | [Cat Purr](https://bigsoundbank.com/cat-purr-s0436.html) |

### สร้างเสียงใหม่

ไฟล์ต้นทางอยู่ใน `voice/source/` (ไม่ได้เก็บใน git เพราะโหลดใหม่ได้)
โหลดใหม่ด้วย — ต้องส่ง Referer เป็นหน้าเสียงนั้น ไม่งั้นเว็บจะปฏิเสธ:

```bash
mkdir -p voice/source && cd voice/source
curl -L -A "Mozilla/5.0" -e "https://bigsoundbank.com/meow-cat-3-s1891.html" \
  -o 1891.mp3 "https://bigsoundbank.com/UPLOAD/mp3/1891.mp3"
```

(ทำแบบเดียวกันกับ `0494`, `0390`, `0436` โดยเปลี่ยน Referer เป็นหน้าของไฟล์นั้น)

แล้วตัด/ปรับความดัง/ฝังลง Swift ด้วย:

```bash
python3 import-cat-voice.py
./build.sh
```

ช่วงเวลาที่ตัดและระดับความดังเป้าหมายอยู่ในตาราง `CUTS` ที่หัวไฟล์ `import-cat-voice.py`

## สไปรต์

วาดเองทั้งหมดในโปรเจกต์นี้ (`sprite-source.html` → `gen-sheet.js` → `cat-sheet.png`)
