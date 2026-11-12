import sys,pickle,collections,json
sys.path.insert(0,sys.argv[1]); S=sys.argv[1]
from render import mask
from PIL import Image, ImageDraw, ImageChops
N=1024
pts=pickle.load(open(S+'/comps.png.pkl','rb'))[0]
char=Image.new('L',(N,N),0); cp=char.load()
for x,y in pts: cp[x,y]=255
# holes: background components fully enclosed by the character bbox region, not touching outside
inv=ImageChops.invert(char); ip=inv.load()
seen=set(); holes=[]
for y in range(N):
    for x in range(N):
        if ip[x,y] and (x,y) not in seen:
            q=collections.deque([(x,y)]); seen.add((x,y)); comp=[]; edge=False
            while q:
                a,b=q.popleft(); comp.append((a,b))
                if a in (0,N-1) or b in (0,N-1): edge=True
                for c,d in ((a+1,b),(a-1,b),(a,b+1),(a,b-1)):
                    if 0<=c<N and 0<=d<N and ip[c,d] and (c,d) not in seen:
                        seen.add((c,d)); q.append((c,d))
            if not edge and len(comp)<200000:
                xs=[p[0] for p in comp]; ys=[p[1] for p in comp]
                holes.append((len(comp),(min(xs),min(ys),max(xs),max(ys)),comp))
holes.sort(key=lambda h:-h[0])
for h in holes: print('hole',h[0],h[1])
pickle.dump(holes,open(S+'/holes.pkl','wb'))
