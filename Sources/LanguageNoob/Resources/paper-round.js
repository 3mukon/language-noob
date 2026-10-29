/* Turn the summary into a real word paper, then open its remaining stack. */
(() => {
  'use strict';
  function start(cards,front,geometry) {
    const card=cards[0],deck=card.node.parentElement;
    const duration=1840,noteStart=1480,noteDuration=360;
    const groups=[],saved=[],animations=[];
    front.hidden=false;
    front.classList.add('ln-round-front');
    // Covered cards share the third pose. Keep them opaque in one group,
    // rather than promoting a separate animated layer for every word.
    for(const [depth,members] of [[1,cards.slice(1,2)],[2,cards.slice(2)]]) {
      if(!members.length)continue;
      const node=document.createElement('div');node.className='ln-round-stack';
      node.style.zIndex=members[0].node.style.zIndex;
      deck.append(node);
      for(const member of members){
        saved.push({node:member.node,style:member.node.getAttribute('style')});
        member.node.style.left='0';member.node.style.top='0';member.node.style.transform='none';
        member.node.inert=true;node.append(member.node);
      }
      const target=PaperMotion.rest(depth,geometry),frames=[],shadows=[];
      const delay=1120+(depth-1)*60;
      for(let i=0;i<=92;i++){
        const offset=i/92,time=offset*duration,t=PaperMotion.smooth((time-delay)/620);
        const pose=PaperMotion.mix(PaperMotion.pose(),target,t);
        frames.push({offset,transform:PaperMotion.transform(pose),opacity:PaperMotion.smooth((time-delay)/120)});
        shadows.push({offset,opacity:t});
      }
      const options={duration,easing:'linear',fill:'both'};
      animations.push(node.animate(frames,options),members[0].ground.animate(shadows,options));
      groups.push({node,paper:members[0].paper});
    }
    const turn=PaperReveal.start(card,front,{noteStart,noteDuration});
    const noteBase=getComputedStyle(card.note).transform;
    animations.push(card.note.animate([
      {offset:0,transform:`translate(-18px,12px) ${noteBase}`},
      {offset:noteStart/duration,transform:`translate(-18px,12px) ${noteBase}`,easing:'cubic-bezier(.22,.7,.25,1)'},
      {offset:1,transform:noteBase}
    ],{duration,fill:'both'}));
    let disposed=false;
    function cancel(){
      if(disposed)return;disposed=true;
      turn.cancel();for(const animation of animations)animation.cancel();
      for(const entry of saved){
        deck.append(entry.node);
        if(entry.style===null)entry.node.removeAttribute('style');else entry.node.setAttribute('style',entry.style);
      }
      for(const group of groups)group.node.remove();
    }
    return {
      card,cancel,
      preparedSurfaces:[card.paper,card.note,...turn.surfaces,...groups.map(group=>group.paper)],
      get surfaces(){return [card.paper,card.note,...turn.surfaces,...groups.filter(group=>+getComputedStyle(group.node).opacity>.005).map(group=>group.paper)];},
      finished:Promise.all([turn.finished,...animations.map(animation=>animation.finished.catch(()=>{}))])
    };
  }
  function startSummary(paper,front) {
    front.classList.add('ln-round-front');
    const deck=paper.parentElement,following=paper.nextSibling;
    const node=document.createElement('div');node.className='ln-assembly ln-summary-turn';
    const ground=document.createElement('div');ground.className='ln-ground-shadow';
    const note=document.createElement('div');note.hidden=true;
    deck.append(node);node.append(ground,paper,note);
    const turn=PaperReveal.start({paper,note,node,ground},front);
    let disposed=false;
    return {
      preparedSurfaces:[paper,...turn.surfaces],
      get surfaces(){return [paper,...turn.surfaces];},
      finished:turn.finished,
      cancel(){
        if(disposed)return;disposed=true;
        turn.cancel();deck.insertBefore(paper,following?.parentElement===deck?following:null);node.remove();
      }
    };
  }
  globalThis.PaperRound=Object.freeze({start,startSummary});
})();
