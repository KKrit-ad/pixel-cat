const fs=require('fs'), zlib=require('zlib');
const src=fs.readFileSync('sprite-source.html','utf8');
const code=src.slice(src.indexOf('const SW=32'), src.indexOf('/* ---------- rasterize'));
fs.writeFileSync('_poses.js', code+'\nmodule.exports={POSES,FRAMES,outline,P,SW,SH};');
const {POSES,FRAMES,outline,P,SW,SH}=require('./_poses.js');

const order=[
  {key:"walk",     pose:"walk",    count:4, blink:false, fps:9.0},
  {key:"walkBlink",pose:"walk",    count:4, blink:true,  fps:9.0},
  {key:"run",      pose:"run",     count:4, blink:false, fps:12.0},
  {key:"runBlink", pose:"run",     count:4, blink:true,  fps:12.0},
  {key:"sit",      pose:"sit",     count:4, blink:false, fps:2.2},
  {key:"sitBlink", pose:"sit",     count:4, blink:true,  fps:2.2},
  {key:"tilt",     pose:"tilt",    count:2, blink:false, fps:1.6},
  {key:"lick",     pose:"lick",    count:2, blink:false, fps:2.5},
  {key:"sleep",    pose:"sleep",   count:2, blink:false, fps:1.0},
  {key:"stretch",  pose:"stretch", count:2, blink:false, fps:2.0},
  {key:"crouch",   pose:"crouch",  count:2, blink:false, fps:4.0},
  {key:"climb",    pose:"climb",   count:2, blink:false, fps:4.5},
  {key:"held",     pose:"held",    count:2, blink:false, fps:3.0},
  {key:"ball",     pose:"ball",    count:4, blink:false, fps:8.0},
  {key:"gecko",    pose:"gecko",   count:2, blink:false, fps:7.0},
  {key:"jump",     pose:"jump",    count:1, blink:false, fps:1.0}
];
const total=order.reduce((n,o)=>n+o.count,0);
const W=SW*total, H=SH;
const rgba=Buffer.alloc(W*H*4,0);
const hx=h=>[parseInt(h.slice(1,3),16),parseInt(h.slice(3,5),16),parseInt(h.slice(5,7),16)];

let idx=0, manifest=[], swift=[];
for(const o of order){
  manifest.push({name:o.key, start:idx, count:o.count});
  swift.push(`    "${o.key}":${" ".repeat(Math.max(0,11-o.key.length))} Pose(start: ${idx}, count: ${o.count}, fps: ${o.fps.toFixed(1)})`);
  for(let f=0;f<o.count;f++,idx++){
    const b=outline(POSES[o.pose](f,o.blink));
    for(let y=0;y<SH;y++)for(let x=0;x<SW;x++){
      const c=b[y*SW+x]; if(!c)continue;
      const [r,g,bl]=hx(c);
      const p=((y*W)+(idx*SW+x))*4;
      rgba[p]=r; rgba[p+1]=g; rgba[p+2]=bl; rgba[p+3]=255;
    }
  }
}
fs.writeFileSync('poses.swift.txt','let POSES: [String: Pose] = [\n'+swift.join(',\n')+'\n]\n');

/* --- minimal PNG encoder --- */
const T=(()=>{const t=new Int32Array(256);for(let n=0;n<256;n++){let c=n;for(let k=0;k<8;k++)c=c&1?0xEDB88320^(c>>>1):c>>>1;t[n]=c;}return t;})();
const crc=b=>{let c=~0;for(const v of b)c=T[(c^v)&255]^(c>>>8);return ~c>>>0;};
function chunk(type,data){
  const len=Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body=Buffer.concat([Buffer.from(type,'ascii'),data]);
  const cr=Buffer.alloc(4); cr.writeUInt32BE(crc(body));
  return Buffer.concat([len,body,cr]);
}
const ihdr=Buffer.alloc(13);
ihdr.writeUInt32BE(W,0); ihdr.writeUInt32BE(H,4);
ihdr[8]=8; ihdr[9]=6; ihdr[10]=0; ihdr[11]=0; ihdr[12]=0;
const raw=Buffer.alloc(H*(W*4+1));
for(let y=0;y<H;y++){ raw[y*(W*4+1)]=0; rgba.copy(raw, y*(W*4+1)+1, y*W*4, (y+1)*W*4); }
const png=Buffer.concat([
  Buffer.from([137,80,78,71,13,10,26,10]),
  chunk('IHDR',ihdr),
  chunk('IDAT',zlib.deflateSync(raw,{level:9})),
  chunk('IEND',Buffer.alloc(0))
]);
fs.writeFileSync('cat-sheet.png',png);
fs.writeFileSync('cat-sheet.b64',png.toString('base64'));
console.log(JSON.stringify({W,H,SW,SH,total,manifest}));
console.log('png bytes', png.length, '| b64', png.toString('base64').length);
