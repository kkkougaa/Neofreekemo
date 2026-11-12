"""Liquid junction where the slime leaves the island's underside. On each side a
concave fillet, tangent to the island's outline at one end and to the body's edge at
the other, so the surface flows into the silhouette with no corner, step or ledge.
The island's underside is the real pill outline: flat in the middle, round at the ends."""
import math
class Pill:
    def __init__(s,x0,x1,top,bottom):
        s.x0,s.x1,s.top,s.bottom=x0,x1,top,bottom; s.r=(bottom-top)/2; s.cy=top+s.r
    def y(s,x):
        """the underside at x (inside the pill's span)"""
        if s.x0+s.r<=x<=s.x1-s.r: return s.bottom
        cx=s.x0+s.r if x<s.x0+s.r else s.x1-s.r
        dx=max(-s.r+1e-3,min(s.r-1e-3,x-cx)); return s.cy+math.sqrt(s.r*s.r-dx*dx)
    def tangent(s,x,side):
        """unit direction along the underside, heading toward the body (opposite of side)"""
        h=0.3; d=(s.y(x-side*h)-s.y(x))
        l=math.hypot(h,d); return (-side*h/l,d/l)
def _bez(p0,p1,p2,p3,n=20):
    out=[]
    for i in range(n+1):
        t=i/n; a=(1-t)**3; b=3*(1-t)**2*t; c=3*(1-t)*t*t; d=t**3
        out.append((a*p0[0]+b*p1[0]+c*p2[0]+d*p3[0], a*p0[1]+b*p1[1]+c*p2[1]+d*p3[1]))
    return out
def fillet(path,side,pill,radius=9.0,depth=10.0):
    surface=pill.bottom
    for k in range(1,len(path)):
        a,b=path[k-1],path[k]
        if b[1]>=surface+depth:
            t=(surface+depth-a[1])/max(b[1]-a[1],1e-6); E=(a[0]+(b[0]-a[0])*t, surface+depth)
            above=path[:k]; break
    else:
        return None
    j=max(0,k-3); T=(path[j][0]-E[0],path[j][1]-E[1]); tl=math.hypot(*T) or 1; T=(T[0]/tl,T[1]/tl)
    if T[1]>-0.6:   # arrive running up into the surface, never sideways into a ledge
        T=(T[0]*0.5,-0.85); tl=math.hypot(*T); T=(T[0]/tl,T[1]/tl)
    reach=max([p[0]*side for p in above if p[1]<=surface+depth]+[E[0]*side])
    sx=side*reach+side*radius
    # keep the start on the pill (a little inside its round end at most)
    sx=max(pill.x0+2,min(pill.x1-2,sx))
    S=(sx,pill.y(sx)); Tg=pill.tangent(sx,side)
    curve=_bez(S,(S[0]+Tg[0]*radius*0.62,S[1]+Tg[1]*radius*0.62),(E[0]+T[0]*depth*0.62,E[1]+T[1]*depth*0.62),E)
    inner=list(reversed(above))
    # close inside the pill, following its outline, so nothing shows outside it
    x_end=above[0][0]; n=12
    back=[(x_end+(sx-x_end)*i/n,pill.y(x_end+(sx-x_end)*i/n)-3) for i in range(n+1)]
    return curve+inner+back
def fillets(left,right,pill,radius=9.0,depth=10.0):
    return [p for p in (fillet(right,1,pill,radius,depth),fillet(left,-1,pill,radius,depth)) if p]
def neck(left,right,pill,depth=10.0):
    surface=pill.bottom
    def cut(path):
        out=[]
        for k,p in enumerate(path):
            if p[1]>=surface+depth:
                if k: a=path[k-1]; t=(surface+depth-a[1])/max(p[1]-a[1],1e-6); out.append((a[0]+(p[0]-a[0])*t,surface+depth))
                break
            out.append(p)
        return out
    L,Rr=cut(left),cut(right)
    return L+list(reversed(Rr)) if len(L)>1 and len(Rr)>1 else None
def junction(left,right,pill,energy=0.0):
    radius=11+5*energy; depth=11+4*energy
    polys=fillets(left,right,pill,radius,depth)
    n=neck(left,right,pill,depth)
    return polys+([n] if n else [])
