import zlib,struct,binascii,sys,os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
def read_png(p):
    d=open(p,'rb').read(); pos=8; idat=b''
    while pos<len(d):
        ln=struct.unpack('>I',d[pos:pos+4])[0]; typ=d[pos+4:pos+8]; data=d[pos+8:pos+8+ln]
        if typ==b'IHDR': w,h=struct.unpack('>II',data[:8])
        elif typ==b'IDAT': idat+=data
        pos+=12+ln
    raw=zlib.decompress(idat); st=w*4
    return w,h,[list(raw[y*(st+1)+1:(y+1)*(st+1)]) for y in range(h)]
def write_png(p,w,h,rows):
    raw=b''.join(b'\x00'+bytes(r) for r in rows)
    def ch(t,dd):
        b=t+dd; return struct.pack('>I',len(dd))+b+struct.pack('>I',binascii.crc32(b)&0xffffffff)
    open(p,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
w,h,rows=read_png('cat-sheet.png')
out_name=sys.argv[1]; S=int(sys.argv[2]); frames=[int(v) for v in sys.argv[3:]] or list(range(w//32))
out=[]
for y in range(h):
    line=[]
    for fi in frames:
        for x in range(fi*32,(fi+1)*32):
            r,g,b,a=rows[y][x*4:x*4+4]
            if a==0: r,g,b=(244,246,242)
            line+=[r,g,b,255]*S
    for _ in range(S): out.append(line)
write_png(out_name,len(frames)*32*S,h*S,out)
print(out_name,len(frames)*32*S,'x',h*S)
