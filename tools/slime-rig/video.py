import sys,math,random,os
B,S,OUT=sys.argv[1],sys.argv[2],sys.argv[3]
src=open(S+'/rig2.py').read(); src=src[:src.index('# ---------------- scenario')]
sys.argv=['rig2',B,S]; ns={'__name__':'rig2'}; exec(src,ns)
sys.path.insert(0,S); import goo; goo.load(S)
from PIL import Image, ImageDraw, ImageFont, ImageChops
g=ns; K=2                     # px per pt in the video
SW,SH=440,250                 # scene in pt: top of an iPhone screen
safeTop=62; islandW=126; islandH=37; islandTop=14; islandBottom=islandTop+islandH
IX0=SW/2-islandW/2; IX1=SW/2+islandW/2
font=ImageFont.truetype('/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',13*K)
small=ImageFont.truetype('/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',11*K)
ACC=(29,161,242)
def background(barShift):
    c=Image.new('RGBA',(SW*K,SH*K),(255,255,255,255)); d=ImageDraw.Draw(c)
    # timeline rows
    for i in range(4):
        y=safeTop+54-barShift*0.0+i*62+10
        d.ellipse([16*K,(y)*K,(16+40)*K,(y+40)*K],fill=(200,205,212))
        d.rounded_rectangle([66*K,(y+4)*K,(66+150)*K,(y+14)*K],radius=4*K,fill=(210,214,220))
        d.rounded_rectangle([66*K,(y+22)*K,(66+300)*K,(y+32)*K],radius=4*K,fill=(228,231,235))
    # nav bar (slides up when hidden)
    ny=safeTop-barShift
    d.rectangle([0,0,SW*K,(ny+54+44)*K],fill=(255,255,255,240))
    d.ellipse([20*K,(ny+7)*K,60*K,(ny+47)*K],fill=(160,170,180))
    d.text((140*K,(ny+66)*K),'추천',font=font,fill=(15,20,25)); d.text((262*K,(ny+66)*K),'팔로우 중',font=font,fill=(110,118,125))
    d.rectangle([128*K,(ny+94)*K,170*K,(ny+97)*K],fill=ACC)
    d.line([0,(ny+98)*K,SW*K,(ny+98)*K],fill=(230,233,236),width=K)
    d.text((40*K,20*K),'10:13',font=font,fill=(0,0,0))
    d.rounded_rectangle([370*K,22*K,394*K,33*K],radius=3*K,outline=(0,0,0),width=K)
    d.rectangle([372*K,24*K,388*K,31*K],fill=(0,0,0))
    return c
def island(c):
    ImageDraw.Draw(c).rounded_rectangle([IX0*K,islandTop*K,IX1*K,islandBottom*K],radius=islandH/2*K,fill=(0,0,0,255))
def clip(layer):
    m=Image.new('L',layer.size,0); ImageDraw.Draw(m).rectangle([0,(islandBottom-30)*K,layer.size[0],layer.size[1]],fill=255)
    layer.putalpha(ImageChops.multiply(layer.split()[3],m)); return layer
def mirror(layer,ax):
    l=layer.transpose(Image.FLIP_LEFT_RIGHT); out=Image.new('RGBA',layer.size,(0,0,0,0))
    out.paste(l,(int((2*ax-SW)*K),0)); return out
def bubble(c,text,head,side,age):
    d=ImageDraw.Draw(c); tw=d.textlength(text,font=font)/K
    w=tw+24; h=30; pop=min(1,age/0.18); s=0.6+0.4*(1-(1-pop)**3)+0.06*math.sin(min(1,age/0.35)*math.pi)
    if side>0: x0=head[0]+36; tail=[(x0+2,head[1]-5),(x0-9,head[1]+2),(x0+2,head[1]+5)]
    else: x0=head[0]-36-w; tail=[(x0+w-2,head[1]-5),(x0+w+9,head[1]+2),(x0+w-2,head[1]+5)]
    y0=head[1]-h/2
    lay=Image.new('RGBA',c.size,(0,0,0,0)); dd=ImageDraw.Draw(lay)
    dd.rounded_rectangle([x0*K,y0*K,(x0+w)*K,(y0+h)*K],radius=h/2*K,fill=ACC+(255,))
    dd.polygon([(x*K,y*K) for x,y in tail],fill=ACC+(255,))
    dd.text(((x0+12)*K,(y0+7)*K),text,font=font,fill=(255,255,255))
    # pop from the tail side
    cx=(x0 if side>0 else x0+w)*K; cy=head[1]*K
    lay=lay.transform(lay.size,Image.AFFINE,(1/s,0,cx-cx/s,0,1/s,cy-cy/s),resample=Image.BILINEAR)
    c.alpha_composite(lay)
# ---------- state
random.seed(7)
spots={'left':IX0+34,'center':SW/2,'right':IX1-34}
mode='hidden'; mt=0; spot='center'; nextSpot='center'
stretch=1.0; svel=0.0; clock=0
expr='normal'; exprUntil=0; talkUntil=-1; nextBlink=1.0; blinkT=-9; doubleBlink=False
bub=None
events={0.3:'out',3.2:'flick',4.0:'bubble1',6.1:'unbubble',7.0:'peek',9.6:'bubble2',11.4:'unbubble',12.0:'barhide',13.1:'barshow',14.6:'bubble3',16.4:'unbubble'}
barShift=0; barTarget=0; wantOut=False; pendingPeek=False
T=17.4; dt=1/60; t=0; fi=0
os.makedirs(S+'/vframes',exist_ok=True)
for f in os.listdir(S+'/vframes'): os.remove(S+'/vframes/'+f)
while t<T:
    for et,ev in events.items():
        if abs(t-et)<dt/2:
            if ev=='out': wantOut=True
            if ev=='flick': g['BY']['earLTip'].om+=10; g['BY']['earRBase'].om-=7; g['BY']['furC'].om+=8
            if ev=='bubble1': bub=('새 트윗 3건',t); expr='surprised'; exprUntil=t+1.8; talkUntil=t+1.1; svel+=1.0
            if ev=='bubble2': bub=('♪ 夜に駆ける — YOASOBI',t); expr='happy'; exprUntil=t+1.8; talkUntil=t+0.8; svel+=0.8
            if ev=='bubble3': bub=('새 알림 1건',t); expr='surprised'; exprUntil=t+1.6; talkUntil=t+1.0; svel+=1.0
            if ev=='unbubble': bub=None
            if ev=='peek': pendingPeek=True; nextSpot='left'
            if ev=='barhide': barTarget=98; wantOut=False; nextSpot='right'
            if ev=='barshow': barTarget=0; wantOut=True
    barShift+=(barTarget-barShift)*min(1,dt*9)
    # mode machine
    if mode=='hidden' and wantOut and not pendingPeek: mode='in'; mt=0; spot=nextSpot
    if mode=='rig' and (not wantOut or pendingPeek): mode='out'; mt=0
    if mode=='hidden' and pendingPeek: pendingPeek=False; mode='in'; mt=-0.2; spot=nextSpot
    mt+=dt; clock+=dt
    ax=spots[spot]; anchor=(ax,islandBottom-5)
    c=background(barShift)
    goo_pts=None; rig_layer=None; head=None
    if mode=='in':
        if mt>=0:
            goo_pts,done=goo.emerge_shape(mt)
            if done:
                mode='rig'; g['ready']=False; stretch=1.15; svel=0; expr='surprised'; exprUntil=t+0.7; nextBlink=t+0.9
                for b in g['BONES']: b.th=0;b.om=0;b.hist=[];b.pang=None
                g['ramp']=0
    elif mode=='out':
        goo_pts,done=goo.retract_shape(mt)
        if done: mode='hidden'
    if mode=='rig':
        svel+=(130*(1-stretch)-9*svel)*dt; stretch+=svel*dt
        length=stretch*(1+math.sin(clock*2.4)*0.012)
        g['simulate'](dt,anchor,length,clock); B_=g['bands'](1.0); g['step_bones'](B_,dt,0)
        if t>exprUntil and expr!='normal': expr='normal'
        tg=g['expr_targets'][expr]; face=g['face']
        for kk in ('oval','eyeScale','lid','mouth'): face[kk]+=(tg[kk]-face[kk])*min(1,dt*14)
        face['perk']+=(tg['perk']-face['perk'])*min(1,dt*8)
        g['BY']['earLBase'].target=-0.22*face['perk']; g['BY']['earRBase'].target=0.22*face['perk']
        ps=g['phoneSpring']; ps[1]+=(160*(tg['phone']-ps[0])-11*ps[1])*dt; ps[0]+=ps[1]*dt
        if t>nextBlink:
            blinkT=t; doubleBlink=random.random()<0.3; nextBlink=t+random.uniform(2.0,4.5)
        bl=0
        for start in ((blinkT,blinkT+0.24) if doubleBlink else (blinkT,)):
            if 0<=t-start<0.15: bl=max(bl,math.sin((t-start)/0.15*math.pi))
        talk=abs(math.sin(t*15)) if t<talkUntil else 0
        rig_layer=Image.new('RGBA',c.size,(0,0,0,0))
        # the rig draws in its own scene units: scale pt->px via ns.K
        g['K']=K; g['render'](B_,{},rig_layer,1,bl,talk)
        # a small fillet where the body meets the island
        fl=Image.new('RGBA',c.size,(0,0,0,0)); g['meniscus'](ImageDraw.Draw(fl),B_,islandBottom,1,3.5); rig_layer.alpha_composite(fl)
        P,_,_,_=g['body_xform'](30,0.62*g['H'],B_); head=(P[0],P[1])
    if goo_pts is not None:
        rig_layer=Image.new('RGBA',c.size,(0,0,0,0))
        slide=goo.emerge_slide(max(0,mt)) if mode=='in' else goo.retract_slide(mt)
        gx=SW/2+(ax-SW/2)*slide
        if spot=='right': gx=2*ax-gx   # undone by the mirror below
        ImageDraw.Draw(rig_layer).polygon([((gx+x)*K,(islandBottom-5+y)*K) for x,y in goo_pts],fill=(0,0,0,255))
    if rig_layer is not None:
        if spot=='right':
            rig_layer=mirror(rig_layer,ax)
            if head: head=(2*ax-head[0],head[1])
        c.alpha_composite(clip(rig_layer))
    island(c)
    if bub and head:
        bubble(c,bub[0],head,-1 if spot=='right' else 1,t-bub[1])
    ImageDraw.Draw(c).text((8*K,(SH-16)*K),f'{t:4.1f}s  {mode:6s} spot={spot:6s} expr={expr}',font=small,fill=(150,150,150))
    c.convert('RGB').save(f'{S}/vframes/f{fi:05d}.png'); fi+=1
    t+=dt
print(fi,'frames')
