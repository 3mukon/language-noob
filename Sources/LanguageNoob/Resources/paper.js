
(() => {
  const root = document.getElementById('layered-note-preview');
  const deck = root.querySelector('.ln-deck');
  const template = root.querySelector('.ln-card-template');
  const live = root.querySelector('.ln-live');
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const preferences = { duration: 1000, fan: 14, noteAngle: -7 };
  const {clamp, lerp, smooth, pose, transform} = PaperMotion;
  const send = (op, payload={}) => window.webkit?.messageHandlers.study.postMessage({op,roundID:session?.id,...payload});
  const library = root.querySelector('.ln-library');
  let generation=0;
  let session;
  let actionCardID = null;
  let deferredPatches = [];
  let geometry;
  let busy = false;
  let queuedDirection = 0;
  let drag = null;
  let dragFrame = 0;
  let geometryDirty = false;
  let wheelTotal = 0;
  let wheelLocked = false;
  let wheelTimer;
  let selectionSurface=null;
  let surfaceCards=null;
  let revealTransition=null;
  let roundTransition=null;
  let startRequested=false;
  let feedback=null,feedbackTimer;
  const allAnimations = new Set();
  const currentCards = () => session.cards;
  const currentIndex = () => session.index;
  const currentCard = () => currentCards()[currentIndex()];
  const slot = (index, front=currentIndex()) => PaperMotion.slot(index,front,currentCards().length);
  const cardCaption=card=>(card.language==='en'?'英语':'日语')+' · '+({introduction:'初识',recall:'回想',review:'复习',retry:'再想一次',browse:'词库'}[card.data.kind]||'词汇')+(card.data.enrichmentStatus==='loading'?' · 正在补全…':card.data.enrichmentStatus==='queued'?' · 等待补全…':card.data.enrichmentStatus==='failed'?' · AI 暂未补全':'');
  function renderFeedback() {
    for(const card of session.allCards){
      const label=card.node.querySelector('.ln-language');
      const message=card===currentCard()?feedback?.text:null;
      label.textContent=message||cardCaption(card);
      label.classList.toggle('has-feedback',!!message);
      label.title=message||card.data.enrichmentError||'';
    }
    const caption=root.querySelector('.ln-complete-caption');
    caption.textContent=session.ended&&feedback?feedback.text:(caption.dataset.caption||'学习安排');
    const heading=library.querySelector('h2');heading.title=feedback?.text||'';
    const status=library.querySelector('.ln-library-status');
    status.textContent=feedback?.text||'';status.hidden=!feedback;
  }
  function announce(text,persistent=false) {
    clearTimeout(feedbackTimer);
    feedback=text?{text,persistent}:null;
    if(text)live.textContent=text;
    renderFeedback();
    if(text&&!persistent)feedbackTimer=setTimeout(()=>{feedback=null;renderFeedback();},4200);
  }
  // Decide ownership at pointer-down, before a paper gesture can capture a
  // native text selection. Inline content regions follow the rendered text
  // lines; their block containers and padding remain available to the paper.
  const nativeInteraction = target => target.closest('button,textarea,input,select,a,[contenteditable="true"],.ln-selectable,.ln-paper-head');
  const modified = event => event.metaKey || event.ctrlKey || event.altKey || event.shiftKey;
  function hasCardSelection() {
    const selection=window.getSelection();
    return selection?.rangeCount && !selection.isCollapsed && currentCard() && selection.getRangeAt(0).intersectsNode(currentCard().node);
  }
  function selectVisibleText() {
    const editor=document.activeElement;
    if(editor.matches('input,textarea')) {editor.select();return;}
    if(busy || drag)return;
    const card=currentCard();
    const surface=!library.hidden?library:reading.state?.target||(card?.node.contains(selectionSurface)?selectionSurface:card?.paper);
    if(!surface)return;
    const selector=library.hidden?'.ln-selectable':'.ln-library-result span';
    const content=[...surface.querySelectorAll(selector)].filter(node=>node.textContent && node.getClientRects().length);
    const selection=window.getSelection();
    if(!content.length){selection.removeAllRanges();return;}
    // Keep a single native range inside this paper, excluding covered cards,
    // header controls, hidden answers and the separate draft editor.
    const first=content[0],last=content.at(-1);
    selection.setBaseAndExtent(first,0,last,last.childNodes.length);
  }
  function setText(node, selector, value) {
    const container=node.querySelector(selector);
    const target=container.querySelector('.ln-selectable')||container;
    if(target.textContent!==value)target.textContent=value;
  }
  const surfaces=PaperSurfaces.create({root,send,isMoving:()=>busy||reading.animations.length>0,getSurfaces:()=>{
    if(!library.hidden)return [library];
    if(roundTransition)return roundTransition.surfaces;
    if(session.ended)return [root.querySelector('.ln-complete')];
    // Measure the exposed poses at each end of a handoff. Covered sheets share
    // their trajectory, so a long round does not multiply this work.
    return (surfaceCards||currentCards().filter(card=>slot(card.index)<3)).flatMap(card=>[card.paper,card.note,...(revealTransition?.card===card?revealTransition.surfaces:[])]);
  }});
  const reading=PaperReader.create({root,deck,live,reduceMotion,getGeometry:()=>geometry,isBusy:()=>busy||!!actionCardID||!!drag,isEnded:()=>session.ended,currentCard,resetWheel,onLayout:placeWindowControls});
  const closeReading=(animated=true)=>{finishRoundEntrance(false);finishReveal(false);reading.close(animated);surfaces.invalidate();};
  const toggleReading=(card,kind)=>{if(kind==='note'&&!card.data.revealed)return;reading.toggle(card,kind);surfaces.invalidate();};
  function addMessage(card, role, content) {
    const item=document.createElement('div');
    item.className=`ln-message ${role}`;
    item.setAttribute('role','group');
    item.setAttribute('aria-label',role==='user'?'你的留言':'回复');
    if(role==='assistant' && !content)item.classList.add('is-pending');
    const paragraph=document.createElement('p'),body=document.createElement('span');
    body.className='ln-selectable'; body.textContent=content;
    paragraph.append(body); item.append(paragraph); card.node.querySelector('.ln-feed').append(item);
    return {item,body};
  }
  function followReply(card) {
    if(card.followTail && !card.node.hidden) card.scroll.scrollTop=card.scroll.scrollHeight;
  }
  function cancelReplies(card) { card.pending.clear(); }
  function submitQuestion(card, raw) {
    if(busy || session.ended || card!==currentCard() || !card.data.revealed) return;
    const question=raw.trim(); if(!question || card.pending.size>=5) return;
    const requestID=crypto.randomUUID();
    addMessage(card,'user',question);
    const letter=addMessage(card,'assistant','');
    letter.item.classList.add('is-writing'); letter.item.setAttribute('aria-busy','true');
    card.pending.set(requestID,{letter,question,text:''});
    card.input.value=''; card.input.placeholder='接着写…';
    card.inputSize.textContent=card.input.placeholder;
    card.followTail=true; followReply(card);
    card.status.textContent='留言已寄出。';
    send('question',{cardID:card.id,requestID,question});
  }
  function renderWord(card) {
    const data=card.data, shown=data.revealed, word=card.word;
    card.node.classList.toggle('is-unrevealed',!shown);
    card.paper.classList.toggle('is-question-face',!shown);
    card.node.setAttribute('aria-label',shown?`${word.word} 学习卡片`:'回想词卡');
    card.note.hidden=!shown;
    const heading=card.node.querySelector('.ln-word');
    heading.classList.toggle('is-prompt',!shown && data.direction==='meaningToWord');
    heading.lang=!shown && data.direction==='meaningToWord'?'zh-CN':card.language;
    setText(card.node,'.ln-word',shown || data.direction==='wordToMeaning'?word.word:word.definition);
    card.node.querySelector('.ln-reading').hidden=!shown;
    const definition=card.node.querySelector('.ln-definition');
    definition.classList.toggle('is-prompt',!shown);
    const missingMeaning=!word.definition.trim();
    definition.classList.toggle('is-missing',shown&&missingMeaning);
    const missingLabel=data.enrichmentStatus==='loading'?'正在补全中文释义…':data.enrichmentStatus==='queued'?'等待补全中文释义…':data.enrichmentStatus==='failed'?'暂未取得中文释义，可从学习菜单用 AI 重试。':'词库暂未提供中文释义。';
    setText(card.node,'.ln-definition',shown?(word.definition||missingLabel):(missingMeaning?'试着读出这个词，翻面核对读音。':data.direction==='meaningToWord'?'试着想起这个单词。':'试着想起它的中文意思。'));
    card.node.querySelector('.ln-example').hidden=!shown;
    for(const [selector,key] of [['.ln-phonetic','reading'],['.ln-pos','pos'],['.ln-original','example'],['.ln-translation','translation']]) setText(card.node,selector,word[key]);
    card.node.querySelector('.ln-language').textContent=cardCaption(card);
    const actions=card.node.querySelector('.ln-study-actions'); actions.replaceChildren();
    actions.hidden=data.kind==='introduction';
    actions.classList.toggle('is-reveal',!shown);
    if(actions.hidden)return;
    function button(text,action,primary=false) { const b=document.createElement('button'); b.type='button'; b.textContent=text; if(primary)b.className='primary'; b.addEventListener('click',action); actions.append(b); }
    if(data.graded){const label=document.createElement('span');label.className='graded';label.textContent='已记下这次复习';actions.append(label);}
    else if(data.kind==='browse'){
      button('加入本轮记忆',()=>requestAction(card,'practice'),true);
      button('返回学习',()=>requestAction(card,'returnToStudy'));
    }
    else if(!shown)button('看看答案',()=>requestAction(card,'reveal'),true);
    else for(const [label,grade] of [['再想想',1],['有点难',3],['记得',4],['很熟悉',5]])button(label,()=>requestAction(card,'grade',{grade}));
  }
  function makeCard(data,language,index) {
    const word=data.word;
    const node=template.content.firstElementChild.cloneNode(true);
    const card={id:data.id,data,word,language,index,node,pending:new Map(),followTail:true};
    node.dataset.cardId=card.id;
    node.setAttribute('aria-label',`${word.word} 学习卡片`);
    setText(node,'.ln-language',language==='en'?'英语词汇':'日语词汇');
    setText(node,'.ln-card-number',`${String(index+1).padStart(2,'0')} / 03`);
    for(const [selector,key] of [['.ln-word','word'],['.ln-phonetic','reading'],['.ln-pos','pos'],['.ln-definition','definition'],['.ln-original','example'],['.ln-translation','translation']]) setText(node,selector,word[key]);
    for(const selector of ['.ln-word','.ln-original','.ln-phonetic']) node.querySelector(selector).lang=language;
    card.note=node.querySelector('.ln-question-note');
    card.paper=node.querySelector('.ln-paper');
    card.ground=node.querySelector('.ln-ground-shadow');
    card.elevation=node.querySelector('.ln-elevation');
    card.input=node.querySelector('textarea');
    card.inputSize=node.querySelector('.ln-compose-size');
    card.scroll=node.querySelector('.ln-scroll');
    card.status=node.querySelector('.ln-letter-status');
    card.input.setAttribute('aria-label',`给 ${word.word} 留言`);
    card.note.setAttribute('aria-label',`${word.word} 的往来纸条`);
    for(const [kind,paper] of [['word',card.paper],['note',card.note]]) {
      paper.id=`${card.id}-${kind}`;
      const control=paper.querySelector(`[data-zoom="${kind}"]`);
      control.setAttribute('aria-controls',paper.id);
      control.addEventListener('click',()=>toggleReading(card,kind));
      paper.addEventListener('dblclick',event=>{
        if(event.button!==0 || modified(event) || nativeInteraction(event.target))return;
        event.preventDefault();event.stopPropagation();
        toggleReading(card,kind);
      });
    }
    card.scroll.addEventListener('scroll',()=>{
      if(card.node.hidden)return;
      card.followTail=card.scroll.scrollHeight-card.scroll.clientHeight-card.scroll.scrollTop<24;
    },{passive:true});
    card.input.addEventListener('input',()=>{card.inputSize.textContent=card.input.value||card.input.placeholder;});
    card.input.addEventListener('keydown',event=>{
      if(event.key==='Enter' && !event.shiftKey && !event.isComposing && event.keyCode!==229) {event.preventDefault();submitQuestion(card,card.input.value);}
    });
    node.querySelector('.ln-compose').addEventListener('submit',event=>{event.preventDefault();submitQuestion(card,card.input.value);});
    card.paper.addEventListener('pointerdown',event=>startDrag(event,card));
    card.paper.addEventListener('pointermove',moveDrag);
    card.paper.addEventListener('pointerup',finishDrag);
    card.paper.addEventListener('pointercancel',cancelDrag);
    card.paper.addEventListener('lostpointercapture',event=>{if(drag?.id===event.pointerId) cancelDrag();});
    node.querySelector('.ln-paper-head').addEventListener('pointerdown',event=>{ if(event.button===0 && !modified(event) && !event.target.closest('button') && !reading.state) {event.preventDefault();event.stopPropagation();send('moveWindow');} });
    renderWord(card);
    deck.append(node);
    surfaces.prepare([card.paper,card.note]);
    return card;
  }
  function replaceSession(payload) {
    const keepLibrary=!!payload.preserveLibrary && !library.hidden;
    const searchSelection=keepLibrary?[searchInput.selectionStart,searchInput.selectionEnd]:null;
    const animateEntry=(startRequested||payload.animateEntry) && session?.id && library.hidden && !reduceMotion.matches && !document.hidden;
    closeReading(false);
    const summary=animateEntry?PaperReveal.capture(session.ended?root.querySelector('.ln-complete'):currentCard().paper):null;
    generation++;
    if(roundTransition){roundTransition.cancel();roundTransition=null;}
    if(revealTransition){revealTransition.cancel();revealTransition=null;}
    selectionSurface=null;
    closeReading(false); detachDrag(); clearAnimations(); resetWheel();
    busy=false; queuedDirection=0; actionCardID=null; deferredPatches=[]; startRequested=false;
    if(session)for(const card of session.allCards){cancelReplies(card);card.node.remove();}
    clearTimeout(searchTimer); activeSearchID=null;
    library.hidden=!keepLibrary; deck.inert=keepLibrary;
    session={id:payload.roundID,allCards:[],cards:[],language:payload.language,index:0,ended:false,view:'study'};
    session.allCards=payload.cards.map((data,index)=>makeCard(data,payload.language,index));
    selectView(payload,payload.currentID);
    renderRoundMessage(payload);
    library.querySelector('h2').textContent=payload.language==='ja'?'日语词库':'英语词库';
    calculateGeometry();
    announce(keepLibrary?'':payload.announcement||'');
    if(keepLibrary){
      searchResults.replaceChildren();searchComposing=false;requestSearch();
      searchInput.focus({preventScroll:true});searchInput.setSelectionRange(...searchSelection);
    }else root.focus({preventScroll:true});
    if(summary){
      busy=true;renderControls();
      const cards=[...currentCards()].sort((a,b)=>slot(a.index)-slot(b.index));
      const transition=cards.length?PaperRound.start(cards,summary,geometry):PaperRound.startSummary(root.querySelector('.ln-complete'),summary);
      roundTransition=transition;surfaces.prepare(transition.preparedSurfaces);surfaces.invalidate();
      transition.finished.then(()=>{if(roundTransition===transition)finishRoundEntrance();});
    }
  }
  function finishRoundEntrance(resume=true) {
    const transition=roundTransition;if(!transition)return;
    roundTransition=null;transition.cancel();busy=false;
    applyRest();
    if(geometryDirty)calculateGeometry();
    live.textContent='新一轮已准备好。';
    const pending=queuedDirection;queuedDirection=0;
    flushPatches();
    if(resume && pending && !busy)requestSwitch(pending);
  }
  function renderRoundMessage(payload) {
    const note=root.querySelector('.ln-complete');
    note.querySelector('.ln-complete-caption').dataset.caption=payload.caption||'学习安排';
    note.querySelector('.ln-complete-language').textContent=session.language==='en'?'英语':'日语';
    note.querySelector('h2').textContent=payload.title||'暂时没有待学词卡';
    note.querySelector('.ln-summary').textContent=payload.summary||'可以到词库看看，\n或在菜单中调整学习安排。';
    const detail=note.querySelector('.ln-complete-detail');
    detail.textContent=payload.detail||'';detail.hidden=!payload.detail;
    renderFeedback();
  }
  function selectView(payload,target) {
    session.view=payload.view||session.view;
    session.pendingID=payload.pendingID||null;
    const byID=new Map(session.allCards.map(card=>[card.id,card]));
    session.cards=payload.visibleIDs?payload.visibleIDs.map(id=>byID.get(id)).filter(Boolean):session.allCards;
    for(const card of session.allCards)card.index=-1;
    currentCards().forEach((card,index)=>{card.index=index;});
    session.index=Math.max(0,currentCards().findIndex(card=>card.id===target));
    session.ended=currentCards().length===0;
  }
  function requestAction(card,op,extra={}) {
    if(busy || actionCardID || card!==currentCard())return;
    actionCardID=card.id;
    for(const button of card.node.querySelectorAll('.ln-study-actions button'))button.disabled=true;
    send(op,{cardID:card.id,...extra});
  }
  function applyPatch(payload) {
    const visibleID=currentCard()?.id;
    const active=currentCard(),next=payload.cards.find(card=>card.id===visibleID);
    const turning=active && next && !active.data.revealed && next.revealed && (!payload.focusID || payload.focusID===visibleID) && !reduceMotion.matches && !document.hidden;
    const prompt=turning?PaperReveal.capture(active.paper):null;
    // Disabling a clicked action can move WebKit focus to the document before
    // its native reply arrives. The pending action still owns that focus.
    const restoreActionFocus=active?.paper.contains(document.activeElement)||actionCardID===visibleID;
    const previous=new Map(session.allCards.map(card=>[card.id,card]));
    session.allCards=payload.cards.map((data,index)=>{
      const card=previous.get(data.id)||makeCard(data,session.language,index);
      if(JSON.stringify(card.data)!==JSON.stringify(data)) {
        card.data=data; card.word=data.word; renderWord(card);
      }
      card.index=index; previous.delete(data.id);
      return card;
    });
    for(const card of previous.values()){
      if(reading.state?.card===card)closeReading(false);
      cancelReplies(card);card.node.remove();
    }
    const target=payload.focusID||visibleID||payload.currentID;
    if(payload.focusID && payload.focusID!==visibleID)closeReading(false);
    selectView(payload,target);
    if(active && active!==currentCard()){
      closeReading(false);
      window.getSelection().removeAllRanges();
      selectionSurface=null;
      root.focus({preventScroll:true});
    }
    actionCardID=null;
    for(const card of session.allCards)for(const button of card.node.querySelectorAll('.ln-study-actions button'))button.disabled=false;
    applyRest();
    renderRoundMessage(payload);
    if(payload.announcement)announce(payload.announcement);
    if(prompt) {
      busy=true;renderControls();
      if(restoreActionFocus)root.focus({preventScroll:true});
      const transition=PaperReveal.start(active,prompt);
      transition.restoreFocus=restoreActionFocus;
      revealTransition=transition;surfaces.prepare(transition.surfaces);surfaces.invalidate();
      transition.finished.then(()=>{if(revealTransition===transition)finishReveal();});
    } else if(currentCard() && restoreActionFocus && !document.activeElement.closest('.ln-assembly')) {
      focusAfterReveal(currentCard());
    }
    if(payload.advanceFrom===currentCard()?.id) { closeReading(false); requestSwitch(1,null,true); }
  }
  function focusAfterReveal(card) {
    const target=root.classList.contains('has-keyboard-focus')?card.paper.querySelector('.ln-study-actions button'):root;
    (target||root).focus({preventScroll:true});
  }
  function finishReveal(resume=true) {
    const transition=revealTransition;if(!transition)return;
    revealTransition=null;transition.cancel();busy=false;
    applyRest(true);
    if(geometryDirty)calculateGeometry();
    if(transition.restoreFocus && transition.card===currentCard())focusAfterReveal(transition.card);
    live.textContent='答案已揭晓，可以评价记忆程度或在纸条上追问。';
    const pending=queuedDirection;queuedDirection=0;
    flushPatches();
    if(resume && pending && !busy)requestSwitch(pending);
  }
  function flushPatches() {
    while(deferredPatches.length && !busy && !drag)applyPatch(deferredPatches.shift());
  }
  function placeWindowControls(rect=null) {
    if(!rect && !library.hidden)rect=library.getBoundingClientRect();
    if(geometry)send('windowControlsLayout',{right:rect?.right??geometry.left+geometry.w,top:rect?.top??geometry.top,controlsEnabled:library.hidden});
    surfaces.invalidate();
  }
  function calculateGeometry() {
    if(roundTransition)finishRoundEntrance(false);
    if(busy || drag) {geometryDirty=true;return;}
    closeReading(false);
    const width=root.clientWidth;
    const narrow=width<620;
    const compact=width<500;
    const h=narrow?480:466;
    const nw=compact?Math.min(304,width-60):clamp(width*.42,248,304);
    const nh=narrow?208:224;
    const noteSine=Math.abs(Math.sin(preferences.noteAngle*Math.PI/180));
    const noteCosine=Math.cos(preferences.noteAngle*Math.PI/180);
    const noteOverhang=(nw-26)*(noteCosine-1)+(nh-22)*noteSine;
    const preferredWidth=clamp((width-100)*.7,330,400);
    const sideBySideWidth=width-nw+104-noteOverhang-40;
    const w=compact?Math.min(360,width-56):Math.min(preferredWidth,sideBySideWidth);
    const nx=compact?w-nw-12:w-104;
    const ny=compact?h-68:267;
    const notePaddingX=16+noteSine*nh/2;
    const notePaddingY=15+noteSine*nw/2;
    const guard=Math.min(84,width*.12);
    const extent=nx+nw;
    const left=compact?(width-w)/2:Math.min((width-(guard+extent+24))/2+guard,width-extent-noteOverhang-12);
    const top=Math.max(48,Math.min(110,(root.clientHeight-h)/2-18));
    const spread=compact?8:clamp((width-420)*.09,8,27);
    const safeFan=Math.atan2(Math.max(5,left-spread-8)*2,h)*180/Math.PI;
    const fan=Math.min(preferences.fan,safeFan);
    geometry={width,w,h,left,top,narrow,spread,fan,nw,nh,nx,ny,noteAngle:preferences.noteAngle};
    deck.style.perspective=`${PaperMotion.perspective}px`;
    root.classList.toggle('is-narrow',narrow);
    root.classList.toggle('is-compact',compact);
    for(const [key,value] of Object.entries({'card-w':w,'card-h':h,'card-left':left,'card-top':top,'note-w':nw,'note-h':nh,'note-x':nx,'note-y':ny,'note-padding-x':notePaddingX,'note-padding-y':notePaddingY})) root.style.setProperty(`--ln-${key}`,`${value}px`);
    root.style.setProperty('--ln-note-angle',`${preferences.noteAngle}deg`);
    deck.style.height=`${Math.ceil(top+Math.max(h+40,ny+nh+16))}px`;
    geometryDirty=false;
    placeWindowControls();
    if(session) applyRest();
  }
  function restPose(position) { return PaperMotion.rest(position,geometry); }
  function applyRest(preserveLayers=false) {
    surfaceCards=null;
    deck.style.transform='';
    for(const card of session.allCards)if(card.index<0){
      card.node.hidden=true;card.node.inert=true;
      card.node.classList.remove('is-front');
      card.node.setAttribute('aria-hidden','true');
    }
    for(const card of currentCards()) {
      const position=slot(card.index);
      const isFront=!session.ended && position===0;
      // Keep covered papers painted. Toggling display at a coincident edge
      // changes its antialiasing even when no text is exposed (L-0001).
      card.node.hidden=session.ended;
      card.node.classList.toggle('is-front',isFront);
      card.node.classList.toggle('is-covered',position>2);
      card.node.classList.remove('is-dragging');
      card.node.inert=!isFront;
      card.node.setAttribute('aria-hidden',String(!isFront));
      card.node.style.transform=transform(restPose(position));
      if(!preserveLayers)card.node.style.zIndex=String((currentCards().length-position)*10);
      card.node.style.willChange='';
      card.elevation.style.opacity='0';
      if(reading.state?.card!==card || reading.state.kind!=='note')card.note.style.transform='';
      card.ground.style.setProperty('--ln-rest-opacity',!session.ended && position<3?'1':'0');
      card.note.style.setProperty('--ln-rest-opacity',isFront?'1':'0');
      if(isFront)followReply(card);
    }
    reading.syncOrder(currentCards().map(card=>card.node));
    renderControls();
    renderFeedback();
    surfaces.invalidate();
  }
  function renderControls() {
    const count=currentCards().length;
    root.querySelector('.ln-end').disabled=busy || session.ended;
    root.querySelector('.ln-start').disabled=busy || startRequested;
    root.querySelector('.ln-complete').hidden=!session.ended;
    for(const card of currentCards())setText(card.node,'.ln-card-number',`${String(card.index+1).padStart(2,'0')} / ${String(count).padStart(2,'0')}`);
  }
  function animate(node,keyframes,options) {
    const animation=node.animate(keyframes,{fill:'both',...options});
    allAnimations.add(animation);
    return animation.finished.catch(()=>{});
  }
  function clearAnimations() {
    for(const animation of allAnimations) animation.cancel();
    allAnimations.clear();
  }
  async function requestSwitch(direction,fromDrag=null,automatic=false) {
    if(reading.state){announce('先按 Esc 还原便笺，再切换词卡。');return;}
    if(!library.hidden){announce('先选择词条，或关闭词库继续学习。');return;}
    if(session.ended){announce('本轮已结束，可以开始新一轮。');return;}
    if(actionCardID){announce('正在保存，请稍候…');return;}
    if(busy){queuedDirection=direction;return;}
    const oldIndex=currentIndex();
    let newIndex=oldIndex+direction,returning=false;
    // Manual navigation is circular in both views. Only an acknowledged grade
    // may advance to unfinished work or request completion of the round.
    if(!automatic || session.view==='library'){
      const count=currentCards().length;
      if(count<2){if(fromDrag)await returnToStack(fromDrag.pose);announce('当前只有一张词卡。');return;}
      newIndex=(newIndex+count)%count;
    }
    if(newIndex<0){if(fromDrag)await returnToStack(fromDrag.pose);return;}
    if(newIndex>=currentCards().length){
      const pending=currentCards().findIndex(card=>card.id===session.pendingID);
      if(pending<0 || pending===oldIndex){
        const token=generation;
        if(fromDrag)await returnToStack(fromDrag.pose);
        if(token===generation && session.view!=='library'){
          if(pending<0)send('completeRound');
          else announce('这张词卡还未完成。');
        }
        return;
      }
      newIndex=pending;returning=true;
    }
    // Move focus off a paper before it becomes inert, including grade and
    // reading controls used by keyboard. The next arrow must still reach us.
    root.focus({preventScroll:true});
    if(reduceMotion.matches){
      session.index=newIndex;applyRest();send('navigate',{cardID:currentCard().id});
      live.textContent=`${returning?'回到未完成的词卡。':''}第 ${newIndex+1} 张，${currentCard().word.word}`;
      return;
    }
    busy=true;renderControls();
    const token=generation, cards=currentCards(), promises=[],stackFrames=[];
    surfaceCards=cards.filter(card=>slot(card.index,oldIndex)<3||slot(card.index,newIndex)<3);
    const path=PaperMotion.flight(geometry);
    const handoff=PaperMotion.handoff(oldIndex,newIndex,cards.map(card=>Number(card.node.style.zIndex)),direction);
    const exchanges=new Map(handoff.changes.map(change=>[change.index,change]));
    const duration=preferences.duration-(fromDrag?Math.min(40,Math.abs(fromDrag.velocity)*30):0);
    for(const card of cards){
      const before=slot(card.index,oldIndex), after=slot(card.index,newIndex);
      // Stationary papers keep their existing paint order, including covered ones.
      if(before>2 && after>2 && !exchanges.has(card.index))continue;
      card.node.inert=true;
      const transforms=[],notes=[],notePositions=[],shadows=[],ambient=[];
      for(let frame=0;frame<=60;frame++){
        const offset=frame/60;
        const value=PaperMotion.sample({index:card.index,from:oldIndex,to:newIndex,count:cards.length,geometry,drag:fromDrag?.pose,path,direction},offset);
        if(card.index===handoff.index)stackFrames.push({offset,transform:`translate3d(${value.shift}px,0,0)`});
        transforms.push({offset,transform:transform(value.pose)});
        notes.push({offset,opacity:value.note});
        notePositions.push({offset,transform:PaperMotion.noteTransform(value.noteX)});
        shadows.push({offset,opacity:value.shadow});
        ambient.push({offset,opacity:value.ambient});
      }
      if(transforms.some(frame=>frame.transform!==transforms[0].transform)){
        card.node.style.willChange='transform';
        promises.push(animate(card.node,transforms,{duration,easing:'linear'}));
      }
      // Only picked-up papers exchange layers, together at clearance. A tail
      // return carries skipped papers underneath without exposing a focus jump.
      const exchange=exchanges.get(card.index);
      if(exchange)promises.push(animate(card.node,[
        {offset:0,zIndex:exchange.start,easing:'steps(1,end)'},
        {offset:.5,zIndex:exchange.end},{offset:1,zIndex:exchange.end}
      ],{duration,easing:'linear'}));
      for(const [node,frames] of [[card.note,notes],[card.elevation,shadows],[card.ground,ambient]])
        if(frames.some(frame=>frame.opacity!==frames[0].opacity))promises.push(animate(node,frames,{duration,easing:'linear'}));
      if(notePositions.some(frame=>frame.transform!==notePositions[0].transform))promises.push(animate(card.note,notePositions,{duration,easing:'linear'}));
    }
    promises.push(animate(deck,stackFrames,{duration,easing:'linear'}));
    surfaces.invalidate();
    await Promise.all(promises);
    if(token!==generation)return;
    session.index=newIndex;
    // Set the final inline pose before removing animation effects.
    for(const change of handoff.changes)cards[change.index].node.style.zIndex=String(change.end);
    applyRest(true);clearAnimations();busy=false;renderControls();
    send('navigate',{cardID:currentCard().id});
    if(geometryDirty)calculateGeometry();
    live.textContent=`${returning?'回到未完成的词卡。':''}第 ${newIndex+1} 张，${currentCard().word.word}`;
    const pending=queuedDirection;queuedDirection=0;
    flushPatches();
    if(pending && !busy)requestSwitch(pending);
  }
  async function returnToStack(from) {
    if(reduceMotion.matches){applyRest();flushPatches();return;}
    busy=true;renderControls();
    surfaces.invalidate();
    const card=currentCard(), token=generation;
    const paperFrames=[],noteFrames=[],shadowFrames=[];
    const shadowOpacity=Number(card.elevation.style.opacity);
    for(let i=0;i<=60;i++){
      // Reach one exact resting pose before dropping the animation effects.
      // A residual interpolated 3D scale can rerasterize text at fractional
      // window coordinates even when the final rectangles already agree.
      const offset=i/60,progress=smooth(offset/.94),position=PaperMotion.mix(from,pose(),progress);
      paperFrames.push({offset,transform:transform(position)});
      noteFrames.push({offset,transform:PaperMotion.noteTransform(PaperMotion.dockNote(position,geometry))});
      shadowFrames.push({offset,opacity:shadowOpacity*(1-progress)});
    }
    const options={duration:clamp(320+Math.abs(from.x)*1.1,380,520),easing:'linear'};
    await Promise.all([
      animate(card.node,paperFrames,options),
      animate(card.note,noteFrames,options),
      animate(card.elevation,shadowFrames,options)
    ]);
    if(token!==generation)return;
    applyRest();clearAnimations();busy=false;renderControls();
    if(geometryDirty)calculateGeometry();
    const pending=queuedDirection;queuedDirection=0;
    flushPatches();if(pending && !busy)requestSwitch(pending);
  }
  function dragPose(state) {
    return PaperMotion.drag(state.dx,state.dy,geometry);
  }
  function paintDrag() {
    dragFrame=0;if(!drag?.locked)return;
    const position=dragPose(drag);
    drag.card.node.style.transform=transform(position);
    drag.card.note.style.transform=PaperMotion.noteTransform(PaperMotion.dockNote(position,geometry));
    drag.card.elevation.style.opacity=String(Math.min(.6,Math.abs(position.x)/geometry.w));
    surfaces.invalidate();
  }
  function startDrag(event,card) {
    if(reading.state || !library.hidden || busy || actionCardID || drag || session.ended || card!==currentCard() || event.button!==0 || modified(event) || nativeInteraction(event.target)) return;
    drag={card,id:event.pointerId,x:event.clientX,y:event.clientY,dx:0,dy:0,lastX:event.clientX,lastTime:event.timeStamp,velocity:0,locked:false};
  }
  function moveDrag(event) {
    if(!drag || drag.id!==event.pointerId)return;
    drag.dx=event.clientX-drag.x;drag.dy=event.clientY-drag.y;
    if(!drag.locked) {
      if(Math.abs(drag.dy)>8 && Math.abs(drag.dy)>Math.abs(drag.dx)) {drag=null;flushPatches();return;}
      if(Math.abs(drag.dx)<5 || Math.abs(drag.dx)<Math.abs(drag.dy)*1.1)return;
      drag.locked=true;drag.card.paper.setPointerCapture(event.pointerId);
      drag.card.node.classList.add('is-dragging');drag.card.node.style.willChange='transform';
    }
    event.preventDefault();
    const elapsed=event.timeStamp-drag.lastTime;
    if(elapsed>0) drag.velocity=drag.velocity*.35+(event.clientX-drag.lastX)/elapsed*.65;
    drag.lastTime=event.timeStamp;drag.lastX=event.clientX;
    if(!dragFrame) dragFrame=requestAnimationFrame(paintDrag);
  }
  function detachDrag() {
    if(dragFrame){cancelAnimationFrame(dragFrame);dragFrame=0;}
    const old=drag;drag=null;
    if(old) {
      old.card.node.classList.remove('is-dragging');
      if(old.card.paper.hasPointerCapture(old.id))old.card.paper.releasePointerCapture(old.id);
    }
    return old;
  }
  function finishDrag(event) {
    if(!drag || drag.id!==event.pointerId)return;
    if(!drag.locked){drag=null;flushPatches();return;}
    drag.dx=event.clientX-drag.x;drag.dy=event.clientY-drag.y;
    paintDrag();
    const old=detachDrag();
    const velocity=event.timeStamp-old.lastTime>90?0:old.velocity;
    const qualifies=Math.abs(old.dx)>Math.min(72,geometry.w*.23) || (Math.abs(velocity)>.48 && Math.abs(old.dx)>22);
    const from={pose:dragPose(old),velocity};
    if(qualifies) requestSwitch(old.dx<0?1:-1,from); else returnToStack(from.pose);
  }
  function cancelDrag() {
    if(!drag)return;
    const from=dragPose(drag);
    const old=detachDrag();
    if(old.locked)returnToStack(from);
    else {if(geometryDirty)calculateGeometry();flushPatches();}
  }
  function resetWheel() {wheelTotal=0;wheelLocked=false;clearTimeout(wheelTimer);}
  function endSession() { if(!busy && !session.ended)send('endRound'); }
  root.querySelector('.ln-end').addEventListener('click',endSession);
  root.querySelector('.ln-reading-shade').addEventListener('click',()=>closeReading());
  root.querySelector('.ln-start').addEventListener('click',()=>{
    if(busy || startRequested || !session.ended)return;
    startRequested=true;renderControls();send('startRound');
  });
  let searchTimer,activeSearchID=null,searchComposing=false;
  const searchInput=root.querySelector('.ln-search'),searchResults=root.querySelector('.ln-library-results');
  function closeLibrary(cancel=true){
    clearTimeout(searchTimer);activeSearchID=null;
    if(cancel)send('closeLibrary');
    library.hidden=true;deck.inert=false;placeWindowControls();root.focus();
  }
  library.querySelector('header').addEventListener('pointerdown',event=>{
    if(event.button!==0 || modified(event) || event.target.closest('button,input,a'))return;
    event.preventDefault();event.stopPropagation();send('moveWindow');
  });
  root.querySelector('.ln-library-close').addEventListener('click',()=>closeLibrary());
  function requestSearch(delay=0){
    clearTimeout(searchTimer);activeSearchID=crypto.randomUUID();
    searchResults.inert=true;searchResults.setAttribute('aria-busy','true');
    if(!searchResults.children.length){const hint=document.createElement('p');hint.className='ln-empty';hint.textContent='正在查找…';searchResults.append(hint);}
    const requestID=activeSearchID;
    const request=()=>{if(!library.hidden&&activeSearchID===requestID)send('search',{query:searchInput.value,requestID});};
    if(delay)searchTimer=setTimeout(request,delay);else request();
  }
  searchInput.addEventListener('compositionstart',()=>{searchComposing=true;clearTimeout(searchTimer);activeSearchID=null;searchResults.inert=true;send('cancelSearch');});
  searchInput.addEventListener('compositionend',()=>{searchComposing=false;requestSearch(120);});
  searchInput.addEventListener('input',event=>{if(!searchComposing&&!event.isComposing)requestSearch(120);});
  root.addEventListener('pointerdown',event=>{
    root.classList.remove('has-keyboard-focus');
    selectionSurface=event.target.closest('.ln-paper,.ln-question-note');
  },{capture:true});
  root.addEventListener('keydown',event=>{
    if(event.key==='Tab')root.classList.add('has-keyboard-focus');
    if(event.isComposing || event.keyCode===229)return;
    if((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && event.key.toLowerCase()==='a' && !event.target.closest('input,textarea,[contenteditable="true"]')) {
      event.preventDefault();selectVisibleText();return;
    }
    if(!library.hidden){if(event.key==='Escape'){event.preventDefault();closeLibrary();}return;}
    if(reading.state) {
      if(event.key==='Escape'){event.preventDefault();event.stopPropagation();closeReading();}
      if(event.key==='Tab') {
        const controls=[...reading.state.target.querySelectorAll('button:not(:disabled),textarea:not(:disabled)')];
        const first=controls[0],last=controls[controls.length-1];
        if(event.shiftKey && document.activeElement===first){event.preventDefault();last.focus();}
        else if(!event.shiftKey && document.activeElement===last){event.preventDefault();first.focus();}
      }
      return;
    }
    if(event.target.closest('textarea,input,select,[contenteditable="true"]'))return;
    if(event.repeat || modified(event) || hasCardSelection())return;
    if(event.key==='ArrowLeft'){event.preventDefault();requestSwitch(-1);}
    if(event.key==='ArrowRight'){event.preventDefault();requestSwitch(1);}
  });
  deck.addEventListener('wheel',event=>{
    if(reading.state || !library.hidden || session.ended || event.target.closest('.ln-question-note,.ln-example'))return;
    if(Math.abs(event.deltaX)<=Math.abs(event.deltaY)*1.2 || Math.abs(event.deltaX)<1)return;
    event.preventDefault();
    clearTimeout(wheelTimer);wheelTimer=setTimeout(resetWheel,220);
    if(wheelLocked)return;
    wheelTotal+=event.deltaX*(event.deltaMode===1?16:event.deltaMode===2?geometry.w:1);
    if(Math.abs(wheelTotal)>62){wheelLocked=true;requestSwitch(wheelTotal>0?1:-1);}
  },{passive:false});

  window.nativeReceive=payload=>{
    if(payload.type==='selectAll'){selectVisibleText();return;}
    if(payload.type==='round'){replaceSession(payload);return;}
    if(['patch','reply','search','actionFailed','feedback'].includes(payload.type) && payload.roundID!==session.id)return;
    if(payload.type==='feedback'){announce(payload.message,!!payload.persistent);return;}
    if(payload.type==='actionFailed'){
      actionCardID=null;startRequested=false;renderControls();
      for(const card of currentCards())for(const button of card.node.querySelectorAll('.ln-study-actions button'))button.disabled=false;
      return;
    }
    if(payload.type==='patch'){
      if(reading.animations.length){
        Promise.allSettled(reading.animations.map(animation=>animation.finished)).then(()=>window.nativeReceive(payload));
        return;
      }
      if(busy || drag)deferredPatches.push(payload);else applyPatch(payload);
      return;
    }
    if(payload.type==='navigate'){if(payload.direction)requestSwitch(payload.direction);return;}
    if(payload.type==='library'){closeReading(false);announce('');library.hidden=false;deck.inert=true;placeWindowControls();requestSearch();searchInput.focus();return;}
    if(payload.type==='search'){
      if(library.hidden||payload.requestID!==activeSearchID||payload.query!==searchInput.value)return;
      searchResults.replaceChildren();searchResults.inert=false;searchResults.removeAttribute('aria-busy');
      for(const word of payload.words){
        const row=document.createElement('button');row.type='button';row.className='ln-library-result';
        const entry=document.createElement('span');entry.className='ln-library-entry';
        const heading=document.createElement('span');heading.className='ln-library-word-line';
        const field=(name,value)=>{const span=document.createElement('span');span.className=name;span.textContent=value;return span;};
        heading.append(field('ln-library-word',word.text));
        if(word.pos?.trim())heading.append(field('ln-library-pos',word.pos));
        entry.append(heading);
        if(word.reading?.trim())entry.append(field('ln-library-reading',word.reading));
        row.append(entry,field('ln-library-meaning',word.definition||'暂无中文释义'));
        row.addEventListener('click',()=>{if(activeSearchID!==payload.requestID)return;closeLibrary(false);send('browse',{wordID:word.id,query:payload.query,requestID:payload.requestID});});
        searchResults.append(row);
      }
      if(!payload.words.length){const empty=document.createElement('p');empty.className='ln-empty';empty.textContent=payload.error||'没有找到词条。可以换个关键词，或从顶部菜单导入词库。';searchResults.append(empty);}return;
    }
    if(payload.type==='reply'){
      const card=session.allCards.find(c=>c.id===payload.cardID), pending=card?.pending.get(payload.requestID);
      if(!pending)return;
      if(payload.delta){pending.text+=payload.delta;if(!reduceMotion.matches){pending.letter.body.textContent=pending.text;pending.letter.item.classList.remove('is-pending');}}
      if(payload.done || payload.error){
        pending.letter.item.classList.remove('is-writing','is-pending');pending.letter.item.setAttribute('aria-busy','false');
        pending.letter.body.textContent=pending.text+(payload.error?(pending.text?'\n\n':'')+payload.error:'');
        if(payload.error){pending.letter.item.classList.add('error');const retry=document.createElement('button');retry.type='button';retry.textContent='再试一次';retry.addEventListener('click',()=>submitQuestion(card,pending.question));pending.letter.item.append(retry);}
        card.pending.delete(payload.requestID);card.status.textContent=payload.error||'收到回复。'+pending.text;
      }
      followReply(card);return;
    }
  };
  root.tabIndex=-1;
  session={id:null,allCards:[],cards:[],language:'en',index:0,ended:true,view:'study'};
  calculateGeometry();
  new ResizeObserver(()=>calculateGeometry()).observe(root);
  document.addEventListener('visibilitychange',()=>{if(document.hidden){finishRoundEntrance();finishReveal();for(const animation of allAnimations)animation.finish();for(const animation of reading.animations)animation.finish();}});
  reduceMotion.addEventListener('change',()=>{if(reduceMotion.matches){finishRoundEntrance();finishReveal();for(const animation of allAnimations)animation.finish();for(const animation of reading.animations)animation.finish();}});
  send('ready');
})();
