import sys,collections
sys.path.insert(0, sys.argv[1])
from render import mask
from PIL import Image, ImageDraw
N=1024
m=mask(sys.argv[2],N); px=m.load()
sq=Image.new('1',(N,N),0); ImageDraw.Draw(sq).rounded_rectangle([10,0,1013,1023],radius=201,fill=1); sp=sq.load()
inv=[[1 if (sp[x,y] and not px[x,y]) else 0 for x in range(N)] for y in range(N)]
seen=[[0]*N for _ in range(N)]; comps=[]
for y in range(N):
    for x in range(N):
        if inv[y][x] and not seen[y][x]:
            q=collections.deque([(x,y)]); seen[y][x]=1; pts=[]
            while q:
                cx,cy=q.popleft(); pts.append((cx,cy))
                for nx,ny in ((cx+1,cy),(cx-1,cy),(cx,cy+1),(cx,cy-1)):
                    if 0<=nx<N and 0<=ny<N and inv[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx]=1; q.append((nx,ny))
            xs=[p[0] for p in pts]; ys=[p[1] for p in pts]
            comps.append((len(pts),(min(xs),min(ys),max(xs),max(ys)),pts))
comps.sort(key=lambda c:-c[0])
for c in comps[:12]: print(c[0],c[1])
# preview: each comp colored
img=Image.new('RGB',(N,N),'white'); ip=img.load()
cols=[(0,0,0),(220,30,30),(30,160,30),(30,30,220),(200,150,0),(150,0,150),(0,150,150),(120,120,120)]
for i,c in enumerate(comps[:8]):
    for (x,y) in c[2]: ip[x,y]=cols[i]
img.resize((512,512)).save(sys.argv[3])
import pickle; pickle.dump([c[2] for c in comps],open(sys.argv[3]+'.pkl','wb'))
