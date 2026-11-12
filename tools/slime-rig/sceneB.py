import sys,math,random,os,json
B,S=sys.argv[1],sys.argv[2]
sys.path.insert(0,S)
from rig3 import Rig
import goo, meniscus; goo.load(S)
from PIL import Image, ImageDraw, ImageFont
random.seed(11)
R=Rig(B,S); K=1.25
SW,SH=440,956; IH=37; ITOP=14; IBOT=ITOP+IH; TUCK=5; IX0=SW/2-63; IX1=SW/2+63
FLOOR=874; LEGH=9.0; CX=SW/2
EDGES=json.load(open(S+'/edges.json')); CONTOUR=goo.CONTOUR
FONT='/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc'
f13=ImageFont.truetype(FONT,int(13*K)); f15=ImageFont.truetype(FONT,int(15*K)); f16=ImageFont.truetype(FONT,int(16*K))
ACC=(29,161,242)
def ss(x,a,b): t=max(0,min(1,(x-a)/(b-a))); return t*t*(3-2*t)
def lerp(a,b,t): return a+(b-a)*t
def P(x,y): return (x*K,y*K)
def background():
    c=Image.new('RGBA',(int(SW*K),int(SH*K)),(255,255,255,255)); d=ImageDraw.Draw(c)
    for i in range(11):
        y=180+i*64
        d.ellipse([*P(16,y),*P(56,y+40)],fill=(200,205,212))
        d.rounded_rectangle([*P(66,y+4),*P(216,y+14)],radius=4*K,fill=(210,214,220))
        d.rounded_rectangle([*P(66,y+22),*P(366,y+32)],radius=4*K,fill=(228,231,235))
    d.rectangle([*P(0,0),*P(SW,160)],fill=(255,255,255))
    d.ellipse([*P(20,69),*P(60,109)],fill=(160,170,180))
    d.text(P(140,128),'추천',font=f13,fill=(15,20,25)); d.text(P(262,128),'팔로우 중',font=f13,fill=(110,118,125))
    d.rectangle([*P(128,156),*P(170,159)],fill=ACC); d.line([*P(0,160),*P(SW,160)],fill=(215,219,223),width=1)
    d.text(P(38,19),'10:13',font=f15,fill=(0,0,0))
    d.rounded_rectangle([*P(372,22),*P(397,34)],radius=3*K,outline=(0,0,0),width=1); d.rectangle([*P(374,24),*P(390,32)],fill=(0,0,0))
    # floating tab bar
    d.rounded_rectangle([*P(20,FLOOR),*P(420,FLOOR+62)],radius=31*K,fill=(246,247,249),outline=(225,228,232),width=1)
    for j in range(5): d.ellipse([*P(51+j*78-11,FLOOR+20),*P(51+j*78+11,FLOOR+42)],fill=(150,158,166) if j else (20,24,28))
    d.rounded_rectangle([*P(160,944),*P(280,949)],radius=3*K,fill=(20,20,20))
    return c
BG=background()
def island(d): d.rounded_rectangle([*P(IX0,ITOP),*P(IX1,IBOT)],radius=IH/2*K,fill=(0,0,0))
def poly(d,pts,fill=(0,0,0,255)): d.polygon([P(x,y) for x,y in pts],fill=fill)
def floor_pts(w,h,cx=CX):
    """a puddle on the tab bar, laid out like the contour (root along the floor)"""
    return [(cx-x,FLOOR-y) for x,y in goo.drop(max(w,1),max(h*0.55,0.5),max(h,0.5),max(min(h*0.9,w*0.3),0.3))]
def upright_pts(hx,hipy,sy=1.0):
    return [(hx-x,hipy-y*sy) for x,y in CONTOUR]
def hanging_pts(ax,stretch):
    return [(ax+x,IBOT-TUCK+y*stretch) for x,y in CONTOUR]
def mix(a,b,t): return [(lerp(p[0],q[0],t),lerp(p[1],q[1],t)) for p,q in zip(a,b)]
def legs(d,Bd,scale,tuck=0.0):
    J=R.joints(Bd); (P0,t0,w0)=J[0]; n=(t0[1],-t0[0])
    for side in (-1,1):
        hx,hy=P0[0]+n[0]*7*side*w0,P0[1]+n[1]*7*side*w0
        L=LEGH*scale*(1-0.5*tuck); fx,fy=hx,hy+L
        w=3.2*scale
        d.rounded_rectangle([*P(hx-w,hy-2),*P(hx+w,fy)],radius=w*K,fill=(0,0,0,255))
        d.ellipse([*P(fx-4.2*scale,fy-3*scale),*P(fx+4.2*scale,fy+2.2*scale)],fill=(0,0,0,255))
# --------------------------------------------------------------- timeline
SEG=[('hang',1.0),('droop',0.8),('pinch',0.28),('fall',None),('splat',0.6),('rise',0.85),('stand',3.2),('melt',0.5),('thread',0.45),('suck',1.1),('emerge',1.2),('greet',1.6)]
CAP={'hang':'','droop':'무거워져서 쭉 늘어지다가','pinch':'똑 끊어져서','fall':'물방울로 떨어짐','splat':'탭바 위에 철퍽','rise':'웅덩이에서 솟아오르며 다리가 생김',
     'stand':'일어서서 두리번 + 통통 뛰기','melt':'다시 녹아서','thread':'아일랜드에서 실이 내려와','suck':'쭈욱 빨아올려 합체','emerge':'다시 나와서','greet':'인사'}
frames_dir=S+'/vBframes'; os.makedirs(frames_dir,exist_ok=True)
for f in os.listdir(frames_dir): os.remove(frames_dir+'/'+f)
dt=1/60; clock=0; fi=0; step=0
seg_i=0; seg_t=0
stretch=1.0; svel=0.0; R.reset((CX,IBOT-TUCK)); R.expr='normal'
fallY=0; fallV=0; drops=[]; facing=1; hopY=0; hopV=0; nextBlink=0.6; blinkT=-9
while seg_i<len(SEG):
    name,dur=SEG[seg_i]
    clock+=dt; seg_t+=dt; e=seg_t
    rig_mode=None; shape=None; extra=[]; leg_scale=0; leg_tuck=0
    if name in ('hang','droop','greet'):
        target=1.65 if name=='droop' else 1.0
        if name=='droop' and e>0.3: R.expr='surprised'
        if name=='greet': R.expr='happy'; R.wave=1.0 if e<1.3 else 0.0
        svel+=(90*(target-stretch)-9*svel)*dt; stretch+=svel*dt
        rig_mode=dict(anchor=(CX,IBOT-TUCK),rootDir=(0,1),gscale=1,stiff=1,length=stretch)
    elif name=='pinch':
        a=hanging_pts(CX,stretch); b=[(CX+x,IBOT-TUCK+y) for x,y in goo.drop(lerp(44,10,ss(e,0,dur)),lerp(4,2,e/dur),lerp(98,80,e/dur),lerp(15,13,e/dur))]
        shape=mix(a,b,ss(e,0,dur)); fallY=0; fallV=0
    elif name=='fall':
        fallV+=1900*dt; fallY+=fallV*dt
        tail=10+min(12,fallV*0.006)         # a teardrop that lengthens a little with speed
        top=IBOT-TUCK+40+fallY
        shape=[(CX+x,top+y) for x,y in goo.drop(7,4.5,tail+24,12.5)]
        # what the neck left behind: a little drip that pulls back into the island
        r=max(0,1-fallY/90)
        if r>0: extra.append([(CX+x,IBOT-TUCK+y) for x,y in goo.drop(lerp(8,18,r),lerp(0.5,2,r),lerp(1,30,r)*r,lerp(1,4,r))])
        if top+tail+24>=FLOOR:
            dur=e; SEG[seg_i]=(name,dur)
            for k in range(5):
                an=math.radians(random.uniform(205,335)); sp=random.uniform(120,220)
                drops.append([CX+random.uniform(-8,8),FLOOR-5,math.cos(an)*sp,math.sin(an)*sp,random.uniform(2.0,3.4)])
    elif name=='splat':
        w=30+88*(1-math.exp(-e*13))+12*math.exp(-e*5)*math.sin(e*24)
        h=max(9,34*math.exp(-e*14)+9+2.5*math.exp(-e*6)*math.sin(e*20))
        shape=floor_pts(w,h)
    elif name=='rise':
        t=ss(e,0,dur); w=lerp(118,44,ss(e,0,dur*0.5)); h=lerp(7,14,ss(e,0,dur*0.5))
        a=floor_pts(w,max(h,9)); b=upright_pts(CX,FLOOR-LEGH,lerp(0.7,1.1,t))
        shape=mix(a,b,ss(e,dur*0.25,dur)); leg_scale=ss(e,dur*0.5,dur)
        if e+dt>=dur:
            R.reset((CX,FLOOR-LEGH),1.0,(0,-1)); stretch=1.15; svel=0; R.expr='surprised'; R.wave=0
    elif name=='stand':
        leg_scale=1
        if e<0.5: R.expr='surprised'
        elif e<1.2: R.expr='curious'
        else: R.expr='happy'
        if abs(e-0.8)<dt/2: facing=-facing          # looks the other way
        for h0 in (1.35,2.15):                     # two hops
            if abs(e-(h0-0.12))<dt/2: svel-=1.6     # crouch
            if abs(e-h0)<dt/2: hopV=-260; svel+=2.2
        if hopV!=0 or hopY<0:
            hopV+=1500*dt; hopY+=hopV*dt
            if hopY>=0: hopY=0; hopV=0; svel-=1.8
        leg_tuck=1.0 if hopY<-2 else 0.0
        svel+=(130*(1-stretch)-9*svel)*dt; stretch+=svel*dt
        rig_mode=dict(anchor=(CX,FLOOR-LEGH+hopY),rootDir=(0,-1),gscale=-0.12,stiff=3.0,length=stretch)
    elif name=='melt':
        t=ss(e,0,dur); a=upright_pts(CX,FLOOR-LEGH,lerp(1,0.6,t)); b=floor_pts(100,9)
        shape=mix(a,b,t); leg_scale=1-t
    elif name=='thread':
        shape=floor_pts(100,9)
        tip=lerp(IBOT,FLOOR-7,ss(e,0,dur))
        extra.append([(CX-2.2,IBOT-2),(CX+2.2,IBOT-2),(CX+1.5,tip),(CX-1.5,tip)])
        extra.append([(CX+3*math.cos(a),tip+3*math.sin(a)) for a in [i*math.pi/8 for i in range(16)]])
        extra.append([(CX-9,IBOT-1),(CX+9,IBOT-1),(CX+2.4,IBOT+7),(CX-2.4,IBOT+7)])
    elif name=='suck':
        t=ss(e,0,dur*0.85); shape=floor_pts(lerp(100,6,t),lerp(9,1.5,t))
        by=lerp(FLOOR-14,IBOT+4,ss(e,0.08,dur*0.9)); br=lerp(9,6,t)
        bottom=lerp(FLOOR-7,IBOT,ss(e,dur*0.8,dur))
        wid=lerp(2.2,3.4,math.sin(min(1,e/dur)*math.pi))
        extra.append([(CX-wid,IBOT-2),(CX+wid,IBOT-2),(CX+wid*0.7,bottom),(CX-wid*0.7,bottom)])
        if e<dur*0.92: extra.append([(CX+br*0.8*math.cos(a),by+br*math.sin(a)) for a in [i*math.pi/10 for i in range(20)]])
        extra.append([(CX-10,IBOT-1),(CX+10,IBOT-1),(CX+wid,IBOT+8),(CX-wid,IBOT+8)])
    elif name=='emerge':
        pts,done=goo.emerge_shape(e); shape=[(CX+x,IBOT-TUCK+y) for x,y in pts]
        if done or e+dt>=dur:
            dur=e; SEG[seg_i]=(name,dur); R.reset((CX,IBOT-TUCK)); stretch=1.15; svel=0; R.expr='happy'
    # splash droplets
    for dp in drops:
        dp[3]+=1400*dt; dp[0]+=dp[2]*dt; dp[1]+=dp[3]*dt
    drops=[dp for dp in drops if dp[1]<FLOOR-1]
    # --- simulate & draw
    if rig_mode:
        R.simulate(dt,rig_mode['anchor'],rig_mode['length']*(1+math.sin(clock*2.4)*0.012),clock,rig_mode['rootDir'],rig_mode['gscale'],rig_mode['stiff'],breeze=40)
        Bd=R.bands(); R.step_bones(Bd,dt); R.update_face(dt,clock)
        if clock>nextBlink: blinkT=clock; nextBlink=clock+random.uniform(1.8,3.6)
    if step%2==0:
        c=BG.copy(); layer=Image.new('RGBA',c.size,(0,0,0,0)); d=ImageDraw.Draw(layer)
        if rig_mode:
            bl=math.sin((clock-blinkT)/0.15*math.pi) if 0<=clock-blinkT<0.15 else 0
            R.render(layer,K,Bd,bl,0,clock)
            if name in ('hang','droop','greet'):
                Le,Re=R.edges(Bd,EDGES)
                for pl in meniscus.junction(Le,Re,meniscus.Pill(IX0,IX1,ITOP,IBOT),min(1,abs(svel)*0.6)): poly(d,pl)
            if name=='stand': legs(d,Bd,1.0,leg_tuck)
            if name=='stand' and facing<0:
                hx=CX; layer=layer.transpose(Image.FLIP_LEFT_RIGHT); l2=Image.new('RGBA',c.size,(0,0,0,0)); l2.paste(layer,(int((2*hx-SW)*K),0)); layer=l2; d=ImageDraw.Draw(layer)
        if shape:
            poly(d,shape)
            if name in ('pinch',):
                gl=[shape[0]]+shape[:-41:-1]; gr=shape[23:63]
                for pl in meniscus.junction(gl,gr,meniscus.Pill(IX0,IX1,ITOP,IBOT),0.8): poly(d,pl)
            if name=='emerge':
                gl=[shape[0]]+shape[:-41:-1]; gr=shape[23:63]
                for pl in meniscus.junction(gl,gr,meniscus.Pill(IX0,IX1,ITOP,IBOT),0.6): poly(d,pl)
        for ex in extra: poly(d,ex)
        if leg_scale>0 and name in ('rise','melt'):
            for side in (-1,1):
                hx=CX+side*7; w=3.2*leg_scale
                d.rounded_rectangle([*P(hx-w,FLOOR-LEGH-2),*P(hx+w,FLOOR-LEGH+LEGH*leg_scale)],radius=max(1,w*K),fill=(0,0,0,255))
        for dp in drops: d.ellipse([*P(dp[0]-dp[4],dp[1]-dp[4]),*P(dp[0]+dp[4],dp[1]+dp[4])],fill=(0,0,0,255))
        c.alpha_composite(layer); d=ImageDraw.Draw(c); island(d)
        cap=CAP.get(name,'')
        if cap:
            tw=d.textlength(cap,font=f16)
            d.rounded_rectangle([(SW*K-tw)/2-12*K,470*K,(SW*K+tw)/2+12*K,498*K],radius=14*K,fill=(20,24,28))
            d.text(((SW*K-tw)/2,474*K),cap,font=f16,fill=(255,255,255))
        c.convert('RGB').save(f'{frames_dir}/f{fi:05d}.png'); fi+=1
    step+=1
    if dur is not None and seg_t>=dur:
        seg_i+=1; seg_t=0
print(fi,'frames')
