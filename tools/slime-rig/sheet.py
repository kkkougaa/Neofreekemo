import sys,math
B,S=sys.argv[1:3]; sys.path.insert(0,S)
from rig3 import Rig
from PIL import Image, ImageDraw, ImageFont
FONT='/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc'
f=ImageFont.truetype(FONT,30)
names=[('normal','기본'),('surprised','놀람'),('happy','기쁨'),('squint','찡그림'),('curious','궁금'),('sleepy','졸림 (새)'),('angry','화남 (새)'),('sad','슬픔 (새)'),('love','하트눈 (새)'),('dizzy','어질어질 (새)')]
K=6; CW,CH=100,92
def star(x,y,r,rot): return [((x+(r if i%2==0 else r*0.45)*math.cos(rot+i*math.pi/5))*K,(y+(r if i%2==0 else r*0.45)*math.sin(rot+i*math.pi/5))*K) for i in range(10)]
def anger(d,x,y,r):
    for j in range(4):
        a=j*math.pi/2+math.pi/4; cx,cy=x+r*math.cos(a),y+r*math.sin(a)
        d.line([((cx+r*0.75*math.cos(a+math.pi*0.75+k/8*math.pi*0.5))*K,(cy+r*0.75*math.sin(a+math.pi*0.75+k/8*math.pi*0.5))*K) for k in range(9)],fill=(230,40,40),width=int(1.4*K),joint='curve')
sheet=Image.new('RGB',(CW*K*5,(CH*K+50)*2),'white')
for i,(e,label) in enumerate(names):
    R=Rig(B,S); R.expr=e; anchor=(CW/2,6)
    for _ in range(90):
        R.simulate(1/60,anchor,1.0,0.0,breeze=0); Bd=R.bands(); R.step_bones(Bd,1/60); R.update_face(1/60,0.0)
    c=Image.new('RGBA',(CW*K,CH*K),(255,255,255,255)); d=ImageDraw.Draw(c)
    d.rounded_rectangle([(CW/2-63)*K,(6-37+5)*K,(CW/2+63)*K,(6+5)*K],radius=18*K,fill=(0,0,0))
    R.render(c,K,Bd,0.0,0.0,0.7); h=R.head(Bd); d=ImageDraw.Draw(c)
    if e=='sleepy':
        for dx,dy,sz in [(-12,8,1),(-18,0,1.3),(-25,-9,1.6)]: d.text(((h[0]+dx)*K,(h[1]+dy)*K),'z',font=ImageFont.truetype(FONT,int(20*sz)),fill=(90,90,110))
    if e=='love':
        for dx,dy in [(-14,4),(12,-2),(-4,-12)]:
            pts=[]
            for k in range(30):
                t=k/30*2*math.pi; hx=16*math.sin(t)**3; hy=-(13*math.cos(t)-5*math.cos(2*t)-2*math.cos(3*t)-math.cos(4*t))
                pts.append(((h[0]+dx+hx*6/32)*K,(h[1]+dy+hy*6/32)*K))
            d.polygon(pts,fill=(255,80,120))
    if e=='sad':
        P,_,_,_=R.body_xform(R.PIV['oval'][0],R.PIV['oval'][1]-3,Bd); d.ellipse([(P[0]-1.6)*K,(P[1]+3)*K,(P[0]+1.6)*K,(P[1]+7.4)*K],fill=(90,170,255))
    if e=='dizzy':
        for j in range(3):
            an=j*2.1; d.polygon(star(h[0]+14*math.cos(an),h[1]+10+5*math.sin(an),3.4,j),fill=(255,200,40))
    if e=='angry': anger(d,h[0]+11,h[1]+14,4.2)
    x=(i%5)*CW*K; y=(i//5)*(CH*K+50); sheet.paste(c.convert('RGB'),(x,y)); ImageDraw.Draw(sheet).text((x+20,y+CH*K+8),label,font=f,fill=(0,0,0))
sheet.resize((sheet.size[0]//2,sheet.size[1]//2),Image.LANCZOS).save(S+'/expressions.png')
