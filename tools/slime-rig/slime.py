import sys,collections
sys.path.insert(0, sys.argv[1])
from render import mask
from PIL import Image
N=1024
m=mask(sys.argv[2],N)              # blue fill
px=m.load()
# character = not blue
inv=[[0 if px[x,y] else 1 for x in range(N)] for y in range(N)]
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
            comps.append((len(pts),min(xs),min(ys),max(xs),max(ys),pts))
comps.sort(key=lambda c:-c[0])
for c in comps[:12]: print(c[0],c[1:5])
