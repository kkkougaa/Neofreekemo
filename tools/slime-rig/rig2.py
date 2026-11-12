import math,sys,json,random
from PIL import Image, ImageDraw
B,S=sys.argv[1],sys.argv[2]
meta=json.load(open(S+'/slime_meta.json'))
TW,TH=meta['size']; W=60.0; H=W*TH/TW; PXPT=TW/W
IMG={n:Image.open(f'{B}/slime_{n}.png') for n in ['base','earLBase','earLTip','earRBase','earRTip','phone','lid','oval','mouth','furA','furB','furC','furD','furE','furF']}
PIV={k:(u*W,v*H) for k,(u,v) in meta['pivots'].items()}
TIP={k:(u*W,v*H) for k,(u,v) in meta['tips'].items()}
ROWS=[(0.133,0.867),(0.096,0.925),(0.087,0.946),(0.117,0.842),(0.108,0.812),(0.163,0.833),(0.421,0.892),(0.321,0.958),(0.279,0.892),(0.263,0.925),(0.250,0.963),(0.350,0.975),(0.312,0.925),(0.346,0.858)]
NB=14; SUB=4; bandH=H/NB
random.seed(3)
# ---------------- body chain
pts=[[0,0] for _ in range(NB+1)]; prev=[[0,0] for _ in range(NB+1)]; ready=False
def simulate(dt,anchor,length,clock):
    global ready
    rest=bandH*length
    if not ready:
        for i in range(NB+1): pts[i]=[anchor[0],anchor[1]+rest*i]; prev[i]=pts[i][:]
        ready=True
    h=dt/SUB
    for _ in range(SUB):
        pts[0]=list(anchor); prev[0]=list(anchor)
        for i in range(1,NB+1):
            d=i/NB; breeze=(math.sin(clock*1.3+d*0.9)+0.4*math.sin(clock*3.1))*60*d
            p=pts[i]; v=[(p[0]-prev[i][0])*0.985,(p[1]-prev[i][1])*0.985]
            prev[i]=p[:]; pts[i]=[p[0]+v[0]+breeze*h*h, p[1]+v[1]+1400*h*h]
        for _ in range(3):
            for i in range(NB):
                a,b=pts[i],pts[i+1]; dx,dy=b[0]-a[0],b[1]-a[1]; dist=max(math.hypot(dx,dy),1e-4)
                push=(dist-rest)/dist*0.55
                if i==0: pts[1][0]-=dx*push; pts[1][1]-=dy*push
                else:
                    pts[i][0]+=dx*push*.5; pts[i][1]+=dy*push*.5; pts[i+1][0]-=dx*push*.5; pts[i+1][1]-=dy*push*.5
                par=(0,1) if i==0 else (pts[i][0]-pts[i-1][0],pts[i][1]-pts[i-1][1]); pl=max(math.hypot(*par),1e-4)
                want=(pts[i][0]+par[0]/pl*rest, pts[i][1]+par[1]/pl*rest); st=0.24-0.14*(i/NB)
                pts[i+1][0]+=(want[0]-pts[i+1][0])*st; pts[i+1][1]+=(want[1]-pts[i+1][1])*st
            pts[0]=list(anchor)
def bands(squeeze):
    out=[]
    for i in range(NB):
        a,b=pts[i],pts[i+1]; dx,dy=b[0]-a[0],b[1]-a[1]; dist=math.hypot(dx,dy); st=dist/bandH
        w=max(0.7,min(1.3,1/math.sqrt(max(st,0.05))))*squeeze
        if st<1: w=min(w,1.15*squeeze)
        out.append((a,math.atan2(-dx,dy),w,max(st,1e-3)))
    return out
def body_xform(u,v,B_):  # canvas point -> world, plus band angle and scales
    i=min(NB-1,max(0,int(v/bandH))); a,ang,w,st=B_[i]
    lx=(u-W/2)*w; ly=(v-i*bandH)*st
    c,s=math.cos(ang),math.sin(ang)
    return (a[0]+c*lx-s*ly, a[1]+s*lx+c*ly), ang, w, st
# ---------------- secondary bones
class Bone:
    def __init__(s,name,parent,k,c,gain,limit):
        s.n=name; s.parent=parent; s.k=k; s.c=c; s.gain=gain; s.limit=limit
        s.th=0; s.om=0; s.target=0; s.hist=[]; s.pang=None; s.pom=0
        tx,ty=TIP[name][0]-PIV[name][0],TIP[name][1]-PIV[name][1]; s.L=max(math.hypot(tx,ty),1); s.dir=(tx/s.L,ty/s.L)
BONES=[Bone('earLBase',None,140,10,0.5,0.32),Bone('earLTip','earLBase',95,7,0.7,0.42),
       Bone('earRBase',None,140,10,0.5,0.32),Bone('earRTip','earRBase',95,7,0.7,0.42)]+\
      [Bone(f,None,230,10,0.8,0.3) for f in ['furA','furB','furC','furD','furE','furF']]+[Bone('phone',None,120,10,0.25,0.25)]
BY={b.n:b for b in BONES}
ramp=0
def bone_world(b,B_,cache):
    if b.n in cache: return cache[b.n]
    if b.parent is None:
        P,ang,w,st=body_xform(*PIV[b.n],B_)
        # parts follow the body's stretch only gently, or thin parts turn into spikes
        g=lambda z:max(0.8,min(1.25,math.sqrt(z)))
        sc=(g(w),g(st))
    else:
        pP,pang,psc=bone_world(BY[b.parent],B_,cache)
        lx=(PIV[b.n][0]-PIV[b.parent][0])*psc[0]; ly=(PIV[b.n][1]-PIV[b.parent][1])*psc[1]
        c,s=math.cos(pang),math.sin(pang); P=(pP[0]+c*lx-s*ly,pP[1]+s*lx+c*ly); ang=pang; sc=psc
    res=(P,ang+b.th,sc); cache[b.n]=res; return res
def step_bones(B_,dt,depth):
    cache={}
    global ramp
    if depth>0.45:
        # mostly inside the island: nothing to swing, settle quietly
        for b in BONES: b.th*=0.8; b.om*=0.5; b.hist=[]; b.pang=None; b.pom=0
        ramp=0
        return
    ramp=min(1,ramp+dt/0.4)  # the swing comes in gently once it is out
    for b in BONES:
        # parent frame (without own angle)
        P,ang,sc=bone_world(b,B_,cache); base_ang=ang-b.th
        b.hist.append(P); b.hist=b.hist[-3:]
        acc=(0,0)
        if len(b.hist)==3: acc=((b.hist[2][0]-2*b.hist[1][0]+b.hist[0][0])/dt/dt,(b.hist[2][1]-2*b.hist[1][1]+b.hist[0][1])/dt/dt)
        pom=0
        if b.pang is not None: pom=(base_ang-b.pang)/dt
        palpha=(pom-b.pom)/dt; b.pang=base_ang; b.pom=pom
        c,s=math.cos(base_ang+b.th),math.sin(base_ang+b.th); dx,dy=c*b.dir[0]-s*b.dir[1], s*b.dir[0]+c*b.dir[1]
        acc=(max(-2500,min(2500,acc[0])),max(-2500,min(2500,acc[1])))
        palpha=max(-400,min(400,palpha))
        torque=(dx*acc[1]-dy*acc[0])/b.L   # lateral push of the hinge swings the part the other way
        a=-b.k*(b.th-b.target)-b.c*b.om-ramp*(b.gain*torque*0.02+b.gain*palpha*0.02)
        b.om+=a*dt; b.th+=b.om*dt; b.th=max(-b.limit,min(b.limit,b.th))
# ---------------- face / expression
face={'oval':1.0,'eyeScale':1.0,'lid':0.0,'mouth':1.0,'perk':0.0,'phone':1.0}
expr_targets={'normal':dict(oval=1,eyeScale=1,lid=0,mouth=1,perk=0,phone=1),
 'surprised':dict(oval=1,eyeScale=1.25,lid=1.6,mouth=1.45,perk=1,phone=0),
 'happy':dict(oval=0.16,eyeScale=1.05,lid=-0.6,mouth=1.3,perk=0.5,phone=1),
 'squint':dict(oval=0.3,eyeScale=0.95,lid=-0.8,mouth=0.75,perk=-1,phone=1)}
phoneSpring=[1.0,0.0]
# ---------------- render
K=3
def paste(canvas,name,P,ang,sx,sy,mirror_x=None,extra=None):
    im=IMG[name]; px,py=PIV[name] if extra is None else extra
    # output pixel (X,Y) -> world pt (X/K,Y/K) -> local canvas pt -> input px
    c,s=math.cos(ang),math.sin(ang)
    # inverse: local = piv + S^-1 R^-1 (world-P)
    a=c/sx/K; b=s/sx/K; cc=px-(c*P[0]+s*P[1])/sx
    d=-s/sy/K; e=c/sy/K; f=py-(-s*P[0]+c*P[1])/sy
    data=(a*PXPT,b*PXPT,cc*PXPT,d*PXPT,e*PXPT,f*PXPT)
    layer=im.transform(canvas.size,Image.AFFINE,data,resample=Image.BILINEAR)
    canvas.alpha_composite(layer)
def render(B_,cache,canvas,squeeze,blinkAmt,talk):
    order=['phone','earLTip','earRTip','earLBase','earRBase','furA','furB','furC','furD','furE','furF']
    for n in order:
        b=BY[n]; P,ang,sc=bone_world(b,B_,cache)
        sx,sy=sc
        if n=='phone':
            o=phoneSpring[0]; k=0.35+0.65*max(0,min(1.15,o)); ang+= (1-o)*0.7; sx*=k; sy*=k
            if o<0.12: continue
        if n.startswith('ear'):
            sy*=1+0.07*face['perk']*(1 if n.endswith('Base') else 0.5)
        paste(canvas,n,P,ang,sx,sy)
    # body bands
    for i in range(NB):
        a,ang,w,st=B_[i]
        band=IMG['base']
        y0=int(i*bandH*PXPT); y1=min(TH,int(((i+1)*bandH+1.5)*PXPT)) if i<NB-1 else TH
        m=Image.new('RGBA',band.size,(0,0,0,0)); m.paste(band.crop((0,y0,TW,y1)),(0,y0))
        IMG['_band']=m; PIV['_band']=(W/2,i*bandH)
        paste(canvas,'_band',a,ang,w,st)
    # face
    for n in ['lid','oval','mouth']:
        P,ang,w,st=body_xform(*PIV[n],B_)
        sx,sy=w,st
        piv=PIV[n]
        if n=='oval':
            sy*=max(0.04,face['oval']*(1-blinkAmt)); sx*=face['eyeScale']; sy*=face['eyeScale']
        if n=='lid':
            P=(P[0],P[1]+face['lid']*st)
        if n=='mouth':
            m=face['mouth']*(1+0.3*talk); sx*=m; sy*=m
        paste(canvas,n,P,ang,sx,sy)
def meniscus(d,B_,Bot,squeeze,f):
    for i in range(NB):
        a=pts[i]; b=pts[i+1]
        if a[1]<=Bot<b[1]:
            t=(Bot-a[1])/(b[1]-a[1]); x=a[0]+t*(b[0]-a[0])
            v=(i+t)/NB
            if v>=0.58: return   # past the body only the ears cross: no meniscus between them
            r=ROWS[min(len(ROWS)-1,int(v*24))]; w=B_[i][2]
            l=x+(r[0]*W-W/2)*w; rr=x+(r[1]*W-W/2)*w
            f=min(f,max(0,(rr-l))*0.45)
            if f<0.8: return
            K_=K
            # concave fillets on both sides, from the flat island bottom down onto the body
            for side in (-1,1):
                ex=l if side<0 else rr
                pts_=[]
                for j in range(13):
                    th=j/12*math.pi/2
                    pts_.append((ex+side*f*(1-math.sin(th)) , Bot+f*(1-math.cos(th))))
                poly=[(ex,Bot-6),(ex+side*f,Bot-6)]+pts_[::-1]+[(ex,Bot+f)]
                d.polygon([(px*K_,py*K_) for px,py in poly],fill=(0,0,0,255))
            d.rectangle([l*K_,(Bot-6)*K_,rr*K_,(Bot+1)*K_],fill=(0,0,0,255))
            return
# ---------------- scenario
frames=[]; dt=1/60; t=0; outv=0; vel=0; clock=0
spot='center'; spots={'left':-35,'center':0,'right':35}
expr='surprised'; exprUntil=1.2; nextBlink=1.6; blinkT=-1; talkUntil=-1
events=[(2.6,'bubble'),(4.6,'peek'),(6.8,'happy'),(8.2,'barhide'),(9.4,'barshow'),(11.2,'flick')]
peekUntil=-1; barhidden=False
CXW=220; ISL=(47,14,173,51)  # island in local scene pt
while t<12.5:
    for et,ev in events:
        if abs(t-et)<dt/2:
            if ev=='bubble': expr='surprised'; exprUntil=t+1.6; talkUntil=t+1.0; vel+=1.2
            if ev=='peek': peekUntil=t+0.6
            if ev=='happy': expr='happy'; exprUntil=t+1.4
            if ev=='barhide': barhidden=True
            if ev=='barshow': barhidden=False
            if ev=='flick': BY['earLTip'].om+=9; BY['earRBase'].om-=6
    if t>exprUntil and expr!='normal': expr='normal'
    target=0 if (barhidden or t<peekUntil) else 1
    if target==0 and outv<0.05 and t<peekUntil+0.1 and spot!='left' and not barhidden: spot='left'; ready=False
    if barhidden and outv<0.05: spot='right'; ready=False
    if target==0 and expr=='normal': expr='squint'; exprUntil=t+0.2
    if target==1 and outv<0.2 and expr!='surprised': expr='surprised'; exprUntil=t+0.9
    k,c=(130,9) if target>outv else (30,10)
    vel+=(k*(target-outv)-c*vel)*dt; outv=max(0,outv+vel*dt); clock+=dt
    depth=max(0,1-outv); length=max(1,outv)*(1+math.sin(clock*2.4)*0.012)
    ax=CXW/2+spots[spot]; anchor=(ax,51-5-depth*(H+4))
    simulate(dt,anchor,length,clock)
    B_=bands(1-0.3*depth)
    step_bones(B_,dt,depth)
    # expression smoothing
    tg=expr_targets[expr]
    for kk in ('oval','eyeScale','lid','mouth'): face[kk]+=(tg[kk]-face[kk])*min(1,dt*14)
    face['perk']+=(tg['perk']-face['perk'])*min(1,dt*8)
    for e in ('earLBase','earRBase'): BY[e].target=(-0.22 if e=='earLBase' else 0.22)*face['perk']
    ps=phoneSpring; ps[1]+=(160*(tg['phone']-ps[0])-11*ps[1])*dt; ps[0]+=ps[1]*dt
    # blink
    if t>nextBlink: blinkT=t; nextBlink=t+random.uniform(2.2,5.0); 
    bl=0
    if blinkT>0 and t-blinkT<0.16: x=(t-blinkT)/0.16; bl=math.sin(x*math.pi)
    talk=abs(math.sin(t*15)) if t<talkUntil else 0
    if int(round(t*60))%2==0:
        canvas=Image.new('RGBA',(CXW*K,150*K),(255,255,255,255))
        rig=Image.new('RGBA',canvas.size,(0,0,0,0))
        if depth<0.98:
            render(B_,{},rig,1-0.3*depth,bl,talk)
            if spot=='right':
                rig=rig.transpose(Image.FLIP_LEFT_RIGHT); shift=int((2*ax-CXW)*K)
                r2=Image.new('RGBA',rig.size,(0,0,0,0)); r2.paste(rig,(shift,0)); rig=r2
            m=Image.new('L',canvas.size,0); ImageDraw.Draw(m).rectangle([0,(51-30)*K,canvas.size[0],canvas.size[1]],fill=255)
            a=rig.split()[3]; from PIL import ImageChops; rig.putalpha(ImageChops.multiply(a,m))
            canvas.alpha_composite(rig)
            d=ImageDraw.Draw(canvas)
            f=2.5+6*min(1,depth*2.5)+3*min(1,abs(vel))
            if spot!='right': meniscus(d,B_,51,1,f)
            else:
                tmp=Image.new('RGBA',canvas.size,(0,0,0,0)); meniscus(ImageDraw.Draw(tmp),B_,51,1,f)
                tmp=tmp.transpose(Image.FLIP_LEFT_RIGHT); r2=Image.new('RGBA',tmp.size,(0,0,0,0)); r2.paste(tmp,(int((2*ax-CXW)*K),0)); canvas.alpha_composite(r2)
        d=ImageDraw.Draw(canvas)
        d.rounded_rectangle([ISL[0]*K,ISL[1]*K,ISL[2]*K,ISL[3]*K],radius=18*K,fill=(0,0,0,255))
        d.text((6,6),f"t={t:.1f} {expr} spot={spot}",fill=(200,0,0,255))
        frames.append(canvas.convert('RGB').resize((CXW*2,300)))
    t+=dt
frames[0].save(S+'/rig2.gif',save_all=True,append_images=frames[1:],duration=33,loop=0)
keys=[2,10,20,45,78,82,90,138,143,150,160,205,215,250,265,285,300,345]
strip=Image.new('RGB',(440*6,300*3),'white')
for j,k in enumerate(keys): strip.paste(frames[min(k,len(frames)-1)],((j%6)*440,(j//6)*300))
strip.save(S+'/rig2_strip.png'); print(len(frames))
