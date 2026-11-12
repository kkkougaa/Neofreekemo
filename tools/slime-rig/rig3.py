"""Slime rig engine, draft v2. World units are points; images are the slime_*.png parts."""
import math,json,random
import numpy as np
from PIL import Image, ImageDraw, ImageFont
class Rig:
    PARTS=['base','paw','earLBase','earLTip','earRBase','earRTip','phone','lid','oval','mouth','furA','furB','furC','furD','furE','furF']
    def __init__(s,B,S):
        meta=json.load(open(S+'/slime_meta.json'))
        s.TW,s.TH=meta['size']; s.W=60.0; s.H=s.W*s.TH/s.TW; s.PXPT=s.TW/s.W
        s.IMG={n:Image.open(f'{B}/slime_{n}.png') for n in s.PARTS}
        s.PIV={k:(u*s.W,v*s.H) for k,(u,v) in meta['pivots'].items()}
        s.TIP={k:(u*s.W,v*s.H) for k,(u,v) in meta['tips'].items()}
        s.NB=14; s.bandH=s.H/s.NB; s.COLS=7
        s.SRC={n:np.asarray(s.IMG[n].convert('RGBA'),dtype=np.float32) for n in ('base',)}
        s.pts=[[0,0] for _ in range(s.NB+1)]; s.prev=[[0,0] for _ in range(s.NB+1)]; s.ready=False
        s.bones={}; s.order=[]
        def bone(n,parent,k,c,gain,limit):
            tx,ty=s.TIP[n][0]-s.PIV[n][0],s.TIP[n][1]-s.PIV[n][1]; L=max(math.hypot(tx,ty),1)
            s.bones[n]=dict(n=n,parent=parent,k=k,c=c,gain=gain,limit=limit,th=0.0,om=0.0,target=0.0,hist=[],pang=None,pom=0.0,L=L,dir=(tx/L,ty/L))
        bone('earLBase',None,140,10,0.5,0.4); bone('earLTip','earLBase',95,7,0.7,0.5)
        bone('earRBase',None,140,10,0.5,0.4); bone('earRTip','earRBase',95,7,0.7,0.5)
        for f in 'ABCDEF': bone('fur'+f,None,230,10,0.8,0.3)
        bone('phone',None,120,10,0.25,0.3); bone('paw',None,160,11,0.3,1.5)
        s.ramp=0
        # eye shapes, drawn where the eye is (upside down, like the character)
        oc=(0.5203*s.W,0.431*s.H)
        s.shapes={}
        def canvas(): return Image.new('RGBA',(s.TW,s.TH),(255,255,255,0))
        P=lambda x,y:((oc[0]+x)*s.PXPT,(oc[1]+y)*s.PXPT)
        im=canvas(); d=ImageDraw.Draw(im)   # heart, point up (the character is upside down)
        hp=[]
        for i in range(60):
            t=i/60*2*math.pi; x=16*math.sin(t)**3; y=-(13*math.cos(t)-5*math.cos(2*t)-2*math.cos(3*t)-math.cos(4*t))
            hp.append(P(x*0.33,-y*0.33))
        d.polygon(hp,fill=(255,255,255,255)); s.shapes['heart']=im
        im=canvas(); d=ImageDraw.Draw(im)   # spiral
        sp=[P(0.25*a*math.cos(a)*0.9,0.25*a*math.sin(a)*0.9) for a in [i*0.2 for i in range(85)]]
        d.line(sp,fill=(255,255,255,255),width=int(1.3*s.PXPT)); s.shapes['spiral']=im
        im=canvas(); d=ImageDraw.Draw(im)   # closed happy eye (an arc, upside down)
        ar=[P(4*math.cos(a),-2.6*math.sin(a)+1) for a in [math.pi*i/20 for i in range(21)]]
        d.line(ar,fill=(255,255,255,255),width=int(1.6*s.PXPT),joint='curve'); s.shapes['arc']=im
        s.PIV['heart']=s.PIV['spiral']=s.PIV['arc']=oc
        s.face=dict(oval=1.0,eyeScale=1.0,lid=0.0,lidRot=0.0,mouth=1.0,perk=0.0)
        s.EXPR={
         'normal':   dict(oval=1,eyeScale=1,lid=0,lidRot=0,mouth=1,perk=0,shape='oval'),
         'surprised':dict(oval=1,eyeScale=1.25,lid=1.6,lidRot=0,mouth=1.45,perk=1,shape='oval'),
         'happy':    dict(oval=1,eyeScale=1,lid=0.4,lidRot=0,mouth=1.3,perk=0.5,shape='arc'),
         'squint':   dict(oval=0.3,eyeScale=0.95,lid=-0.8,lidRot=0,mouth=0.75,perk=-1,shape='oval'),
         'sleepy':   dict(oval=0.2,eyeScale=1,lid=-1.1,lidRot=0.08,mouth=0.85,perk=-1.4,shape='oval'),
         'angry':    dict(oval=0.7,eyeScale=0.9,lid=-0.7,lidRot=0.6,mouth=1.25,perk=-0.9,shape='oval'),
         'sad':      dict(oval=0.85,eyeScale=1,lid=0.6,lidRot=-0.55,mouth=0.7,perk=-1.6,shape='oval'),
         'love':     dict(oval=1,eyeScale=1,lid=0.6,lidRot=0,mouth=1.2,perk=0.8,shape='heart'),
         'dizzy':    dict(oval=1,eyeScale=1,lid=0.3,lidRot=0.15,mouth=1.1,perk=-0.4,shape='spiral'),
         'curious':  dict(oval=1,eyeScale=1.12,lid=0.9,lidRot=-0.12,mouth=1.0,perk=1.2,shape='oval'),
        }
        s.expr='normal'; s.phone=[0.0,0.0]; s.phoneWanted=0.0; s.wave=0.0; s.arm=[0.0,0.0]
    # ------------------------------------------------------------- body
    def reset(s,anchor,length=1.0,rootDir=(0,1)):
        rest=s.bandH*length
        for i in range(s.NB+1): s.pts[i]=[anchor[0]+rootDir[0]*rest*i,anchor[1]+rootDir[1]*rest*i]; s.prev[i]=s.pts[i][:]
        for b in s.bones.values(): b.update(th=0.0,om=0.0,hist=[],pang=None,pom=0.0)
        s.ramp=0; s.ready=True
    def simulate(s,dt,anchor,length,clock,rootDir=(0,1),gscale=1.0,stiff=1.0,free=False,floor=None,breeze=60,bob=0.0):
        if not s.ready: s.reset(anchor,length,rootDir)
        rest=s.bandH*length; SUB=4; h=dt/SUB; NB=s.NB; P=s.pts; Q=s.prev
        for _ in range(SUB):
            if not free: P[0]=list(anchor); Q[0]=list(anchor)
            for i in range(0 if free else 1,NB+1):
                d=i/NB; wind=(math.sin(clock*1.3+d*0.9)+0.4*math.sin(clock*3.1))*breeze*d+bob*d
                p=P[i]; v=[(p[0]-Q[i][0])*0.985,(p[1]-Q[i][1])*0.985]
                if floor is not None and p[1]>=floor-0.5: v[0]*=0.9
                Q[i]=p[:]; P[i]=[p[0]+v[0]+wind*h*h, p[1]+v[1]+1400*gscale*h*h]
            for _ in range(3):
                for i in range(NB):
                    a,b=P[i],P[i+1]; dx,dy=b[0]-a[0],b[1]-a[1]; dist=max(math.hypot(dx,dy),1e-4)
                    push=(dist-rest)/dist*0.55
                    if i==0 and not free: P[1][0]-=dx*push; P[1][1]-=dy*push
                    else:
                        P[i][0]+=dx*push*.5; P[i][1]+=dy*push*.5; P[i+1][0]-=dx*push*.5; P[i+1][1]-=dy*push*.5
                    if i==0: par=rootDir if not free else (P[1][0]-P[0][0],P[1][1]-P[0][1])
                    else: par=(P[i][0]-P[i-1][0],P[i][1]-P[i-1][1])
                    pl=max(math.hypot(*par),1e-4)
                    want=(P[i][0]+par[0]/pl*rest, P[i][1]+par[1]/pl*rest); st=min(0.7,(0.24-0.14*(i/NB))*stiff)
                    P[i+1][0]+=(want[0]-P[i+1][0])*st; P[i+1][1]+=(want[1]-P[i+1][1])*st
                if floor is not None:
                    for i in range(NB+1):
                        if P[i][1]>floor: P[i][1]=floor
                if not free: P[0]=list(anchor)
    def bands(s,squeeze=1.0):
        out=[]
        for i in range(s.NB):
            a,b=s.pts[i],s.pts[i+1]; dx,dy=b[0]-a[0],b[1]-a[1]; dist=math.hypot(dx,dy); st=dist/s.bandH
            w=max(0.7,min(1.3,1/math.sqrt(max(st,0.05))))*squeeze
            if st<1: w=min(w,1.15*squeeze)
            out.append((a,math.atan2(-dx,dy),w,max(st,1e-3)))
        return out
    def joints(s,B):
        """per joint: position, unit tangent (down the body), width scale. Neighbouring
        bones share each joint, so the mesh built on them has no gaps."""
        NB=s.NB; d=[(-math.sin(b[1]),math.cos(b[1])) for b in B]
        J=[]
        for i in range(NB+1):
            P=B[i][0] if i<NB else s.pts[NB]
            if i==0: t=d[0]; w=B[0][2]
            elif i==NB: t=d[NB-1]; w=B[NB-1][2]
            else:
                t=(d[i-1][0]+d[i][0],d[i-1][1]+d[i][1]); l=math.hypot(*t) or 1; t=(t[0]/l,t[1]/l); w=(B[i-1][2]+B[i][2])/2
            J.append((tuple(P),t,w))
        return J
    def body_xform(s,u,v,B):
        J=s._J if getattr(s,'_Jkey',None) is B else s.joints(B)
        s._J=J; s._Jkey=B
        f=max(0.0,min(s.NB-1e-6,v/s.bandH)); i=int(f); t=f-i
        (P0,t0,w0),(P1,t1,w1)=J[i],J[i+1]
        tx,ty=t0[0]+(t1[0]-t0[0])*t,t0[1]+(t1[1]-t0[1])*t; l=math.hypot(tx,ty) or 1; tx,ty=tx/l,ty/l
        w=w0+(w1-w0)*t; ox=(u-s.W/2)
        n0=(t0[1]*w0,-t0[0]*w0); n1=(t1[1]*w1,-t1[0]*w1)
        nx=n0[0]+(n1[0]-n0[0])*t; ny=n0[1]+(n1[1]-n0[1])*t
        P=(P0[0]+(P1[0]-P0[0])*t+nx*ox, P0[1]+(P1[1]-P0[1])*t+ny*ox)
        return P,math.atan2(-tx,ty),w,B[i][3]
    # ------------------------------------------------------------- secondary bones
    def bone_world(s,n,B,cache):
        if n in cache: return cache[n]
        b=s.bones[n]
        if b['parent'] is None:
            P,ang,w,st=s.body_xform(*s.PIV[n],B); g=lambda z:max(0.8,min(1.25,math.sqrt(z))); sc=(g(w),g(st))
        else:
            pP,pang,psc=s.bone_world(b['parent'],B,cache)
            lx=(s.PIV[n][0]-s.PIV[b['parent']][0])*psc[0]; ly=(s.PIV[n][1]-s.PIV[b['parent']][1])*psc[1]
            c,sn=math.cos(pang),math.sin(pang); P=(pP[0]+c*lx-sn*ly,pP[1]+sn*lx+c*ly); ang=pang; sc=psc
        r=(P,ang+b['th'],sc); cache[n]=r; return r
    def step_bones(s,B,dt,quiet=False):
        if quiet:
            for b in s.bones.values(): b.update(th=b['th']*0.8,om=b['om']*0.5,hist=[],pang=None,pom=0.0)
            s.ramp=0; return
        s.ramp=min(1,s.ramp+dt/0.4); cache={}
        for n,b in s.bones.items():
            P,ang,sc=s.bone_world(n,B,cache); base=ang-b['th']
            b['hist'].append(P); b['hist']=b['hist'][-3:]; acc=(0,0)
            if len(b['hist'])==3:
                h=b['hist']; acc=((h[2][0]-2*h[1][0]+h[0][0])/dt/dt,(h[2][1]-2*h[1][1]+h[0][1])/dt/dt)
            pom=0 if b['pang'] is None else (base-b['pang'])/dt
            pal=max(-400,min(400,(pom-b['pom'])/dt)); b['pang']=base; b['pom']=pom
            acc=(max(-2500,min(2500,acc[0])),max(-2500,min(2500,acc[1])))
            c,sn=math.cos(base+b['th']),math.sin(base+b['th']); dx,dy=c*b['dir'][0]-sn*b['dir'][1],sn*b['dir'][0]+c*b['dir'][1]
            torque=(dx*acc[1]-dy*acc[0])/b['L']
            a=-b['k']*(b['th']-b['target'])-b['c']*b['om']-s.ramp*(b['gain']*torque*0.02+b['gain']*pal*0.02)
            b['om']+=a*dt; b['th']+=b['om']*dt; b['th']=max(-b['limit'],min(b['limit'],b['th']))
    # ------------------------------------------------------------- face & controls
    def update_face(s,dt,clock):
        tg=s.EXPR[s.expr]; f=s.face
        for k in ('oval','eyeScale','lid','lidRot','mouth'): f[k]+=(tg[k]-f[k])*min(1,dt*14)
        f['perk']+=(tg['perk']-f['perk'])*min(1,dt*8)
        s.bones['earLBase']['target']=-0.22*f['perk']; s.bones['earRBase']['target']=0.22*f['perk']
        s.bones['earLTip']['target']=-0.12*min(0,f['perk']); s.bones['earRTip']['target']=0.12*min(0,f['perk'])
        p=s.phone; p[1]+=(160*(s.phoneWanted-p[0])-11*p[1])*dt; p[0]+=p[1]*dt
        # waving: the arm stretches out like goo (spring, overshoots), the paw swings on it
        a=s.arm; a[1]+=(170*(s.wave-a[0])-12*a[1])*dt; a[0]+=a[1]*dt
        s.bones['paw']['target']=s.wave*(0.9*math.sin(clock*11)-0.5)
    # ------------------------------------------------------------- render
    def paste(s,canvas,K,img,piv,P,ang,sx,sy):
        px,py=piv; c,sn=math.cos(ang),math.sin(ang)
        a=c/sx/K; b=sn/sx/K; cc=px-(c*P[0]+sn*P[1])/sx
        d=-sn/sy/K; e=c/sy/K; f=py-(-sn*P[0]+c*P[1])/sy
        layer=img.transform(canvas.size,Image.AFFINE,tuple(v*s.PXPT for v in (a,b,cc,d,e,f)),resample=Image.BILINEAR)
        canvas.alpha_composite(layer)
    def render(s,canvas,K,B,blink,talk,clock):
        cache={}
        for n in ['phone','earLTip','earRTip','earLBase','earRBase','furA','furB','furC','furD','furE','furF']:
            P,ang,(sx,sy)=s.bone_world(n,B,cache)
            if n=='phone':
                o=s.phone[0]
                if o<0.12: continue
                k=0.35+0.65*max(0,min(1.15,o)); ang+=(1-o)*0.7; sx*=k; sy*=k
            if n.startswith('ear'): sy*=1+0.07*s.face['perk']*(1 if n.endswith('Base') else 0.5)
            s.paste(canvas,K,s.IMG[n],s.PIV[n],P,ang,sx,sy)
        s.warp(canvas,K,B)
        P,ang,(sx,sy)=s.bone_world('paw',B,cache)
        ext=max(0.0,s.arm[0])
        if ext>0.02:
            # the arm: a goo strand from the wrist out to where the paw has gone
            base=ang-s.bones['paw']['th']; tx,ty=s.TIP['paw'][0]-s.PIV['paw'][0],s.TIP['paw'][1]-s.PIV['paw'][1]
            l=math.hypot(tx,ty); base-=0.35   # reach out and a little down, clear of the island
            c,sn=math.cos(base),math.sin(base); ux,uy=(c*tx-sn*ty)/l,(sn*tx+c*ty)/l
            Q=(P[0]+ux*ext*25,P[1]+uy*ext*25)
            d=ImageDraw.Draw(canvas); nx,ny=-uy,ux; w0,w1=6.5,4.2
            d.polygon([((P[0]+nx*w0)*K,(P[1]+ny*w0)*K),((Q[0]+nx*w1)*K,(Q[1]+ny*w1)*K),((Q[0]-nx*w1)*K,(Q[1]-ny*w1)*K),((P[0]-nx*w0)*K,(P[1]-ny*w0)*K)],fill=(0,0,0,255))
            d.ellipse([(Q[0]-w1)*K,(Q[1]-w1)*K,(Q[0]+w1)*K,(Q[1]+w1)*K],fill=(0,0,0,255))
            P=Q
        s.paste(canvas,K,s.IMG['paw'],s.PIV['paw'],P,ang,sx,sy)
        f=s.face; shape=s.EXPR[s.expr]['shape']
        P,ang,w,st=s.body_xform(*s.PIV['lid'],B)
        s.paste(canvas,K,s.IMG['lid'],s.PIV['lid'],(P[0],P[1]+f['lid']*st),ang+f['lidRot'],w,st)
        if shape=='oval':
            P,ang,w,st=s.body_xform(*s.PIV['oval'],B)
            s.paste(canvas,K,s.IMG['oval'],s.PIV['oval'],P,ang,w*f['eyeScale'],st*f['eyeScale']*max(0.04,f['oval']*(1-blink)))
        else:
            P,ang,w,st=s.body_xform(*s.PIV[shape],B)
            extra=clock*5 if shape=='spiral' else 0; pulse=1+0.12*math.sin(clock*9) if shape=='heart' else 1
            s.paste(canvas,K,s.shapes[shape],s.PIV[shape],P,ang+extra,w*pulse,st*pulse*(1 if shape!='arc' else (1-0.5*blink)))
        P,ang,w,st=s.body_xform(*s.PIV['mouth'],B); m=0.78*f['mouth']*(1+0.3*talk)
        s.paste(canvas,K,s.IMG['mouth'],s.PIV['mouth'],P,ang,w*m,st*m)
    def outline(s,B,contour):
        """the character contour (canvas coords, x from the middle) carried by the bones"""
        out=[]
        for x,y in contour:
            P,_,_,_=s.body_xform(x+s.W/2,min(max(y,0.0),s.H-0.01),B)
            if y<0: P=(P[0],P[1]+y)
            out.append(P)
        return out
    def edges(s,B,table):
        """the body's left and right edges near the root (edges.json rows), carried by
        the spine; the paw's part of the edge follows the paw's own bone"""
        cache={}; pw=s.bone_world('paw',B,cache)
        def place(u,v,paw):
            if not paw:
                P,_,_,_=s.body_xform(u*s.W,v*s.H,B); return P
            (px,py),ang,(sx,sy)=pw; ox=(u*s.W-s.PIV['paw'][0])*sx; oy=(v*s.H-s.PIV['paw'][1])*sy
            c,sn=math.cos(ang),math.sin(ang); return (px+c*ox-sn*oy,py+sn*ox+c*oy)
        L=[place(r['l'],r['v'],r['lpaw']) for r in table if r]
        Rr=[place(r['r'],r['v'],r['rpaw']) for r in table if r]
        return L,Rr
    def warp(s,canvas,K,B):
        """the body picture on a mesh that follows the spine: COLS vertices across at
        every joint, two triangles per cell, sampled bilinearly"""
        src=s.SRC['base']; TH,TW=src.shape[:2]
        J=s.joints(B); s._J=J; s._Jkey=B
        cols=s.COLS; dst={}; srcv={}
        for i,(P,t,w) in enumerate(J):
            n=(t[1]*w,-t[0]*w)
            for j in range(cols):
                u=j/(cols-1); ox=(u-0.5)*s.W
                dst[i,j]=((P[0]+n[0]*ox)*K,(P[1]+n[1]*ox)*K); srcv[i,j]=(u*TW,min(i/s.NB,1)*TH)
        Wc,Hc=canvas.size; out=np.zeros((Hc,Wc,4),dtype=np.float32)
        for i in range(s.NB):
            for j in range(cols-1):
                for tri in (((i,j),(i,j+1),(i+1,j)),((i,j+1),(i+1,j+1),(i+1,j))):
                    D=np.array([dst[k] for k in tri]); Sv=np.array([srcv[k] for k in tri])
                    x0,y0=np.floor(D.min(0)).astype(int); x1,y1=np.ceil(D.max(0)).astype(int)
                    x0=max(x0,0); y0=max(y0,0); x1=min(x1,Wc-1); y1=min(y1,Hc-1)
                    if x1<x0 or y1<y0: continue
                    M=np.array([[D[0,0],D[1,0],D[2,0]],[D[0,1],D[1,1],D[2,1]],[1,1,1]])
                    try: Mi=np.linalg.inv(M)
                    except np.linalg.LinAlgError: continue
                    ys,xs=np.mgrid[y0:y1+1,x0:x1+1]; px=xs+0.5; py=ys+0.5
                    l=Mi@np.stack([px.ravel(),py.ravel(),np.ones(px.size)])
                    inside=(l>=-1e-4).all(0)
                    if not inside.any(): continue
                    sx=(Sv[:,0]@l)[inside]-0.5; sy=(Sv[:,1]@l)[inside]-0.5
                    sx=np.clip(sx,0,TW-1.001); sy=np.clip(sy,0,TH-1.001)
                    ix=sx.astype(int); iy=sy.astype(int); fx=(sx-ix)[:,None]; fy=(sy-iy)[:,None]
                    c=(src[iy,ix]*(1-fx)*(1-fy)+src[iy,ix+1]*fx*(1-fy)+src[iy+1,ix]*(1-fx)*fy+src[iy+1,ix+1]*fx*fy)
                    yy=ys.ravel()[inside]; xx=xs.ravel()[inside]
                    keep=c[:,3]>out[yy,xx,3]
                    out[yy[keep],xx[keep]]=c[keep]
        layer=Image.fromarray(out.clip(0,255).astype(np.uint8),'RGBA')
        canvas.alpha_composite(layer)
    def head(s,B,v=0.62):
        P,_,_,_=s.body_xform(30,v*s.H,B); return P
