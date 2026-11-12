import sys,pickle
S=sys.argv[1]
from PIL import Image, ImageDraw
N=1024
pts=pickle.load(open(S+'/comps.png.pkl','rb'))[0]; holes=pickle.load(open(S+'/holes.pkl','rb'))
char={p for p in pts if not ((p[0]>=978 and p[1]>=770) or (p[0]>=958 and p[1]>=850))}
earL=lambda x,y: 450<=x<=712 and y < 358-(x-455)*0.223
earR=lambda x,y: x>=700 and y < 302+(x-700)*0.921 and y<512
P=[(78,705),(78,655),(108,612),(288,598),(314,620),(408,800),(376,838),(330,816),(268,796),(212,809),(191,835),(183,872),(148,872),(78,710)]
pm=Image.new('1',(N,N),0); ImageDraw.Draw(pm).polygon(P,fill=1); pmp=pm.load()
PAW=[(168,1023),(166,905),(178,880),(195,840),(212,805),(255,790),(300,795),(350,812),(400,838),(445,860),(462,905),(500,960),(540,1023)]
pw=Image.new('1',(N,N),0); ImageDraw.Draw(pw).polygon(PAW,fill=1); pw=pw.filter(__import__('PIL.ImageFilter',fromlist=['x']).MaxFilter(3)); pwp=pw.load()
inpaw=lambda x,y: pwp[x,y]==1
phone=lambda x,y: pmp[x,y]==1 and not inpaw(x,y)
eye=set(holes[1][2]); snout=set(holes[4][2])
lid_bottom=lambda x: 570-0.216*(x-515)+2
oval={p for p in eye if p[1]>lid_bottom(p[0])}; lid=eye-oval
parts={k:set() for k in ['base','earL','earR','phone']}
for p in char:
    x,y=p
    if earL(x,y): parts['earL'].add(p)
    elif earR(x,y): parts['earR'].add(p)
    elif phone(x,y): parts['phone'].add(p)
    else: parts['base'].add(p)
parts['base']|=eye|snout   # face holes filled; the face layers draw them
# the two cheek triangles are filled in: a plain cheek
parts['base']|=set(holes[2][2])|set(holes[3][2])
# the paw: drawn on top, turning at the wrist; only the hand that sticks out leaves the body
parts['paw']={p for p in char if inpaw(*p)}
parts['base']-={p for p in parts['paw'] if p[0]<420}
parts['lid']=lid; parts['oval']=oval; parts['mouth']=snout
for k,v in parts.items():
    xs=[p[0] for p in v]; ys=[p[1] for p in v]; print(k,len(v),(min(xs),min(ys),max(xs),max(ys)))
pickle.dump(parts,open(S+'/parts.pkl','wb'))
cols={'base':(0,0,0),'earL':(220,40,40),'earR':(40,90,220),'phone':(30,160,60),'lid':(240,170,0),'oval':(200,0,200),'mouth':(0,180,180)}
im=Image.new('RGB',(N,N),'white'); ip=im.load()
cols['paw']=(255,120,0)
for k in ['base','earL','earR','phone','paw','lid','oval','mouth']:
    for x,y in parts[k]: ip[x,y]=cols[k]
im.resize((640,640)).save(S+'/parts.png')
