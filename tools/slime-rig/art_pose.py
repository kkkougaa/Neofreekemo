"""Poses cut from 형's artwork: anti-aliased black silhouettes (cheek triangles filled),
outer contours for morphing, and a mesh warp to deform them."""
import pickle,math,collections
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
class Poses:
    FILL={'stand':[3],'prone':[3]}   # the cheek triangles
    def __init__(s,S):
        s.S=S; gray=np.asarray(Image.open(S+'/art.png').convert('L')).astype(np.float32)
        lab=np.load(S+'/art_lab.npy'); figs=pickle.load(open(S+'/art_figs.pkl','rb'))
        s.P={}
        for name in ['stand','prone','absorb1','blob','flat','ball','splat','flat2']:
            f=figs[name]; x0,y0,x1,y1=f['box']
            region=np.isin(lab[y0:y1,x0:x1],f['ids'])
            for i in s.FILL.get(name,[]):
                h=f['holes'][i]['pts']; region[h[:,0],h[:,1]]=True
            reg=Image.fromarray((region*255).astype(np.uint8)).filter(ImageFilter.MaxFilter(5))
            reg=np.asarray(reg)>0
            alpha=np.clip((255-gray[y0:y1,x0:x1])*1.15,0,255)*reg
            for i in s.FILL.get(name,[]):
                h=f['holes'][i]['pts']
                m=np.zeros(region.shape,bool); m[h[:,0],h[:,1]]=True
                m=np.asarray(Image.fromarray((m*255).astype(np.uint8)).filter(ImageFilter.MaxFilter(5)))>0
                alpha[m]=255
            img=np.zeros(alpha.shape+(4,),np.float32); img[...,3]=alpha
            main=np.isin(lab[y0:y1,x0:x1],[f['ids'][0]])
            for i in s.FILL.get(name,[]):
                h=f['holes'][i]['pts']; main[h[:,0],h[:,1]]=True
            ys,xs=np.nonzero(main); foot=(float(xs[ys>=ys.max()-3].mean()),float(ys.max()))
            s.P[name]=dict(img=img,main=main,foot=foot,holes=f['holes'],size=(x1-x0,y1-y0))
        # the right arm of the standing pose, as its own part (crop px)
        st=s.P['stand']
        arm_poly=[(175,200),(196,211),(207,228),(208,249),(197,259),(187,258),(183,241),(180,228),(175,214)]
        m=Image.new('L',(st['size'][0],st['size'][1]),0); ImageDraw.Draw(m).polygon(arm_poly,fill=255)
        m=np.asarray(m.filter(ImageFilter.GaussianBlur(0.8)),np.float32)/255
        arm=st['img'].copy(); arm[...,3]*=m; body=st['img'].copy(); body[...,3]*=(1-m)
        # the torso behind the arm, filled in, so lifting the arm never opens a gap
        t=Image.new('L',(st['size'][0],st['size'][1]),0); ImageDraw.Draw(t).polygon([(150,190),(177,199),(183,228),(189,257),(160,262)],fill=255)
        t=np.asarray(t.filter(ImageFilter.GaussianBlur(0.8)),np.float32)/255
        body[...,3]=np.maximum(body[...,3],255*t)
        s.P['standBody']=dict(st,img=body); s.P['arm']=dict(st,img=arm,pivot=(181,209))
        for name,p in s.P.items():
            if 'contour' not in p and name in ('stand','prone','absorb1','blob','flat','ball','splat','flat2'):
                p['contour']=s.contour(p['main'],p['foot'])
    def contour(s,mask,foot,N=180):
        m=np.pad(mask,1); H,W=m.shape
        ys,xs=np.nonzero(m); y0=ys.min(); x0=xs[ys==y0].min()
        dirs=[(1,0),(1,1),(0,1),(-1,1),(-1,0),(-1,-1),(0,-1),(1,-1)]
        cur=(x0,y0); back=4; path=[cur]
        for _ in range(400000):
            for k in range(8):
                d=(back+1+k)%8; nx,ny=cur[0]+dirs[d][0],cur[1]+dirs[d][1]
                if m[ny,nx]: back=(d+4)%8; cur=(nx,ny); break
            if cur==(x0,y0): break
            path.append(cur)
        pts=[(x-1,y-1) for x,y in path]
        # start at the bottom, nearest the foot, so every contour lines up the same way
        i0=min(range(len(pts)),key=lambda i:(abs(pts[i][1]-foot[1])*3+abs(pts[i][0]-foot[0])))
        pts=pts[i0:]+pts[:i0]+[pts[i0]]
        L=[0]
        for i in range(1,len(pts)): L.append(L[-1]+math.dist(pts[i-1],pts[i]))
        out=[]; j=0
        for i in range(N):
            t=L[-1]*i/N
            while L[j+1]<t: j+=1
            u=(t-L[j])/max(L[j+1]-L[j],1e-9); out.append((pts[j][0]+(pts[j+1][0]-pts[j][0])*u,pts[j][1]+(pts[j+1][1]-pts[j][1])*u))
        return out
def warp(canvas_arr,src,mapping,rows=18,cols=14):
    """draw src (H,W,4 float) through mapping(px,py)->(cx,cy) canvas pixels, on a mesh"""
    H,W=src.shape[:2]; Hc,Wc=canvas_arr.shape[:2]
    gx=np.linspace(0,W,cols); gy=np.linspace(0,H,rows)
    D={}
    for i,y in enumerate(gy):
        for j,x in enumerate(gx): D[i,j]=mapping(x,y)
    layer=np.zeros_like(canvas_arr)
    for i in range(rows-1):
        for j in range(cols-1):
            for tri in (((i,j),(i,j+1),(i+1,j)),((i,j+1),(i+1,j+1),(i+1,j))):
                Dp=np.array([D[k] for k in tri]); Sp=np.array([(gx[k[1]],gy[k[0]]) for k in tri])
                x0,y0=np.floor(Dp.min(0)).astype(int); x1,y1=np.ceil(Dp.max(0)).astype(int)
                x0=max(x0,0); y0=max(y0,0); x1=min(x1,Wc-1); y1=min(y1,Hc-1)
                if x1<x0 or y1<y0: continue
                M=np.array([[Dp[0,0],Dp[1,0],Dp[2,0]],[Dp[0,1],Dp[1,1],Dp[2,1]],[1,1,1]])
                try: Mi=np.linalg.inv(M)
                except np.linalg.LinAlgError: continue
                yy,xx=np.mgrid[y0:y1+1,x0:x1+1]
                l=Mi@np.stack([xx.ravel()+0.5,yy.ravel()+0.5,np.ones(xx.size)])
                ins=(l>=-1e-4).all(0)
                if not ins.any(): continue
                sx=np.clip((Sp[:,0]@l)[ins]-0.5,0,W-1.001); sy=np.clip((Sp[:,1]@l)[ins]-0.5,0,H-1.001)
                ix=sx.astype(int); iy=sy.astype(int); fx=(sx-ix)[:,None]; fy=(sy-iy)[:,None]
                c=src[iy,ix]*(1-fx)*(1-fy)+src[iy,ix+1]*fx*(1-fy)+src[iy+1,ix]*(1-fx)*fy+src[iy+1,ix+1]*fx*fy
                Y=yy.ravel()[ins]; X=xx.ravel()[ins]; keep=c[:,3]>layer[Y,X,3]
                layer[Y[keep],X[keep]]=c[keep]
    a=layer[...,3:4]/255.0
    canvas_arr[...,:3]=canvas_arr[...,:3]*(1-a)+layer[...,:3]*a
    canvas_arr[...,3:4]=np.maximum(canvas_arr[...,3:4],layer[...,3:4])
