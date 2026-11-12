import re,sys
from PIL import Image, ImageDraw, ImageChops
def polys(path):
    s=open(path).read(); d=re.search(r' d="([^"]+)"',s).group(1)
    out=[]
    for sub in re.findall(r'M([^MZ]+)Z',d):
        n=list(map(float,sub.split())); out.append(list(zip(n[0::2],n[1::2])))
    return out
def mask(path,size=512):
    m=Image.new('1',(size,size),0); k=size/1024
    for p in polys(path):
        t=Image.new('1',(size,size),0); ImageDraw.Draw(t).polygon([(x*k,y*k) for x,y in p],fill=1)
        m=ImageChops.logical_xor(m,t)
    return m
if __name__=='__main__':
  files=sys.argv[2:]; out=sys.argv[1]
  W=Image.new('RGB',(520*len(files),520),'white')
  for i,f in enumerate(files):
    m=mask(f); bg=Image.new('RGB',(512,512),(230,240,255)); fg=Image.new('RGB',(512,512),(29,161,242))
    W.paste(Image.composite(fg,bg,m.convert('L')),(i*520,4))
  W.save(out)
  for f in files: print(f,len(polys(f)),'subpaths')
