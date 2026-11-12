import sys,math,random,os
B,S=sys.argv[1],sys.argv[2]
sys.path.insert(0,S)
from rig3 import Rig
import goo; goo.load(S)
import meniscus, json
EDGES=json.load(open(S+'/edges.json'))
from PIL import Image, ImageDraw, ImageFont
random.seed(5)
R=Rig(B,S); K=2
SW,SH=440,260; safeTop=62; IH=37; ITOP=14; IBOT=ITOP+IH; TUCK=5; FLOOR=160
FONT='/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc'
f13=ImageFont.truetype(FONT,13*K); f11=ImageFont.truetype(FONT,11*K); f15=ImageFont.truetype(FONT,15*K); fz=ImageFont.truetype(FONT,10*K)
ACC=(29,161,242)
def ss(x,a,b): t=max(0,min(1,(x-a)/(b-a))); return t*t*(3-2*t)
def lerp(a,b,t): return a+(b-a)*t
# ---------------- scene state
st=dict(mode='hidden',mt=0,spot='center',mir=False,iw=126,music=False,bubble=None,caption='',
        stretch=1.0,svel=0.0,blinkT=-9,nextBlink=1.5,dbl=False,talkUntil=-1,
        climb=None,fall=None,particles=[],anchor=(SW/2,IBOT-TUCK),rootDir=(0,1))
def IX0(): return SW/2-st['iw']/2
def IX1(): return SW/2+st['iw']/2
def spotX(): return SW/2 if st['spot']=='center' else IX0()+34
# ---------------- timeline
TL=[]
def at(t,fn): TL.append((t,fn))
def emerge(spot,mir):
    def f(t): st.update(spot=spot,mir=mir,mode='in',mt=0)
    return f
def setv(**kw):
    def f(t): st.update(**kw)
    return f
def expr(e,cap=None):
    def f(t):
        R.expr=e
        if cap is not None: st['caption']=cap
    return f
def bubble(text,dur,e='surprised',phone=0.0,talk=1.0):
    def f(t):
        st['bubble']=(text,t,t+dur); R.expr=e; R.phoneWanted=phone; st['talkUntil']=t+talk; st['svel']+=1.0
    return f
def wave(on):
    def f(t): R.wave=1.0 if on else 0.0
    return f
def climb(side_caption):
    def f(t): st.update(mode='climb',climb=dict(t0=t,go=2.0,hold=1.5,back=1.2)); st['caption']=side_caption; R.phoneWanted=0
    return f
def fall(t):
    st.update(mode='fall',fall=dict(t0=t,landed=None,thread=None)); st['caption']='뚝 떨어져서 바닥에 누웠다가 → 점액 실로 다시 합체'
def retract(t): st.update(mode='out',mt=0)
at(0.3,emerge('center',False)); at(0.3,setv(caption='등장: 퍼짐 → 모임 → 늘어남 → 변형 → 출렁 (이음새는 둥글게)'))
at(1.9,expr('happy','인사: 팔을 쭉 늘려서 손 흔들기')); at(1.9,wave(True)); at(4.1,wave(False)); at(4.3,expr('normal',''))
TL.append((4.6,lambda t: (setattr(R,'phoneWanted',1.0), st.update(caption='폰 꺼내기'))))
at(6.0,bubble('새 트윗 3건',2.0)); at(6.0,setv(caption='알림: 놀람 + 폰 집어넣기 + 말하기 (말풍선은 바라보는 쪽)'))
at(8.0,setv(bubble=None)); at(8.0,expr('normal',''))
at(8.4,expr('sleepy','새 표정: 졸림')); at(10.6,expr('normal',''))
at(11.0,retract); at(11.0,setv(caption='쏙 들어갔다가 왼쪽 끝에서 다시 나오기'))
TL.append((11.7,lambda t: st.update(spot='end',mir=False,mode='in',mt=0)))
at(14.6,retract)
at(14.8,setv(music=True,caption='음악 재생 중: 가운데로 옮겨 리듬 타기'))
TL.append((15.3,lambda t: st.update(spot='center',mir=False,mode='in',mt=0)))
at(16.6,bubble('♪ 夜に駆ける — YOASOBI',2.2,e='happy',phone=0.0,talk=0.6))
at(19.4,setv(music=False,caption=''))
T=20.2

# ---------------- drawing helpers
def background(c,d):
    for i in range(4):
        y=safeTop+108+i*62
        d.ellipse([16*K,y*K,56*K,(y+40)*K],fill=(200,205,212))
        d.rounded_rectangle([66*K,(y+4)*K,216*K,(y+14)*K],radius=4*K,fill=(210,214,220))
        d.rounded_rectangle([66*K,(y+22)*K,366*K,(y+32)*K],radius=4*K,fill=(228,231,235))
    ny=safeTop
    d.ellipse([20*K,(ny+7)*K,60*K,(ny+47)*K],fill=(160,170,180))
    d.text((140*K,(ny+66)*K),'추천',font=f13,fill=(15,20,25)); d.text((262*K,(ny+66)*K),'팔로우 중',font=f13,fill=(110,118,125))
    d.rectangle([128*K,(ny+94)*K,170*K,(ny+97)*K],fill=ACC)
    d.line([0,FLOOR*K,SW*K,FLOOR*K],fill=(215,219,223),width=K)
    d.text((38*K,19*K),'10:13',font=f15,fill=(0,0,0))
    d.rounded_rectangle([372*K,22*K,397*K,34*K],radius=3*K,outline=(0,0,0),width=K); d.rectangle([374*K,24*K,390*K,32*K],fill=(0,0,0))
def island(d,clock):
    d.rounded_rectangle([IX0()*K,ITOP*K,IX1()*K,IBOT*K],radius=IH/2*K,fill=(0,0,0))
    if st['iw']>170:   # now playing, compact
        a=min(1,(st['iw']-170)/50)
        d.rounded_rectangle([(IX0()+9)*K,(ITOP+8)*K,(IX0()+30)*K,(ITOP+29)*K],radius=5*K,fill=(int(230*a),int(90*a),int(140*a)))
        for j in range(4):
            hgt=4+6*abs(math.sin(clock*6+j*1.3))
            x=IX1()-30+j*5; d.rounded_rectangle([x*K,(ITOP+IH/2-hgt/2)*K,(x+3)*K,(ITOP+IH/2+hgt/2)*K],radius=K,fill=(int(240*a),int(110*a),int(160*a)))
def fillet(d,xl,xr,y,f):
    for side,ex in ((-1,xl),(1,xr)):
        pts=[(ex+side*f*(1-math.sin(t/12*math.pi/2)),y+f*(1-math.cos(t/12*math.pi/2))) for t in range(13)]
        poly=[(ex,y-6),(ex+side*f,y-6)]+pts[::-1]+[(ex,y+f)]
        d.polygon([(x*K,yy*K) for x,yy in poly],fill=(0,0,0,255))
def draw_bubble(c,text,head,side,age):
    d=ImageDraw.Draw(c); tw=d.textlength(text,font=f13)/K; w=tw+24; h=30
    pop=min(1,age/0.18); s=0.6+0.4*(1-(1-pop)**3)+0.06*math.sin(min(1,age/0.35)*math.pi)
    if side>0: x0=head[0]+36; tail=[(x0+2,head[1]-5),(x0-9,head[1]+2),(x0+2,head[1]+5)]; cx=x0
    else: x0=head[0]-36-w; tail=[(x0+w-2,head[1]-5),(x0+w+9,head[1]+2),(x0+w-2,head[1]+5)]; cx=x0+w
    y0=head[1]-h/2; lay=Image.new('RGBA',c.size,(0,0,0,0)); dd=ImageDraw.Draw(lay)
    dd.rounded_rectangle([x0*K,y0*K,(x0+w)*K,(y0+h)*K],radius=h/2*K,fill=ACC+(255,)); dd.polygon([(x*K,y*K) for x,y in tail],fill=ACC+(255,))
    dd.text(((x0+12)*K,(y0+7)*K),text,font=f13,fill=(255,255,255))
    cx*=K; cy=head[1]*K
    lay=lay.transform(lay.size,Image.AFFINE,(1/s,0,cx-cx/s,0,1/s,cy-cy/s),resample=Image.BILINEAR); c.alpha_composite(lay)
def star(x,y,r,rot):
    return [((x+(r if i%2==0 else r*0.45)*math.cos(rot+i*math.pi/5))*K,(y+(r if i%2==0 else r*0.45)*math.sin(rot+i*math.pi/5))*K) for i in range(10)]
def anger(d,x,y,r):
    # the cartoon vein mark: four bent strokes, each corner bowing toward the middle
    for j in range(4):
        a=j*math.pi/2+math.pi/4; cx,cy=x+r*math.cos(a),y+r*math.sin(a)
        pts=[]
        for k in range(9):
            b=a+math.pi*0.75+k/8*math.pi*0.5
            pts.append(((cx+r*0.75*math.cos(b))*K,(cy+r*0.75*math.sin(b))*K))
        d.line(pts,fill=(230,40,40,255),width=int(1.4*K),joint='curve')
def heart_poly(x,y,sz):
    out=[]
    for i in range(30):
        t=i/30*2*math.pi; hx=16*math.sin(t)**3; hy=-(13*math.cos(t)-5*math.cos(2*t)-2*math.cos(3*t)-math.cos(4*t))
        out.append(((x+hx*sz/32)*K,(y+hy*sz/32)*K))
    return out
# ---------------- loop
frames_dir=S+'/vAframes'; os.makedirs(frames_dir,exist_ok=True)
for f in os.listdir(frames_dir): os.remove(frames_dir+'/'+f)
dt=1/60; t=0; clock=0; fi=0; step=0
fired=set()
while t<T:
    for i,(et,fn) in enumerate(TL):
        if i not in fired and t>=et: fired.add(i); fn(t)
    clock+=dt; st['mt']+=dt
    st['iw']+=((230 if st['music'] else 126)-st['iw'])*min(1,dt*7)
    mode=st['mode']
    # ---- what the body does this frame (in the simulation frame: facing left, the left end)
    anchor=(spotX(),IBOT-TUCK); rootDir=(0,1); gscale=1; stiff=1; free=False; floor=None; bob=0; breeze=60
    goo_pts=None; goo_x=None; thread=None
    if mode=='in':
        if st['mt']>=0:
            goo_pts,done=goo.emerge_shape(st['mt']); goo_x=SW/2+(spotX()-SW/2)*goo.emerge_slide(st['mt'])
            if done:
                st.update(mode='rig',stretch=1.15,svel=0); R.ready=False; R.expr='surprised' if R.expr=='normal' else R.expr
                st['nextBlink']=t+0.8; mode='rig'
    elif mode=='out':
        goo_pts,done=goo.retract_shape(st['mt']); goo_x=SW/2+(spotX()-SW/2)*goo.retract_slide(st['mt'])
        if done: st['mode']='hidden'; mode='hidden'
    if mode=='climb':
        c=st['climb']; u=t-c['t0']; Rr=IH/2; cx=IX0()+Rr; cy=ITOP+Rr; sx=spotX()
        LA=abs(sx-cx); th1=math.radians(212); LB=(Rr-TUCK)*(th1-math.pi/2); tot=LA+LB
        if u<c['go']: p=ss(u,0,c['go'])
        elif u<c['go']+c['hold']: p=1.0
        elif u<c['go']+c['hold']+c['back']: p=1-ss(u-c['go']-c['hold'],0,c['back'])
        else: p=0; st['mode']='rig'; mode='rig'; st['caption']=''
        dist=p*tot
        if dist<=LA: anchor=(sx-dist,IBOT-TUCK); th=math.pi/2
        else:
            th=math.pi/2+(dist-LA)/(Rr-TUCK); anchor=(cx+(Rr-TUCK)*math.cos(th),cy+(Rr-TUCK)*math.sin(th))
        rootDir=(math.cos(th),math.sin(th)); k=ss(math.degrees(th),110,170); gscale=1-0.8*k; stiff=1+2.2*k
        if c['go']<=u<c['go']+c['hold']: R.expr='curious'
        elif R.expr=='curious': R.expr='normal'
        if mode=='climb': mode='rig2'
    if mode=='fall':
        fl=st['fall']; u=t-fl['t0']; free=True; floor=FLOOR-20
        if fl['landed'] is None and R.pts[0][1]>=floor-0.5:
            fl['landed']=t; R.expr='dizzy'; st['svel']-=1.2
            for q in (R.prev[-1],R.prev[-2]): q[0]+=3.5   # tips over
        if fl['landed'] and t-fl['landed']>1.6 and fl['thread'] is None: fl['thread']=t
        if fl['thread'] is not None:
            v=t-fl['thread']; tip=R.pts[0]; grow=ss(v,0,0.45)
            top=(SW/2,IBOT-TUCK); thread=(top,(lerp(top[0],tip[0],grow),lerp(top[1],tip[1],grow)))
            if v>0.5:   # reel it in: the root rides the thread up, the body hangs under it
                if 'from' not in fl: fl['from']=tuple(R.pts[0])
                pull=ss(v,0.5,1.6); fr=fl['from']
                anchor=(lerp(fr[0],top[0],pull),lerp(fr[1],top[1],pull)); free=False; floor=None; rootDir=(0,1)
                thread=(top,anchor)
                if pull>=1:
                    st.update(mode='rig',spot='center',fall=None,stretch=1.2,svel=0); R.expr='happy'; st['caption']=''
                    thread=None; free=False; mode='rig'
                    TL.append((t+0.9,expr('normal')))
        if mode=='fall': mode='rig2'
    rig=None; head=None
    if mode in ('rig','rig2'):
        if st['music'] and st['mode']=='rig': bob=150*math.sin(clock*2*math.pi*1.6)
        st['svel']+=(130*(1-st['stretch'])-9*st['svel'])*dt; st['stretch']+=st['svel']*dt
        length=st['stretch']*(1+math.sin(clock*2.4)*0.012)
        R.simulate(dt,anchor,length,clock,rootDir,gscale,stiff,free,floor,breeze,bob)
        Bd=R.bands(); R.step_bones(Bd,dt); R.update_face(dt,clock)
        if t>st['nextBlink']: st['blinkT']=t; st['dbl']=random.random()<0.3; st['nextBlink']=t+random.uniform(2.0,4.5)
        bl=0
        for s0 in ((st['blinkT'],st['blinkT']+0.24) if st['dbl'] else (st['blinkT'],)):
            if 0<=t-s0<0.15: bl=max(bl,math.sin((t-s0)/0.15*math.pi))
        if R.expr=='sleepy': bl=0
        talk=abs(math.sin(t*15)) if t<st['talkUntil'] else 0
        if step%2==0:
            rig=Image.new('RGBA',(SW*K,SH*K),(0,0,0,0)); R.render(rig,K,Bd,bl,talk,clock)
            if st['mode']=='rig':
                rd=ImageDraw.Draw(rig); Le,Re=R.edges(Bd,EDGES)
                for poly in meniscus.junction(Le,Re,meniscus.Pill(IX0(),IX1(),ITOP,IBOT),min(1,abs(st['svel'])*0.8)):
                    rd.polygon([(x*K,y*K) for x,y in poly],fill=(0,0,0,255))
        head=R.head(Bd)
        # effects
        e=R.expr
        if step%2==0:
            if e=='sleepy' and random.random()<0.06: st['particles'].append(dict(k='z',x=head[0]-8,y=head[1]+6,vx=-8,vy=-14,age=0,life=1.6))
            if e=='love' and random.random()<0.08: st['particles'].append(dict(k='heart',x=head[0]+random.uniform(-10,10),y=head[1]+4,vx=random.uniform(-6,6),vy=-22,age=0,life=1.3))
            if e=='sad' and random.random()<0.07:
                P,_,_,_=R.body_xform(R.PIV['oval'][0],R.PIV['oval'][1]-3,Bd); st['particles'].append(dict(k='tear',x=P[0],y=P[1],vx=0,vy=10,age=0,life=0.9))
    # ---- particles
    for p in st['particles']:
        p['age']+=dt; p['x']+=p['vx']*dt; p['y']+=p['vy']*dt
        if p['k']=='tear': p['vy']+=200*dt
    st['particles']=[p for p in st['particles'] if p['age']<p['life']]
    if step%2==0:
        c=Image.new('RGBA',(SW*K,SH*K),(255,255,255,255)); d=ImageDraw.Draw(c); background(c,d)
        layer=Image.new('RGBA',c.size,(0,0,0,0))
        if rig is not None: layer.alpha_composite(rig)
        ld=ImageDraw.Draw(layer)
        if goo_pts is not None:
            gw=[(goo_x+x,IBOT-TUCK+y) for x,y in goo_pts]
            ld.polygon([(x*K,y*K) for x,y in gw],fill=(0,0,0,255))
            # the same liquid junction on the goo (laid out like the contour: root 0..23)
            gr=gw[23:23+40]; gl=[gw[0]]+gw[:-41:-1]
            for poly in meniscus.junction(gl,gr,meniscus.Pill(IX0(),IX1(),ITOP,IBOT),0.6):
                ld.polygon([(x*K,y*K) for x,y in poly],fill=(0,0,0,255))
        if thread is not None:
            (x0,y0),(x1,y1)=thread; ang=math.atan2(y1-y0,x1-x0); nx,ny=-math.sin(ang),math.cos(ang)
            ld.polygon([((x0+nx*4)*K,(y0+ny*4)*K),((x1+nx*1.5)*K,(y1+ny*1.5)*K),((x1-nx*1.5)*K,(y1-ny*1.5)*K),((x0-nx*4)*K,(y0-ny*4)*K)],fill=(0,0,0,255))
        # effects in the simulation frame
        for p in st['particles']:
            a=int(255*min(1,(p['life']-p['age'])/0.4))
            if p['k']=='z': ld.text((p['x']*K,p['y']*K),'z',font=fz,fill=(90,90,110,a))
            if p['k']=='heart': ld.polygon(heart_poly(p['x'],p['y'],7),fill=(255,80,120,a))
            if p['k']=='tear': ld.ellipse([(p['x']-1.6)*K,(p['y']-2.2)*K,(p['x']+1.6)*K,(p['y']+2.2)*K],fill=(90,170,255,a))
        if head is not None and R.expr=='dizzy':
            for j in range(3):
                an=clock*4+j*2.1; sx_=head[0]+14*math.cos(an); sy_=head[1]+10+5*math.sin(an)
                ld.polygon(star(sx_,sy_,3.4,clock*2+j),fill=(255,200,40,255))
        if head is not None and R.expr=='angry':
            pulse=1+0.15*abs(math.sin(clock*8)); anger(ld,head[0]+11,head[1]+14,4.2*pulse)
        if st['mir']: layer=layer.transpose(Image.FLIP_LEFT_RIGHT)
        c.alpha_composite(layer)
        d=ImageDraw.Draw(c); island(d,clock)
        b=st['bubble']
        if b and head is not None and t<b[2]:
            h=head if not st['mir'] else (SW-head[0],head[1])
            draw_bubble(c,b[0],h,1 if st['mir'] else -1,t-b[1])
        if st['caption']:
            tw=d.textlength(st['caption'],font=f13)
            d.rounded_rectangle([(SW*K-tw)/2-10*K,(SH-30)*K,(SW*K+tw)/2+10*K,(SH-8)*K],radius=10*K,fill=(20,24,28))
            d.text(((SW*K-tw)/2,(SH-26)*K),st['caption'],font=f13,fill=(255,255,255))
        c.convert('RGB').save(f'{frames_dir}/f{fi:05d}.png'); fi+=1
    t+=dt; step+=1
print(fi,'frames')
