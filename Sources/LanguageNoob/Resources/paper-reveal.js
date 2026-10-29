/* Pick up, turn and land an inert prompt face over the live answer paper. */
(() => {
  'use strict';
  function capture(paper) {
    const face=paper.cloneNode(true);
    face.classList.add('ln-reveal-front');
    face.removeAttribute('id');face.setAttribute('aria-hidden','true');face.inert=true;
    for(const node of face.querySelectorAll('[id]'))node.removeAttribute('id');
    for(const node of face.querySelectorAll('.ln-surface-corner'))node.remove();
    return face;
  }
  function start(card,front,{noteStart=1040,noteDuration=320}={}) {
    const {paper,note,node,ground}=card;
    const base=getComputedStyle(paper).transform;
    const transform=base==='none'?'':base;
    const matrix=base==='none'?new DOMMatrix():new DOMMatrix(base);
    const bounds=paper.getBoundingClientRect(),root=node.closest('#layered-note-preview');
    const width=paper.offsetWidth,height=paper.offsetHeight,scaleBase=matrix.a;
    const origin={x:(bounds.left+bounds.right)/2-matrix.m41,y:(bounds.top+bounds.bottom)/2-matrix.m42};
    const liftDistance=Math.min(52,Math.max(18,bounds.top-24));
    const {smooth,clamp}=PaperMotion;
    const backing=document.createElement('div');
    backing.className='ln-reveal-backing';backing.setAttribute('aria-hidden','true');
    const shadow=document.createElement('div');
    shadow.className='ln-reveal-shadow';shadow.setAttribute('aria-hidden','true');
    paper.before(shadow,backing);paper.after(front);
    node.classList.add('is-revealing');node.inert=true;
    const frontFrames=[],answerFrames=[],backingFrames=[],shadowFrames=[],groundFrames=[],noteFrames=[];
    const groundOpacity=+getComputedStyle(ground).opacity,noteOpacity=+getComputedStyle(note).opacity;
    const turnDuration=1120,duration=Math.max(turnDuration,noteStart+noteDuration);
    function projected(transforms) {
      const points=transforms.flatMap(value=>{
        const m=new DOMMatrix(value);
        return [[0,0],[width,0],[width,height],[0,height]].map(([x,y])=>{
          const p=new DOMPoint(x-width/2,y-height/2).matrixTransform(m);
          return {x:origin.x+p.x/p.w,y:origin.y+p.y/p.w};
        });
      });
      return {left:Math.min(...points.map(p=>p.x)),right:Math.max(...points.map(p=>p.x)),top:Math.min(...points.map(p=>p.y)),bottom:Math.max(...points.map(p=>p.y))};
    }
    for(let i=0;i<=80;i++) {
      const progress=i/80,offset=progress*turnDuration/duration,turn=smooth((progress-.2)/.56);
      const lift=smooth(progress/.23)*(1-smooth((progress-.76)/.24));
      const arc=Math.sin(Math.PI*turn),roll=-lift*(5+2*arc),pitch=lift*(4+3*arc);
      let x=lift*(30-10*turn)/scaleBase,y=-lift*(liftDistance+5*arc)/scaleBase,scale=1+.025*lift-.1*arc;
      const breadth=Math.max(.24,Math.abs(Math.cos(Math.PI*turn)));
      const makeTransforms=()=>{
        const held=`${transform} translate(${x}px,${y}px) rotateZ(${roll}deg) perspective(1800px) rotateX(${pitch}deg)`;
        return [`${held} rotateY(${-180*turn}deg) scale(${scale})`,`${held} rotateY(${180-180*turn}deg) scale(${scale})`,`${held} scaleX(${breadth}) scale(${scale})`];
      };
      let poses=makeTransforms(),edge=projected(poses);
      // Fit the actual projected faces, including an enlarged reading paper.
      const fit=Math.min(1,(root.clientWidth-24)/(edge.right-edge.left),(root.clientHeight-24)/(edge.bottom-edge.top));
      if(fit<1){scale*=fit*.995;poses=makeTransforms();edge=projected(poses);}
      x+=clamp(0,12-edge.left,root.clientWidth-12-edge.right)/scaleBase;
      y+=clamp(0,12-edge.top,root.clientHeight-12-edge.bottom)/scaleBase;
      poses=makeTransforms();
      frontFrames.push({offset,transform:poses[0],opacity:1-smooth((turn-.4)/.08)});
      answerFrames.push({offset,transform:poses[1],opacity:smooth((turn-.52)/.08)});
      // The narrow, moving underside keeps the edge crossing solid without
      // leaving a stationary full-size sheet behind the lifted paper.
      backingFrames.push({offset,transform:poses[2],opacity:smooth((turn-.3)/.12)*(1-smooth((turn-.58)/.12))});
      shadowFrames.push({offset,transform:`${transform} translate(${x*.55}px,${12*lift/scaleBase}px) rotate(${roll*.5}deg) scaleX(${breadth}) scale(${1-.04*lift})`,opacity:.65*lift});
      // Once airborne, only the moving footprint may cast a shadow. Retaining
      // any contact-shadow floor leaves a ghost rectangle at the resting pose.
      groundFrames.push({offset,opacity:groundOpacity*(1-lift)});
      noteFrames.push({offset:progress,opacity:noteOpacity*smooth((progress*duration-noteStart)/noteDuration)});
    }
    // Preserve the paper's pace, then hold its settled pose while the note
    // finishes a later, unhurried fade on the same cancellable timeline.
    for(const frames of [frontFrames,answerFrames,backingFrames,shadowFrames,groundFrames])frames.push({...frames.at(-1),offset:1});
    const options={duration,easing:'linear',fill:'both'};
    const animations=[[front,frontFrames],[paper,answerFrames],[backing,backingFrames],[shadow,shadowFrames],[ground,groundFrames],[note,noteFrames]].map(([element,frames])=>element.animate(frames,options));
    let disposed=false;
    function cancel() {
      if(disposed)return;disposed=true;
      for(const animation of animations)animation.cancel();
      front.remove();backing.remove();shadow.remove();node.classList.remove('is-revealing');
    }
    return {card,animations,surfaces:[front,backing],cancel,finished:Promise.all(animations.map(animation=>animation.finished.catch(()=>{})))};
  }
  globalThis.PaperReveal=Object.freeze({capture,start});
})();
