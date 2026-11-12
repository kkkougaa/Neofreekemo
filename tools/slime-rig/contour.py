import sys,json,math
from PIL import Image, ImageFilter
B,S=sys.argv[1],sys.argv[2]
names=['phone','earLTip','earRTip','earLBase','earRBase','furA','furB','furC','furD','furE','furF','base']
first=Image.open(f'{B}/slime_base.png'); TW,TH=first.size
a=Image.new('L',(TW,TH),0)
for n in names: a=Image.composite(Image.new('L',(TW,TH),255),a,Image.open(f'{B}/slime_{n}.png').split()[3].point(lambda v:255 if v>110 else 0))
# close small gaps so the outline is one loop (ear inner openings, phone screen)
a=a.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(3))
p=a.load()
inside=lambda x,y: 0<=x<TW and 0<=y<TH and p[x,y]>0
# Moore boundary tracing from the leftmost pixel of the top row
y0=0; x0=next(x for x in range(TW) if inside(x,0))
dirs=[(1,0),(1,1),(0,1),(-1,1),(-1,0),(-1,-1),(0,-1),(1,-1)]
cur=(x0,y0); back=4; path=[cur]
for _ in range(200000):
    found=False
    for k in range(8):
        d=(back+1+k)%8; nx,ny=cur[0]+dirs[d][0],cur[1]+dirs[d][1]
        if inside(nx,ny):
            back=(d+4)%8; cur=(nx,ny); found=True; break
    if not found or cur==(x0,y0): break
    path.append(cur)
W=60.0; k=W/TW
pts=[((x+0.5)*k-W/2,(y+0.5)*k) for x,y in path]
# the root edge: run along y==0 from the start to the right end of the top row
xr=max(x for x in range(TW) if inside(x,0))
top_end=next(i for i,(x,y) in enumerate(path) if y==0 and x==xr)
def resample(seq,n,closed=False):
    L=[0]
    for i in range(1,len(seq)): L.append(L[-1]+math.dist(seq[i-1],seq[i]))
    tot=L[-1]; out=[]; j=0
    for i in range(n):
        s=tot*i/(n-1 if not closed else n)
        while j<len(L)-2 and L[j+1]<s: j+=1
        t=(s-L[j])/max(L[j+1]-L[j],1e-9); out.append((seq[j][0]+(seq[j+1][0]-seq[j][0])*t, seq[j][1]+(seq[j+1][1]-seq[j][1])*t))
    return out
top=resample(pts[:top_end+1],24)          # left -> right along the root (hidden under the island)
rest=resample(pts[top_end:]+[pts[0]],97)[1:-1]  # right side down, round the head, up the left
M=top+rest
print(len(M),'points; top',top[0],top[-1],'H',TH*k)
json.dump(M,open(S+'/contour.json','w'))
from PIL import ImageDraw
im=Image.new('RGB',(240,250),'white'); d=ImageDraw.Draw(im)
d.polygon([((x+W/2)*4,y*4) for x,y in M],fill=(0,0,0))
for i,(x,y) in enumerate(M[::6]): d.text(((x+W/2)*4,y*4),str(i*6),fill=(255,0,0))
im.save(S+'/contour.png')
