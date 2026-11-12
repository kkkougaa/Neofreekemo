import sys,math,random,os
S=sys.argv[1]; sys.path.insert(0,S)
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from art_pose import Poses, warp
import goo, meniscus; goo.load(S)
random.seed(4)
P=Poses(S); K=2
SW,SH=440,260; IH=37; ITOP=14; IBOT=51; IX0,IX1=SW/2-63,SW/2+63; X0=SW/2
FLOOR=116; KP=50/329.0       # points per artwork pixel: the standing fox is 50pt tall
FONT='/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc'
f13=ImageFont.truetype(FONT,13*K); f15=ImageFont.truetype(FONT,15*K)
ACC=(29,161,242)
def ss(x,a=0,b=1): t=max(0,min(1,(x-a)/(b-a))); return t*t*(3-2*t)
def eout(x): x=max(0,min(1,x)); return 1-(1-x)**3
def lerp(a,b,t): return a+(b-a)*t
def background():
    c=Image.new('RGBA',(SW*K,SH*K),(255,255,255,255)); d=ImageDraw.Draw(c)
    for i in range(2):
        y=172+i*62
        d.ellipse([16*K,y*K,56*K,(y+40)*K],fill=(200,205,212))
        d.rounded_rectangle([66*K,(y+4)*K,216*K,(y+14)*K],radius=4*K,fill=(210,214,220))
        d.rounded_rectangle([66*K,(y+22)*K,366*K,(y+32)*K],radius=4*K,fill=(228,231,235))
    d.ellipse([20*K,69*K,60*K,109*K],fill=(160,170,180))
    d.line([0,116*K,SW*K,116*K],fill=(232,235,238),width=K)
    d.text((140*K,128*K),'추천',font=f13,fill=(15,20,25)); d.text((262*K,128*K),'팔로우 중',font=f13,fill=(110,118,125))
    d.rectangle([128*K,156*K,170*K,159*K],fill=ACC); d.line([0,160*K,SW*K,160*K],fill=(215,219,223),width=K)
    d.text((38*K,19*K),'10:13',font=f15,fill=(0,0,0))
    d.rounded_rectangle([372*K,22*K,397*K,34*K],radius=3*K,outline=(0,0,0),width=K); d.rectangle([374*K,24*K,390*K,32*K],fill=(0,0,0))
    return c
BG=np.asarray(background(),np.float32)
# ------------------------------------------------------------ pose drawing
def pose_map(name,X,st):
    """artwork pixel -> canvas pixel for a pose standing on the floor at X, with the
    jelly controls in st: squash, shear, tail, ears, breath"""
    p=P.P[name]; fx,fy=p['foot']; Hpx=p['size'][1]
    sy=st.get('squash',1.0)*(1+st.get('breath',0)); sx=1/math.sqrt(max(sy,0.2))
    shear=st.get('shear',0); tail=st.get('tail',0); ears=st.get('ears',0)
    def m(px,py):
        dx=(px-fx); dy=(py-fy)
        if name in ('stand','standBody') and tail:
            w=ss((96-px)/80)*ss((py-200)/30)          # the tail, swinging about its root
            if w>0:
                bx,by=96-fx,262-fy; a=tail*w; c,s_=math.cos(a),math.sin(a); rx,ry=dx-bx,dy-by
                dx,dy=bx+c*rx-s_*ry,by+s_*rx+c*ry
        if name=='prone' and tail:
            w=ss((px-190)/90)
            if w>0:
                bx,by=190-fx,100-fy; a=-tail*w; c,s_=math.cos(a),math.sin(a); rx,ry=dx-bx,dy-by
                dx,dy=bx+c*rx-s_*ry,by+s_*rx+c*ry
        if name in ('stand','standBody') and ears:
            w=ss((96-py)/70)
            if w>0:
                side=-1 if px<110 else 1; bx,by=(66 if side<0 else 150)-fx,96-fy
                a=ears*side*w; c,s_=math.cos(a),math.sin(a); rx,ry=dx-bx,dy-by
                dx,dy=bx+c*rx-s_*ry,by+s_*rx+c*ry
        h=max(0,-dy)/Hpx
        wx=X+dx*KP*sx+shear*(h**1.4)*Hpx*KP
        wy=FLOOR+dy*KP*sy
        return (wx*K,wy*K)
    return m
def draw_pose(arr,name,X,st,alpha=1.0):
    src=P.P[name]['img'] if alpha>=0.999 else P.P[name]['img']*np.array([1,1,1,alpha],np.float32)
    warp(arr,src,pose_map(name,X,st))
def draw_arm(arr,X,st,arm):
    body=pose_map('standBody',X,st); pv=P.P['arm']['pivot']; A=body(*pv)
    th=arm['angle']; stretch=1+arm['stretch']; wig=arm['wiggle']
    def m(px,py):
        vx,vy=(px-pv[0])*KP*K*stretch,(py-pv[1])*KP*K*stretch
        d=math.hypot(vx,vy)/(45*KP*K); a=th+wig*min(1,d)
        c,s_=math.cos(a),math.sin(a); return (A[0]+c*vx-s_*vy,A[1]+s_*vx+c*vy)
    warp(arr,P.P['arm']['img'],m,rows=10,cols=10)
    return m
def eyelid(d,name,X,st,amount):
    """closes the eye from the top: a black lid over the eye hole"""
    if amount<=0.01: return
    box={'stand':(124,111,170,144),'prone':(94,96,119,119)}[name]
    m=pose_map(name,X,st); x0,y0,x1,y1=box; yb=y0+(y1-y0)*min(1,amount)
    d.polygon([m(x0,y0-1),m(x1,y0-1),m(x1,yb),m(x0,yb)],fill=(0,0,0,255))
def contour_world(name,X,sx=1.0,sy=1.0,dy0=0.0):
    p=P.P[name]; fx,fy=p['foot']
    return [((X+(px-fx)*KP*sx)*K,(FLOOR+dy0+(py-fy)*KP*sy)*K) for px,py in p['contour']]
def mix(a,b,t): return [(lerp(p[0],q[0],t),lerp(p[1],q[1],t)) for p,q in zip(a,b)]
def poly_layer(arr,pts,alpha=1.0):
    if alpha<=0 or not pts: return
    m=Image.new('L',(arr.shape[1],arr.shape[0]),0); ImageDraw.Draw(m).polygon(pts,fill=int(255*alpha))
    a=np.asarray(m.filter(ImageFilter.GaussianBlur(0.6)),np.float32)[...,None]/255
    arr[...,:3]*=(1-a); arr[...,3:4]=np.maximum(arr[...,3:4],a*255)
def circle(cx,cy,r,n=24): return [((cx+r*math.cos(t))*K,(cy+r*math.sin(t))*K) for t in [i/n*2*math.pi for i in range(n)]]
# ------------------------------------------------------------ the story
SEG=[('wait',0.5),('drip',0.55),('fall',None),('splat',0.42),('rise',0.6),('idle',1.4),('wave',2.3),('idle2',0.5),
     ('lie',0.55),('rest',1.6),('absorb',1.35),('return',1.15),('end',0.6)]
CAP={'drip':'아일랜드에서 한 방울','fall':'슬라임 공으로 떨어져서','splat':'탭 위에 납작하게 철퍽','rise':'웅덩이에서 전신으로 일어서기',
     'idle':'숨쉬기 · 깜빡 · 꼬리 살랑','wave':'팔을 쭉 늘려 손 흔들기','idle2':'','lie':'엎드리기','rest':'엎드려서 꼬리 살랑','absorb':'녹아서 흡수',
     'return':'아일랜드로 쭈욱 돌아가기','end':''}
out_dir=S+'/v4frames'; os.makedirs(out_dir,exist_ok=True)
for f in os.listdir(out_dir): os.remove(out_dir+'/'+f)
dt=1/60; clock=0; step=0; fi=0; seg=0; t=0
sq=1.0; sv=0.0; ballY=0; ballV=0; drops=[]
arm=dict(angle=0.0,stretch=0.0,wiggle=0.0); armv=[0.0,0.0]; blinkT=-9; nextBlink=0.9
pill=meniscus.Pill(IX0,IX1,ITOP,IBOT)
while seg<len(SEG):
    name,dur=SEG[seg]; t+=dt; clock+=dt
    arr=BG.copy(); layers=[]   # polygons drawn after images: (pts, alpha)
    st=dict(breath=math.sin(clock*2.6)*0.012,tail=0.0,ears=0.0,shear=0.0,squash=sq)
    draw_islands=[]
    if name=='drip':
        e=ss(t,0,dur); w=lerp(10,16,e); L=lerp(1,17,eout(t/dur)); R=lerp(1,8.6,e)
        pts=[((X0+x)*K,(IBOT-4+y)*K) for x,y in goo.drop(w,lerp(3,2,e),L,R)]
        layers.append((pts,1))
        gw=[(x/K,y/K) for x,y in pts]
        for pl in meniscus.junction([gw[0]]+gw[:-41:-1],gw[23:63],pill,0.4): layers.append(([(x*K,y*K) for x,y in pl],1))
        ballY=IBOT+L-2*R-4; ballV=0
    elif name=='fall':
        ballV+=1700*dt; ballY+=ballV*dt
        bh=P.P['ball']['size'][1]*KP; stretch=1+min(0.22,ballV*0.0007)
        top=ballY; bottom=top+bh*stretch
        layers.append((contour_world('ball',X0,1/math.sqrt(stretch),stretch,dy0=bottom-FLOOR),1))
        r=max(0,1-t/0.25)          # the neck it left behind pulls back up
        if r>0:
            pts=[((X0+x)*K,(IBOT-4+y)*K) for x,y in goo.drop(lerp(6,14,r),lerp(0.6,2,r),14*r*r+0.5,lerp(1,3,r))]; layers.append((pts,1))
        d=ImageDraw.Draw(Image.new('L',(1,1)))
        for j,ox in enumerate((-5,0,5)):   # speed lines, like the artwork
            y0=top-8-j%2*3; layers.append(([((X0+ox-0.6)*K,(y0-9)*K),((X0+ox+0.6)*K,(y0-9)*K),((X0+ox+0.6)*K,y0*K),((X0+ox-0.6)*K,y0*K)],0.85))
        if bottom>=FLOOR:
            dur=t; SEG[seg]=(name,dur)
            for v in ((-60,-150,1.6),(70,-190,1.4),(-15,-210,1.1)): drops.append([X0+v[0]*0.05,FLOOR-6,v[0],v[1],v[2]])
    elif name=='splat':
        if t<0.12: layers.append((mix(contour_world('ball',X0,1.15,0.8),contour_world('splat',X0),ss(t,0,0.12)),1))
        else:
            e=ss(t,0.12,dur); wob=1+0.08*math.exp(-(t-0.12)*9)*math.sin((t-0.12)*30)
            layers.append((mix(contour_world('splat',X0),contour_world('flat2',X0,wob,1/wob),e),1))
    elif name=='rise':
        e=ss(t,0,dur)
        a=contour_world('flat2',X0); b=contour_world('stand',X0,0.94,1.12)
        layers.append((mix(a,b,eout(t/dur)),1-ss(t,dur*0.65,dur)))
        if t>dur*0.6:
            st['squash']=1.12; draw_pose(arr,'stand',X0,st,ss(t,dur*0.6,dur))
        if t+dt>=dur: sq=1.12; sv=0
    elif name in ('idle','wave','idle2'):
        sv+=(140*(1-sq)-8*sv)*dt; sq+=sv*dt; st['squash']=sq
        st['tail']=0.16*math.sin(clock*2.3); st['ears']=0.05*math.sin(clock*1.7)*(1 if (clock%4)<1.2 else 0)
        st['shear']=0.025*math.sin(clock*1.9)
        if name=='wave':
            up=1 if t<dur-0.45 else 0
            tgt_a=-2.25*up; tgt_s=0.55*up
            armv[0]+=(150*(tgt_a-arm['angle'])-11*armv[0])*dt; arm['angle']+=armv[0]*dt
            armv[1]+=(150*(tgt_s-arm['stretch'])-11*armv[1])*dt; arm['stretch']+=armv[1]*dt
            arm['wiggle']=0.38*math.sin(clock*15)*up*ss(t,0.3,0.6)
        else:
            armv[0]+=(150*(0-arm['angle'])-11*armv[0])*dt; arm['angle']+=armv[0]*dt
            armv[1]+=(150*(0-arm['stretch'])-11*armv[1])*dt; arm['stretch']+=armv[1]*dt; arm['wiggle']=0
        draw_pose(arr,'standBody',X0,st)
        am=draw_arm(arr,X0,st,arm)
        if name=='wave' and t>0.35 and t<dur-0.45:
            px,py=am(198,250); px/=K; py/=K
            for j,r in enumerate((5,8.5)):
                a0=-60+20*math.sin(clock*15)
                layers.append(('arc',(px,py,r,a0),1))
        if clock>nextBlink: blinkT=clock; nextBlink=clock+random.uniform(1.5,3.2)
        bl=math.sin((clock-blinkT)/0.16*math.pi) if 0<=clock-blinkT<0.16 else 0
        layers.append(('lid',('stand',st,bl),1))
    elif name=='lie':
        a=contour_world('stand',X0,1/math.sqrt(sq),sq); b=contour_world('prone',X0,1.12,0.8)
        e=ss(t,0,dur); layers.append((mix(a,b,e),1))
        if t<0.15: draw_pose(arr,'stand',X0,dict(st,squash=sq),1-ss(t,0,0.15))
        if t>dur*0.6: draw_pose(arr,'prone',X0,dict(st,squash=0.8),ss(t,dur*0.6,dur))
        if t+dt>=dur: sq=0.8; sv=0
    elif name=='rest':
        sv+=(120*(1-sq)-7*sv)*dt; sq+=sv*dt
        draw_pose(arr,'prone',X0,dict(st,squash=sq,tail=0.22*math.sin(clock*2.1),breath=math.sin(clock*1.9)*0.03))
        slow=0.55+0.45*math.sin(clock*1.2)**8                     # sleepy, heavy lids
        layers.append(('lid',('prone',dict(st,squash=sq,breath=math.sin(clock*1.9)*0.03),slow*0.7),1))
    elif name=='absorb':
        k1,k2=0.45,0.9
        if t<k1:
            e=ss(t,0,k1); layers.append((mix(contour_world('prone',X0),contour_world('absorb1',X0),e),1))
            if t<0.12: draw_pose(arr,'prone',X0,dict(st,squash=sq),1-ss(t,0,0.12))
        elif t<k2:
            e=ss(t,k1,k2); layers.append((mix(contour_world('absorb1',X0),contour_world('blob',X0),e),1))
            if abs(t-k1-0.18)<dt/2:
                for v in ((-40,-120,1.5),(50,-110,1.3)): drops.append([X0+v[0]*0.06,FLOOR-10,v[0],v[1],v[2]])
        else:
            e=ss(t,k2,dur); layers.append((mix(contour_world('blob',X0),contour_world('flat',X0),e),1))
    elif name=='return':
        sh=1-ss(t,0.25,0.95); w=max(0.15,sh)
        layers.append((contour_world('flat',X0,w,max(0.25,sh)),1))
        tip=lerp(IBOT,FLOOR-3,ss(t,0,0.25)) if t<0.95 else lerp(FLOOR-3,IBOT,ss(t,0.95,dur))
        wid=lerp(1.4,2.6,math.sin(min(1,t/dur)*math.pi))
        layers.append(([((X0-wid*1.6)*K,(IBOT-2)*K),((X0+wid*1.6)*K,(IBOT-2)*K),((X0+wid)*K,tip*K),((X0-wid)*K,tip*K)],1))
        if 0.25<t<0.98:
            by=lerp(FLOOR-6,IBOT+2,ss(t,0.3,0.98)); br=lerp(5.5,3.5,ss(t,0.3,0.98))
            layers.append((circle(X0,by,br),1))
        layers.append(([((X0-8)*K,(IBOT-1)*K),((X0+8)*K,(IBOT-1)*K),((X0+wid)*K,(IBOT+6)*K),((X0-wid)*K,(IBOT+6)*K)],1))
    # droplets
    for dp in drops: dp[3]+=1400*dt; dp[0]+=dp[2]*dt; dp[1]+=dp[3]*dt
    drops=[dp for dp in drops if dp[1]<FLOOR-1]
    for dp in drops: layers.append((circle(dp[0],dp[1],dp[4]),1))
    if step%2==0:
        for item in layers:
            if item[0]=='lid':
                img=Image.new('RGBA',(arr.shape[1],arr.shape[0]),(0,0,0,0)); dd=ImageDraw.Draw(img); n_,st_,amt=item[1]
                eyelid(dd,n_,X0,st_,amt); a=np.asarray(img,np.float32)[...,3:4]/255; arr[...,:3]*=(1-a)
            elif item[0]=='arc':
                px,py,r,a0=item[1]; img=Image.new('L',(arr.shape[1],arr.shape[0]),0)
                ImageDraw.Draw(img).arc([(px-r)*K,(py-r)*K,(px+r)*K,(py+r)*K],a0-35,a0+35,fill=255,width=int(1.3*K))
                a=np.asarray(img,np.float32)[...,None]/255; arr[...,:3]*=(1-a)
            else: poly_layer(arr,item[0],item[1])
        im=Image.fromarray(arr.clip(0,255).astype(np.uint8),'RGBA'); d=ImageDraw.Draw(im)
        d.rounded_rectangle([IX0*K,ITOP*K,IX1*K,IBOT*K],radius=IH/2*K,fill=(0,0,0))
        cap=CAP.get(name,'')
        if cap:
            tw=d.textlength(cap,font=f13)
            d.rounded_rectangle([(SW*K-tw)/2-10*K,(SH-30)*K,(SW*K+tw)/2+10*K,(SH-8)*K],radius=10*K,fill=(20,24,28))
            d.text(((SW*K-tw)/2,(SH-26)*K),cap,font=f13,fill=(255,255,255))
        im.convert('RGB').save(f'{out_dir}/f{fi:05d}.png'); fi+=1
    step+=1
    if dur is not None and t>=dur: seg+=1; t=0
print(fi,'frames')
