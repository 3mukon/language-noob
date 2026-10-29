/* Owns reading zoom and focus without changing the text layout scale. */
(() => {
  'use strict';
  function create({root,deck,live,reduceMotion,getGeometry,isBusy,isEnded,currentCard,resetWheel,onLayout}) {
    let reader=null,readerMotion=null;
    function animateReader(state) {
      const opening=!state.closing;
      const progress=readerMotion?.[0]?.effect.getComputedTiming().progress??1;
      // Read the painted frame before cancelling an unfinished opening.
      const targets=state.effects.map(item=>({...item,from:getComputedStyle(item.node)[item.property]}));
      if(readerMotion) {
        const previous=readerMotion;readerMotion=null;
        for(const animation of previous)animation.cancel();
      }
      root.classList.toggle('is-reader-expanded',opening);
      for(const item of targets)if(item.expanded!==undefined)item.node.style[item.property]=opening?item.expanded:item.base;
      for(const item of targets)item.to=getComputedStyle(item.node)[item.property];
      if(reduceMotion.matches){if(!opening)finishReading();return;}
      const duration=opening?560:Math.max(160,480*Math.sqrt(progress));
      const motions=targets.filter(item=>item.from!==item.to).map(item=>{
        const {property,from,to}=item;
        const frames=[{offset:0,[property]:from},{offset:1,[property]:to}];
        return item.node.animate(frames,{duration,easing:'cubic-bezier(.3,0,.2,1)'});
      });
      readerMotion=motions;
      Promise.all(motions.map(animation=>animation.finished)).then(()=>{
        if(readerMotion!==motions)return;
        readerMotion=null;if(!opening)finishReading();
      }).catch(()=>{});
    }
    function syncOrder(nodes) {
      if(!reader)return;
      reader.order=nodes;
    }
    function moveCard(card,parent,before=null) {
      const {input,scroll}=card;
      const position={reply:scroll.scrollTop,input:input.scrollTop,left:input.scrollLeft,start:input.selectionStart,end:input.selectionEnd,direction:input.selectionDirection};
      parent.insertBefore(card.node,before);
      return ()=>{
        if(input.selectionStart!==position.start || input.selectionEnd!==position.end || input.selectionDirection!==position.direction)input.setSelectionRange(position.start,position.end,position.direction);
        input.scrollTop=position.input;input.scrollLeft=position.left;scroll.scrollTop=position.reply;
      };
    }
    function finishReading(restoreFocus=true) {
      if(!reader)return;
      const state=reader;reader=null;
      if(readerMotion){const motions=readerMotion;readerMotion=null;for(const animation of motions)animation.cancel();}
      for(const item of state.effects)if(item.expanded!==undefined)item.node.style[item.property]=item.inline;
      state.card.node.classList.remove('is-reading-word','is-reading-note');
      state.card.node.removeAttribute('role');state.card.node.removeAttribute('aria-modal');
      state.card.node.setAttribute('aria-label',`${state.card.word.word} 学习卡片`);
      state.card.paper.inert=false;state.card.note.inert=false;
      state.control.setAttribute('aria-expanded','false');
      state.control.setAttribute('aria-label',state.kind==='word'?'放大单词便笺':'放大小纸条');
      root.classList.remove('has-reader','is-reader-expanded');
      const next=state.order.slice(state.order.indexOf(state.card.node)+1).find(node=>node.parentNode===deck);
      const restoreEditor=moveCard(state.card,deck,next||null);
      state.foreground.remove();
      root.querySelector('.ln-reading-shade').hidden=true;
      root.querySelector('.ln-toolbar').inert=false;
      deck.style.height=state.deckHeight;
      onLayout();
      live.textContent='已还原便笺';
      restoreEditor();
      if(restoreFocus) {
        const destination=state.focus?.isConnected && root.contains(state.focus)?state.focus:state.control;
        destination.focus({preventScroll:true});
      }
    }
    function closeReading(animated=true) {
      if(!reader)return;
      if(!animated){finishReading(false);return;}
      if(reader.closing)return;
      reader.closing=true;
      animateReader(reader);
    }
    function toggleReading(card,kind) {
      if(isBusy() || isEnded() || card!==currentCard())return;
      if(reader){closeReading();return;}
      resetWheel();
      const geometry=getGeometry();
      const target=kind==='word'?card.paper:card.note;
      const content=kind==='note'?target.querySelector('.ln-note-content'):null;
      const compose=content?card.input.closest('.ln-compose'):null;
      const baseComposeFont=compose?getComputedStyle(compose).fontSize:null;
      const control=target.querySelector(`[data-zoom="${kind}"]`);
      const origin=getComputedStyle(target).transformOrigin.split(' ').map(parseFloat);
      const scale=Math.max(1,Math.min(kind==='word'?1.5:2.1,(geometry.width-48)/target.offsetWidth,(root.clientHeight-44)/target.offsetHeight));
      const enlargedWidth=target.offsetWidth*scale;
      const enlargedHeight=target.offsetHeight*scale;
      const deckHeight=root.clientHeight;
      const centerX=(geometry.width-enlargedWidth)/2-geometry.left-target.offsetLeft;
      const centerY=(deckHeight-enlargedHeight)/2-geometry.top-target.offsetTop;
      const x=centerX+(scale-1)*origin[0];
      const y=centerY+(scale-1)*origin[1];
      const paperTransform=`translate(${x}px,${y}px) scale(${scale})`;
      const effects=[];
      const tween=(node,property,expanded)=>effects.push({node,property,expanded,base:getComputedStyle(node)[property],inline:node.style[property]});
      tween(target,'transform',paperTransform);
      if(kind==='word')tween(card.ground,'transform',paperTransform);
      if(content){tween(content,'transform','rotate(0deg)');tween(control,'transform','rotate(0deg)');}
      // Keep the writing hint quiet while the surrounding paper gains reading space.
      if(compose)tween(compose,'fontSize',`${Math.min(16,parseFloat(baseComposeFont)*scale)/scale}px`);
      // Reuse the prepared deck layer for background fading. Only lift the active
      // card into a foreground host; moving every covered sheet stalls long rounds.
      const order=[...deck.querySelectorAll('.ln-assembly')];
      const focus=document.activeElement;
      const foreground=document.createElement('div');foreground.className='ln-reader-foreground';
      Object.assign(foreground.style,{left:`${deck.offsetLeft}px`,top:`${deck.offsetTop}px`,width:`${deck.offsetWidth}px`,height:`${deck.offsetHeight}px`});
      root.append(foreground);const restoreEditor=moveCard(card,foreground);
      for(const node of [deck,root.querySelector('.ln-toolbar'),kind==='word'?card.note:card.paper,...(kind==='note'?[card.ground]:[])])effects.push({node,property:'opacity'});
      const state={card,kind,target,control,effects,foreground,order,focus,deckHeight:deck.style.height,closing:false};
      reader=state;
      root.classList.add('has-reader');card.node.classList.add(`is-reading-${kind}`);
      card.node.setAttribute('role','dialog');card.node.setAttribute('aria-modal','true');
      card.node.setAttribute('aria-label',`${card.word.word}，放大阅读`);
      card.paper.inert=kind==='note';card.note.inert=kind==='word';
      control.setAttribute('aria-expanded','true');
      control.setAttribute('aria-label',kind==='word'?'还原单词便笺':'还原小纸条');
      root.querySelector('.ln-reading-shade').hidden=false;
      root.querySelector('.ln-toolbar').inert=true;
      deck.style.height=`${deckHeight}px`;
      onLayout({right:(geometry.width+enlargedWidth)/2,top:(root.clientHeight-enlargedHeight)/2});
      // Keep the same 2D transform during animation and settled reading. Switching
      // to CSS zoom changes system-font metrics and can leave a native textarea's
      // placeholder unpainted (L-0004).
      animateReader(state);
      restoreEditor();
      control.focus({preventScroll:true});
      live.textContent='已放大。双击纸张空白处或按 Esc 还原，文字可选择复制';
    }

    return Object.freeze({toggle:toggleReading,close:closeReading,syncOrder,get state(){return reader;},get animations(){return readerMotion||[];}});
  }
  globalThis.PaperReader=Object.freeze({create});
})();
