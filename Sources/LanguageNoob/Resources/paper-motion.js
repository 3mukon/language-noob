/* Pure geometry: presentation and tests share the same paper trajectories. */
(() => {
  'use strict';
  const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = value => { const t = clamp(value, 0, 1); return t * t * t * (t * (t * 6 - 15) + 10); };
  const pose = (x = 0, y = 0, r = 0, s = 1, rx = 0, ry = 0, z = 0) => ({ x, y, r, s, rx, ry, z });
  const mix = (a, b, t) => Object.fromEntries(Object.keys(a).map(key => [key, lerp(a[key], b[key], t)]));
  const transform = p => `translate3d(${p.x.toFixed(3)}px,${p.y.toFixed(3)}px,${p.z.toFixed(3)}px) rotateZ(${p.r.toFixed(3)}deg) rotateY(${p.ry.toFixed(3)}deg) rotateX(${p.rx.toFixed(3)}deg) scale(${p.s.toFixed(5)})`;
  const slot = (index, front, count) => (index - front + count) % count;
  const perspective = 1500, margin = 8;

  function handoff(from, to, layers, direction=Math.sign(to-from)) {
    const forward=direction>0;
    const count=forward?slot(to,from,layers.length):1;
    const bottom=Math.min(...layers),top=Math.max(...layers);
    const changes=Array.from({length:count},(_,offset)=>{
      const index=forward?(from+offset)%layers.length:to;
      return {index,start:layers[index],end:forward?bottom-(offset+1)*10:top+10};
    });
    return {...changes[0],changes};
  }

  function edges(p, geometry, withNote, noteOnly=false) {
    const {w,h,left,width,nw,nh,nx,ny,noteAngle}=geometry;
    const points=noteOnly?[]:[[0,0],[w,0],[w,h],[0,h]];
    if(withNote){
      const angle=noteAngle*Math.PI/180, c=Math.cos(angle), s=Math.sin(angle);
      for(const [x,y] of [[0,0],[nw,0],[nw,nh],[0,nh]])
        points.push([nx+26+(x-26)*c-(y-22)*s,ny+22+(x-26)*s+(y-22)*c]);
    }
    const rx=p.rx*Math.PI/180,ry=p.ry*Math.PI/180,rz=p.r*Math.PI/180;
    return points.map(([px,py])=>{
      let x=(px-w*.5)*p.s,y=(py-h*.52)*p.s,z=0;
      [y,z]=[y*Math.cos(rx),y*Math.sin(rx)];
      [x,z]=[x*Math.cos(ry)+z*Math.sin(ry),-x*Math.sin(ry)+z*Math.cos(ry)];
      x=x*Math.cos(rz)-y*Math.sin(rz);
      return {base:left+w*.5+x,depth:1-(z+p.z)/perspective,camera:width*.5};
    });
  }

  function bounds(p, geometry, withNote=false, noteX=0) {
    if(noteX)geometry={...geometry,nx:geometry.nx+noteX};
    const xs=edges(p,geometry,withNote).map(({base,depth,camera})=>camera+(base+p.x-camera)/depth);
    return {left:Math.min(...xs),right:Math.max(...xs)};
  }

  function contain(p, geometry, withNote=false, shift=0) {
    let low=-Infinity,high=Infinity;
    for(const {base,depth,camera} of edges(p,geometry,withNote)){
      low=Math.max(low,(margin-shift-camera)*depth+camera-base);
      high=Math.min(high,(geometry.width-margin-shift-camera)*depth+camera-base);
    }
    return {...p,x:clamp(p.x,low,high)};
  }

  function dockNote(p,geometry,shift=0) {
    // Let the word paper follow the hand; tuck only the attached note inward
    // when its projected edge reaches the window. Solve in its local X axis.
    const ry=p.ry*Math.PI/180,rz=p.r*Math.PI/180;
    const horizontal=p.s*Math.cos(ry)*Math.cos(rz),depthStep=p.s*Math.sin(ry)/perspective;
    let low=-Infinity,high=Infinity;
    for(const {base,depth,camera} of edges(p,geometry,true,true)){
      const left=margin-shift-camera,right=geometry.width-margin-shift-camera,offset=base+p.x-camera;
      low=Math.max(low,(left*depth-offset)/(horizontal-left*depthStep));
      high=Math.min(high,(right*depth-offset)/(horizontal-right*depthStep));
    }
    return clamp(0,low,high);
  }

  const noteTransform=x=>`translateX(${x.toFixed(3)}px) rotate(var(--ln-note-angle))`;

  function drag(dx,dy,geometry) {
    const limit=Math.min(144,geometry.w*.36),x=limit*Math.tanh(dx/limit);
    return contain(pose(x,-Math.min(Math.abs(x)*.085,15)+clamp(dy*.1,-9,9),x/geometry.w*8,1+Math.min(Math.abs(x)/geometry.w*.025,.018),0,-x/geometry.w*4,Math.min(Math.abs(x)*.12,15)),geometry);
  }

  function rest(depth, geometry) {
    if (depth === 0) return pose();
    if (depth === 1) return pose(geometry.spread, 21, geometry.fan * .7, .985);
    // Covered sheets stay painted at exactly the same pose (L-0001).
    return pose(-geometry.spread, 25, -geometry.fan, .972);
  }

  function cubic(a, b, c, d, t) {
    const m = 1 - t;
    return m * m * m * a + 3 * m * m * t * b + 3 * m * t * t * c + t * t * t * d;
  }

  function flight(geometry) {
    // Make room by gently moving the stack as one surface. The turning sheet
    // keeps a broad face instead of collapsing to an aliased, edge-on slit.
    const stackLeft=Math.min(...[0,1,2].map(depth=>bounds(rest(depth,geometry),geometry).left));
    const angle=-lerp(54,48,clamp((geometry.width-700)/240,0,1));
    const outer=pose(0,-26,0,.98,0,angle);
    const points=edges(outer,geometry,false);
    function place(shift) {
      return {...outer,x:Math.max(...points.map(({base,depth,camera})=>(24-shift-camera)*depth+camera-base))};
    }
    let low=0,high=geometry.w;
    for(let i=0;i<20;i++){
      const shift=(low+high)/2;
      if(bounds(place(shift),geometry).right+18>stackLeft)low=shift;else high=shift;
    }
    return {outer:place(high),shift:high};
  }

  const stackShift=(u,path)=>path.shift*(u<=.5?smooth(u/.5):1-smooth((u-.5)/.32));

  function arc(u, front, bottom, geometry, path) {
    const outer=path.outer;
    const first = u <= .5;
    const t = first ? u * 2 : (u - .5) * 2;
    const a = first ? front : outer, b = first ? outer : bottom;
    const result = mix(a, b, smooth(t));
    result.x = cubic(a.x, first ? front.x - geometry.w * .2 : outer.x,
                     first ? outer.x : bottom.x - 60, b.x, t);
    result.y = cubic(a.y, first ? front.y - 52 : outer.y + 40,
                     first ? outer.y - 40 : bottom.y + 40, b.y, t);
    return result;
  }

  function reverseDeparture(u,start,end,geometry,path) {
    const position=mix(start,end,smooth(u));
    const front=bounds(rest(0,geometry),geometry),outer=bounds(path.outer,geometry);
    const leftTravel=(front.left+front.right-outer.left-outer.right)/2-path.shift;
    const middle=mix(start,end,.5);
    const reach=Math.max(0,leftTravel-path.shift-middle.x);
    const lift=Math.sin(Math.PI*u)**2;
    position.x+=reach*lift;
    position.y-=24*lift;
    position.r+=4*lift;
    position.ry-=8*lift;
    position.z+=10*lift;
    return position;
  }

  function sample({ index, from, to, count, geometry, drag = null, path=flight(geometry), direction=Math.sign(to-from) }, time) {
    const t = clamp(time, 0, 1), u = t * t * (3 - 2 * t);
    const forward = direction > 0;
    const before = slot(index, from, count), after = slot(index, to, count);
    const moving = forward ? before < slot(to,from,count) : index === to;
    const start = before === 0 && drag ? drag : rest(before, geometry);
    const end = rest(after, geometry);
    let position;
    if (moving) position = forward ? arc(u, start, end, geometry,path) : arc(1 - u, end, start, geometry,path);
    else if(!forward && before===0)position=reverseDeparture(u,start,end,geometry,path);
    else position = mix(start, end, smooth(u));
    const note = before === 0 ? 1 - smooth((u - .12) / .14) : after === 0 ? smooth((u - .82) / .16) : 0;
    const shift=stackShift(u,path);
    position=contain(position,geometry,false,shift);
    const noteX=dockNote(position,geometry,shift);
    // Covered papers can cast shadows outside their covering sheet; fade them independently.
    const ambient = before > 2 && after > 2 ? 0 : before > 2 ? smooth(u / .3) : after > 2 ? 1 - smooth((u - .7) / .3) : 1;
    const heldShadow = before === 0 && drag ? Math.min(.6, Math.abs(drag.x) / geometry.w) : 0;
    const shadow = Math.sin(Math.PI * u) ** 2 * (moving ? forward && before>0 ? 0 : .55 : !forward && before===0 ? .35 : .1) + heldShadow * (1 - smooth(u / .4));
    return { pose: position, note, noteX, shadow, ambient, shift };
  }

  globalThis.PaperMotion = Object.freeze({ clamp, lerp, smooth, pose, mix, transform, slot, rest, handoff, flight, sample, bounds, contain, dockNote, noteTransform, drag, perspective });
})();
