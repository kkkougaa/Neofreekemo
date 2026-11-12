import math,json
CONTOUR=None
def load(S):
    global CONTOUR; CONTOUR=json.load(open(S+'/contour.json'))
def ease(x): x=max(0,min(1,x)); return x*x*(3-2*x)
def eout(x): x=max(0,min(1,x)); return 1-(1-x)**3
def lerp(a,b,t): return a+(b-a)*t
def resample(seq,n):
    L=[0]
    for i in range(1,len(seq)): L.append(L[-1]+math.dist(seq[i-1],seq[i]))
    tot=L[-1]; out=[]; j=0
    for i in range(n):
        s=tot*i/(n-1)
        while j<len(L)-2 and L[j+1]<s: j+=1
        t=(s-L[j])/max(L[j+1]-L[j],1e-9); out.append((seq[j][0]+(seq[j+1][0]-seq[j][0])*t, seq[j][1]+(seq[j+1][1]-seq[j][1])*t))
    return out
def drop(w,n,L,R):
    """Hanging goo: wide where it leaves the island, a neck, a round bulb at the end. Same
    point layout as the character contour: 24 along the root, 95 round the rest."""
    def r(y):
        neck=n+(w/2-n)*math.exp(-y/max(3.0,L*0.12))
        yc=L-R; bulb=math.sqrt(max(0,R*R-(y-yc)**2)) if abs(y-yc)<R else 0
        cap=(w/2)*math.sqrt(max(0,1-(y/L)**2)) if L>0 else 0
        return min(max(neck,bulb), max(cap,bulb) if L<R*2.2 else max(neck,bulb))
    ys=[L*(i/200) for i in range(201)]
    right=[(r(y),y) for y in ys]; left=[(-r(y),y) for y in reversed(ys)]
    top=[(-w/2+w*i/23,0.0) for i in range(24)]
    rest=resample(right+left,97)[1:-1]
    return top+rest
def character(sx=0.93,sy=1.15):
    return [(x*sx,y*sy) for x,y in CONTOUR]
def emerge_slide(u):
    """how far the goo has travelled from the island's middle to its spot (0..1)"""
    return 0.0 if u<0.24 else ease((u-0.24)/0.34)
def retract_slide(u):
    return 1.0 if u<0.30 else 1-ease((u-0.30)/0.26)
def emerge_shape(u):
    """u seconds into coming out; returns (points, done)"""
    if u<0.28:   # 1. puddle: spreads thin along the island's edge
        e=eout(u/0.28); return drop(96*e,2+3*e,3+5*e,2+3*e),False
    if u<0.52:   # 2. gathers toward the spot, thickening (mesh deformation)
        e=ease((u-0.28)/0.24); return drop(lerp(96,44,e),lerp(5,7,e),lerp(8,26,e),lerp(5,11,e)),False
    if u<0.80:   # 3. pulled down long (warp)
        e=eout((u-0.52)/0.28); return drop(44,lerp(7,4,e),lerp(26,77,e),lerp(11,15,e)),False
    if u<1.05:   # 4. shape morph into the character
        e=ease((u-0.80)/0.25); a=drop(44,4,77,15); b=character()
        return [(lerp(p[0],q[0],e),lerp(p[1],q[1],e)) for p,q in zip(a,b)],False
    return character(),True
def retract_shape(u):
    """the reverse, quicker"""
    if u<0.18:
        e=ease(u/0.18); a=character(); b=drop(44,4,60,13)
        return [(lerp(p[0],q[0],e),lerp(p[1],q[1],e)) for p,q in zip(a,b)],False
    if u<0.36:
        e=ease((u-0.18)/0.18); return drop(lerp(44,70,e),lerp(4,6,e),lerp(60,8,e),lerp(13,5,e)),False
    if u<0.58:
        e=eout((u-0.36)/0.22); return drop(lerp(70,96,e),lerp(6,1,e),lerp(8,0.5,e),lerp(5,0.5,e)),False
    return None,True
