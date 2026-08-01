from __future__ import annotations

import argparse, hashlib, json, math, shutil, zipfile
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import distance_transform_edt, gaussian_filter
from skimage import measure


def smoothstep(a,b,x):
    t=np.clip((x-a)/(b-a),0,1); return t*t*(3-2*t)

def norm(a,lo=None,hi=None):
    f=a[np.isfinite(a)]; lo=float(f.min()) if lo is None else lo; hi=float(f.max()) if hi is None else hi
    return np.clip((a-lo)/max(hi-lo,1e-8),0,1)

def write_f32(path,a): path.write_bytes(np.asarray(a,dtype='<f4').tobytes(order='C'))
def save_rgba(path,a): Image.fromarray(np.flipud(np.clip(a,0,255).astype(np.uint8)),'RGBA').save(path)
def save_l(path,a): Image.fromarray(np.flipud(np.clip(a,0,255).astype(np.uint8)),'L').save(path)

def sha(path):
    h=hashlib.sha256(); h.update(path.read_bytes()); return h.hexdigest()

def water_rgb(depth,dark=False):
    positive=depth[depth>0]; hi=float(np.percentile(positive,98)) if positive.size else 1.0
    t=norm(depth,0,max(hi,.5))[...,None]
    shallow=np.array([134,210,235],np.float32); deep=np.array([19,91,164],np.float32)
    if dark: shallow=np.array([64,147,183],np.float32); deep=np.array([9,42,91],np.float32)
    return shallow*(1-t)+deep*t

def elev_rgb(bed):
    t=norm(bed,0,max(4.0,float(bed.max())))[...,None]
    low=np.array([235,218,143],np.float32); high=np.array([126,182,119],np.float32)
    return low*(1-t)+high*t

def texture(land,seed,dark,density):
    h,w=land.shape; rng=np.random.default_rng(seed)
    n=norm(gaussian_filter(rng.normal(size=(h,w)),sigma=max(3,min(h,w)/60)))
    c0=np.array([46,48,48] if dark else [224,216,194],np.float32)
    c1=np.array([75,78,72] if dark else [241,233,211],np.float32)
    rgba=np.zeros((h,w,4),np.uint8); rgba[...,:3]=(c0*(1-n[...,None])+c1*n[...,None]).astype(np.uint8); rgba[...,3]=land*255
    img=Image.fromarray(np.flipud(rgba),'RGBA'); over=Image.new('RGBA',(w,h),(0,0,0,0)); d=ImageDraw.Draw(over,'RGBA')
    park=(55,98,67,165) if dark else (123,174,109,170)
    for _ in range(max(6,density//3)):
        cx=int(rng.uniform(.05,.95)*w); cy=int(rng.uniform(.06,.94)*h); rx=int(rng.uniform(.025,.09)*w); ry=int(rng.uniform(.02,.07)*h)
        d.ellipse((cx-rx,cy-ry,cx+rx,cy+ry),fill=park)
    major=(190,181,165,210) if dark else (250,248,239,230); minor=(135,132,124,130) if dark else (203,198,184,160)
    for i in range(density):
        pts=[]
        if i%2==0:
            y0=(i+1)/(density+1)*h
            for k in range(9): pts.append((int(k/8*w),int(y0+math.sin(k/8*2*math.pi+i)*h*.025)))
        else:
            x0=(i+1)/(density+1)*w
            for k in range(9): pts.append((int(x0+math.sin(k/8*2*math.pi+i*.7)*w*.018),int(k/8*h)))
        d.line(pts,fill=major if i%4==0 else minor,width=max(1,int(min(w,h)*(.006 if i%4==0 else .0025))))
    block=(94,91,88,65) if dark else (188,172,153,70)
    for _ in range(density*14):
        x0=int(rng.uniform(0,w)); y0=int(rng.uniform(0,h)); bw=int(rng.uniform(.006,.022)*w); bh=int(rng.uniform(.006,.025)*h)
        d.rounded_rectangle((x0,y0,x0+bw,y0+bh),radius=max(1,min(bw,bh)//5),fill=block)
    oa=np.array(over); oa[...,3]=(oa[...,3].astype(np.float32)*np.flipud(land)).astype(np.uint8)
    return np.flipud(np.array(Image.alpha_composite(img,Image.fromarray(oa,'RGBA'))))

def resize_rgba(a,size): return np.flipud(np.array(Image.fromarray(np.flipud(a.astype(np.uint8)),'RGBA').resize(size,Image.Resampling.LANCZOS)))
def resize_scalar(a,size): return np.flipud(np.array(Image.fromarray(np.flipud(a.astype(np.float32)),'F').resize(size,Image.Resampling.BILINEAR),np.float32))
def resize_mask(a,size): return np.flipud(np.array(Image.fromarray(np.flipud((a*255).astype(np.uint8)),'L').resize(size,Image.Resampling.NEAREST))>127)

def foam(wet):
    inside=distance_transform_edt(wet); outside=distance_transform_edt(~wet); d=np.where(wet,inside,outside)
    core=np.clip((2.2-d)/.8,0,1); halo=np.maximum(np.clip((5-d)/3.6,0,1)-core*.7,0)
    return core,halo

def widget(tex,depth,appearance,size):
    wet=resize_mask(depth>1e-5,size); dep=resize_scalar(depth,size); t=resize_rgba(tex,size); h,w=wet.shape
    out=np.zeros((h,w,4),np.float32)
    if appearance=='tinted': out[...,:3]=[217,225,231]; out[...,3]=235; out[wet,:3]=[74,132,181]
    elif appearance=='clear':
        out[...,:3]=[230,236,240]; out[...,3]=95; out[~wet,:3]=np.maximum(t[~wet,:3]*.75,95); out[~wet,3]=np.maximum(t[~wet,3],145); out[wet,:3]=[91,154,198]; out[wet,3]=175
    else:
        out[:]=t; wc=water_rgb(dep,appearance=='dark'); out[wet,:3]=wc[wet]; out[wet,3]=255
    core,halo=foam(wet); out[...,:3]*=(1-(halo*.12)[...,None]); white=np.ones((h,w,3))*255
    ah=(halo*.26)[...,None]; out[...,:3]=out[...,:3]*(1-ah)+white*ah
    ac=(core*.92)[...,None]; out[...,:3]=out[...,:3]*(1-ac)+white*ac; out[...,3]=np.maximum(out[...,3],np.maximum(core,halo)*255)
    return np.clip(out,0,255).astype(np.uint8)

def normal(bed,depth):
    land=depth<=1e-5; rgb=np.zeros((*bed.shape,3),np.float32); ec=elev_rgb(bed); wc=water_rgb(depth); rgb[land]=ec[land]; rgb[~land]=wc[~land]
    return np.dstack([rgb.astype(np.uint8),np.full(bed.shape,255,np.uint8)])

def svg(mask,title,seed):
    h,w=mask.shape; chunks=[]
    for c in sorted(measure.find_contours(mask.astype(np.float32),.5),key=len,reverse=True)[:16]:
        if len(c)<12: continue
        pts=c[::max(1,len(c)//500)]; cmd=[]
        for i,(r,col) in enumerate(pts): cmd.append(('M' if i==0 else 'L')+f'{col:.2f},{h-r:.2f}')
        chunks.append('<path d="'+' '.join(cmd)+' Z" fill="#e8dfc5" stroke="#ffffff" stroke-width="1"/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}"><title>{title} procedural map source</title><rect width="{w}" height="{h}" fill="#6cb7db"/>'+''.join(chunks)+f'<metadata>{{"generator":"generate_tide_maps.py","seed":{seed}}}</metadata></svg>'

def bay():
    w,h=1024,512; yy,xx=np.mgrid[0:h,0:w]; x=(xx+.5)/w; y=(yy+.5)/h
    center=.50+.055*np.sin(2*np.pi*(x+.08))-.025*np.exp(-((x-.26)/.15)**2); half=.045+.31*smoothstep(.02,.98,x)
    water=(np.abs(y-center)<half)|((x<.22)&(np.abs(y-(.50+.03*np.sin(9*x)))<(.035+.03*x)))|((x>.84)&(y>.055)&(y<.945))
    water|=((x<.48)&(np.abs(y-(center+.12-.10*x))<.015))|((x<.38)&(np.abs(y-(center-.13+.08*x))<.012))
    land=~water; dl=distance_transform_edt(land); rel=np.clip(np.abs(y-center)/np.maximum(half,1e-5),0,1)
    bed=np.empty((h,w),np.float32); deep=1.2+5.4*(1-rel**1.8)+2*smoothstep(.55,1,x)
    shoal=1.8*np.exp(-((x-.63)/.10)**2-((y-center-.10)/.04)**2)+1.3*np.exp(-((x-.74)/.08)**2-((y-center+.12)/.035)**2)
    bed[water]=np.minimum(-(deep[water]-shoal[water]),-.15); noise=.24*np.sin(7*x)*np.cos(6*y)+.18*np.sin(15*(x+y)); bed[land]=(2.65+1.35*smoothstep(0,.18,dl/24)+noise)[land]
    bank=land&(dl<=6); bed[bank]=np.maximum(bed[bank],2.05); depth=np.maximum(-bed,0).astype(np.float32); lm=bed>=0
    return dict(id='bay',name='Bay',w=w,h=h,domain=(40000.,20000.),aspect=2.,bank=2.,bed=bed,depth=depth,land=lm,td=texture(lm,1107,False,28),tk=texture(lm,1107,True,28),seed=1107,description='Original procedural funnel-shaped estuary city map, loosely inspired by large tidal bays.')

def lake():
    w=h=512; yy,xx=np.mgrid[0:h,0:w]; x=(xx+.5)/w; y=(yy+.5)/h
    water=(((x-.50)/.31)**2+((y-.52)/.285)**2<1)|(((x-.31)/.17)**2+((y-.52)/.18)**2<1)|(((x-.69)/.17)**2+((y-.44)/.20)**2<1)|(((x-.57)/.20)**2+((y-.72)/.12)**2<1)|(((x-.45)/.12)**2+((y-.81)/.10)**2<1)|(((x-.82)/.10)**2+((y-.48)/.12)**2<1)
    c1=(np.abs(x-(.45+.035*np.sin(10*y)))<.009)&(y>.30)&(y<.77); c2=(np.abs(y-(.62-.05*np.sin(8*x)))<.008)&(x>.50)&(x<.77); i1=((x-.61)/.035)**2+((y-.50)/.055)**2<1; i2=((x-.38)/.025)**2+((y-.62)/.032)**2<1
    water&=~(c1|c2|i1|i2); land=~water; dl=distance_transform_edt(land); dw=distance_transform_edt(water); bed=np.empty((h,w),np.float32); wet=.35+2.9*np.clip(dw/85,0,1)**.75; bed[water]=-wet[water]
    terr=1.65+.65*smoothstep(0,.22,dl/30)+.15*np.sin(10*x)*np.cos(8*y); bed[land]=terr[land]; bank=land&(dl<=5); bed[bank]=np.maximum(bed[bank],1.05); bed[c1|c2|i1|i2]=np.maximum(bed[c1|c2|i1|i2],1.35)
    depth=np.maximum(-bed,0).astype(np.float32); lm=bed>=0
    return dict(id='lake',name='Lake',w=w,h=h,domain=(4000.,4000.),aspect=1.,bank=1.,bed=bed,depth=depth,land=lm,td=texture(lm,2031,False,34),tk=texture(lm,2031,True,34),seed=2031,description='Original procedural urban lake map with irregular coves, causeways, and islands, loosely inspired by classical Chinese city lakes.')

def save_map(d,root,preview_root):
    p=root/f"{d['name']}.tidemap"; [q.mkdir(parents=True,exist_ok=True) for q in [p/'texture',p/'source',p/'preview']]
    write_f32(p/'bed_elevation.f32',d['bed']); write_f32(p/'initial_water_depth.f32',d['depth']); save_l(p/'land_mask.png',d['land']*255); save_rgba(p/'texture/land-default.png',d['td']); save_rgba(p/'texture/land-dark.png',d['tk'])
    primary=np.where(d['land'],np.clip(100+np.mean(d['td'][...,:3],axis=2)*.55,0,255),0); accent=np.where(d['depth']>1e-5,255,0); save_l(p/'texture/primary-mask.png',primary); save_l(p/'texture/accent-mask.png',accent)
    (p/'source/map.svg').write_text(svg(d['land'],d['name'],d['seed']),encoding='utf-8'); (p/'source/generation.json').write_text(json.dumps({'generator':'generate_tide_maps.py','seed':d['seed'],'copyright':'Original procedural asset generated for TideSandbox.','geographicBasis':'Loosely inspired shape only; not GIS data and not a geographic replica.'},indent=2),encoding='utf-8')
    save_rgba(p/'preview/normal-2d.png',normal(d['bed'],d['depth']))
    for fam,size in {'small':(340,340),'medium':(680,340)}.items():
        msize=(340,340) if d['aspect']==1 and fam=='medium' else size
        for app in ['default','dark','clear','tinted']:
            a=widget(d['tk'] if app=='dark' else d['td'],d['depth'],app,msize)
            if msize!=size:
                c=np.zeros((size[1],size[0],4),np.uint8); x0=(size[0]-msize[0])//2; c[:,x0:x0+msize[0]]=a; a=c
            fn=f'widget-{fam}-{app}.png'; save_rgba(p/'preview'/fn,a); save_rgba(preview_root/f"{d['id']}-{fn}",a)
    manifest={'schemaVersion':1,'id':d['id'],'name':d['name'],'description':d['description'],'gridWidth':d['w'],'gridHeight':d['h'],'domainWidthMeters':d['domain'][0],'domainHeightMeters':d['domain'][1],'rowOrder':'row-major-bottom-to-top','scalarType':'float32-little-endian','textureOrigin':'top-left','textureUVTransform':[1,0,0,-1,0,1],'recommendedAspect':d['aspect'],'landTextureColorSpace':'sRGB','bankElevationMetersASL':d['bank'],'resources':{'bedElevation':'bed_elevation.f32','initialWaterDepth':'initial_water_depth.f32','landMask':'land_mask.png','landDefault':'texture/land-default.png','landDark':'texture/land-dark.png','primaryMask':'texture/primary-mask.png','accentMask':'texture/accent-mask.png','sourceSVG':'source/map.svg','generation':'source/generation.json'}}
    (p/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8'); checks={str(x.relative_to(p)):sha(x) for x in sorted(p.rglob('*')) if x.is_file()}; (p/'checksums.sha256.json').write_text(json.dumps(checks,indent=2),encoding='utf-8')
    dl=distance_transform_edt(d['land']); bz=d['land']&(dl<=6)
    return {'name':d['name'],'cells':d['w']*d['h'],'bedMin':float(d['bed'].min()),'bedMax':float(d['bed'].max()),'depthMin':float(d['depth'].min()),'depthMax':float(d['depth'].max()),'landFraction':float(d['land'].mean()),'minimumBank':float(d['bed'][bz].min()),'finite':bool(np.isfinite(d['bed']).all() and np.isfinite(d['depth']).all()),'nonnegativeDepth':bool((d['depth']>=0).all()),'fileCount':sum(x.is_file() for x in p.rglob('*'))}

def contact(preview_root,mapid,out):
    names=[f'{mapid}-widget-{fam}-{app}.png' for fam in ['small','medium'] for app in ['default','dark','clear','tinted']]; imgs=[Image.open(preview_root/n).convert('RGBA') for n in names]; tw,th=360,190; c=Image.new('RGBA',(tw*2,th*4),(28,30,34,255))
    for i,img in enumerate(imgs): img.thumbnail((tw-12,th-12),Image.Resampling.LANCZOS); c.alpha_composite(img,((i%2)*tw+(tw-img.width)//2,(i//2)*th+(th-img.height)//2))
    c.save(out)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--root',type=Path,required=True); a=ap.parse_args(); assets=a.root/'Assets/TideMaps'; previews=a.root/'Docs/MapAssets/previews'; assets.mkdir(parents=True,exist_ok=True); previews.mkdir(parents=True,exist_ok=True)
    rs=[save_map(d,assets,previews) for d in [bay(),lake()]]; contact(previews,'bay',previews/'Bay-contact-sheet.png'); contact(previews,'lake',previews/'Lake-contact-sheet.png')
    lines=['# TideMap Asset Validation Report','','Generated by `Tools/MapGeneration/generate_tide_maps.py`.','','These are original procedural assets. They do not contain downloaded map tiles, labels, logos, or watermarks.','']
    for r in rs: lines += [f"## {r['name']}",'',f"- Cells: `{r['cells']}`",f"- Bed elevation range: `{r['bedMin']:.3f}` to `{r['bedMax']:.3f}` m ASL",f"- Initial water depth range: `{r['depthMin']:.3f}` to `{r['depthMax']:.3f}` m",f"- Land fraction: `{r['landFraction']:.3f}`",f"- Minimum generated bank-zone elevation: `{r['minimumBank']:.3f}` m ASL",f"- All values finite: `{r['finite']}`",f"- Water depth nonnegative: `{r['nonnegativeDepth']}`",f"- Files in package: `{r['fileCount']}`",'']
    (a.root/'Docs/MapAssets/asset_validation_report.md').write_text('\n'.join(lines),encoding='utf-8')
if __name__=='__main__': main()
