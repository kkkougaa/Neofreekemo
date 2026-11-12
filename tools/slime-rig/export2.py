import sys,pickle,json,math
S,OUT=sys.argv[1],sys.argv[2]
from PIL import Image, ImageDraw, ImageFilter
N=1024; C=(88,64,1024,1024); CW,CH=C[2]-C[0],C[3]-C[1]
pts=set(pickle.load(open(S+'/comps.png.pkl','rb'))[0]); P=pickle.load(open(S+'/parts.pkl','rb'))
# the thin crescent along the logo's bottom-right corner is not part of the fox
sliver=lambda p: (p[0]>=978 and p[1]>=770) or (p[0]>=958 and p[1]>=850)
pts={p for p in pts if not sliver(p)}
for k in P: P[k]={p for p in P[k] if not sliver(p)}
def poly_mask(poly):
    m=Image.new('1',(N,N),0); ImageDraw.Draw(m).polygon(poly,fill=1); mp=m.load()
    return lambda x,y: mp[x,y]==1
# fur tufts: (protrusion triangle base1, tip, base2), inward extension for the hidden overlap
tufts={
 'furA':((447,398),(399,431),(443,452),(472,398),(470,452)),
 'furB':((395,522),(362,556),(414,570),(440,522),(440,572)),
 'furC':((952,537),(1010,575),(935,661),(905,537),(905,661)),
 'furD':((935,661),(994,718),(879,780),(892,661),(846,780)),
 'furE':((879,780),(921,826),(858,842),(838,780),(822,842)),
 'furF':((464,858),(484,908),(505,877),(482,836),(522,852)),
}
earL=set(P['earL']); earR=set(P['earR'])
# ears reach into the head for the hidden overlap (as before)
earLfull={p for p in pts if 450<=p[0]<=712 and p[1] < 358-(p[0]-455)*0.223+16}|earL
earRfull={p for p in pts if p[0]>=696 and p[1] < 302+(p[0]-700)*0.921+16 and p[1]<528 and p not in earLfull}|earR
base=set(P['base'])
parts={}; pivots={}; tips={}
for name,(b1,tip,b2,i1,i2) in tufts.items():
    prot=poly_mask([b1,tip,b2]); full=poly_mask([i1,b1,tip,b2,i2])
    parts[name]={p for p in pts if full(*p)}
    base-={p for p in base if prot(*p)}
    pivots[name]=((b1[0]+b2[0])/2,(b1[1]+b2[1])/2); tips[name]=tip
# ears: base and tip halves, split across the ear's axis at its middle
def split(ear,piv,tip):
    ax,ay=tip[0]-piv[0],tip[1]-piv[1]; L=math.hypot(ax,ay); ux,uy=ax/L,ay/L
    mid=(piv[0]+ax*0.5,piv[1]+ay*0.5)
    t=lambda p:(p[0]-mid[0])*ux+(p[1]-mid[1])*uy
    return {p for p in ear if t(p)<=4},{p for p in ear if t(p)>-12},mid
for name,ear,piv,tip in (('earL',earLfull,(585,338),(575,78)),('earR',earRfull,(806,402),(905,114))):
    lo,hi,mid=split(ear,piv,tip)
    parts[name+'Base']=lo; parts[name+'Tip']=hi
    pivots[name+'Base']=piv; pivots[name+'Tip']=mid; tips[name+'Base']=mid; tips[name+'Tip']=tip
parts['phone']=P['phone']; pivots['phone']=(300,828); tips['phone']=(190,640)
parts['paw']=P['paw']; pivots['paw']=(455,975); tips['paw']=(200,880)
parts['base']=base
for k in ('lid','oval','mouth'): parts[k]=P[k]
pivots.update({'lid':(595,541),'oval':(575,556),'mouth':(377,625)})
TW=240; TH=round(CH*TW/CW)
for name,pix in parts.items():
    m=Image.new('L',(N,N),0); mp=m.load()
    for x,y in pix: mp[x,y]=255
    m=m.filter(ImageFilter.GaussianBlur(0.6)).crop(C).transpose(Image.FLIP_TOP_BOTTOM).resize((TW,TH),Image.LANCZOS)
    color=(255,255,255) if name in ('lid','oval','mouth') else (0,0,0)
    im=Image.new('RGBA',(TW,TH),color+(0,)); im.putalpha(m); im.save(f'{OUT}/slime_{name}.png')
def uv(p): return [round((p[0]-C[0])/CW,4), round(1-(p[1]-C[1])/CH,4)]
meta={'size':[TW,TH],'pivots':{k:uv(v) for k,v in pivots.items()},'tips':{k:uv(v) for k,v in tips.items()}}
union=pts
rows=[]
for i in range(40):
    v=(i+0.5)/40; y=round(C[3]-v*CH); xs=[x for x in range(C[0],C[2]) if (x,y) in union]
    rows.append([round((min(xs)-C[0])/CW,3),round((max(xs)-C[0])/CW,3)] if xs else [0.5,0.5])
meta['rows']=rows
json.dump(meta,open(f'{S}/slime_meta.json','w'),indent=1)
# overlay check (upright)
im=Image.new('RGB',(N,N),'white'); ip=im.load()
cols={'base':(0,0,0),'earLBase':(220,40,40),'earLTip':(255,140,140),'earRBase':(40,90,220),'earRTip':(140,170,255),'phone':(30,160,60),'lid':(240,170,0),'oval':(200,0,200),'mouth':(0,180,180)}
fc=[(255,120,0),(160,80,0),(0,150,150),(120,0,160),(200,0,90),(90,160,0)]
for i,n in enumerate(tufts): cols[n]=fc[i]
cols['paw']=(255,120,0)
for k in ['earLTip','earRTip','earLBase','earRBase','phone']+list(tufts)+['base','paw','lid','oval','mouth']:
    for x,y in parts[k]: ip[x,y]=cols[k]
im.resize((640,640)).save(S+'/parts2.png')
print(sorted(parts))
