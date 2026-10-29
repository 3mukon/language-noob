async function runUIChecks(section) {
  const root=document.getElementById('layered-note-preview');
  const sent=window.testMessages=[];
  window.testUICheckProgress={section,paintCount:0,lastCheck:'starting'};
  const paint=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>{window.testUICheckProgress.paintCount++;resolve();})));
  const check=(value,message)=>{window.testUICheckProgress.lastCheck=message;if(!value)throw Error(message);};
  const front=()=>root.querySelector('.is-front');
  const rect=node=>{const r=node.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,left:r.left,right:r.right,top:r.top,bottom:r.bottom};};
  const near=(a,b,tolerance=1.5)=>['x','y','width','height'].every(key=>Math.abs(a[key]-b[key])<tolerance);
  const receive=payload=>window.nativeReceive(payload);
  let serial=0,fixture;
  async function load(count,start=0,extra={}) {
    const roundID=`00000000-0000-4000-8000-${String(++serial).padStart(12,'0')}`;
    const cards=Array.from({length:count},(_,i)=>({id:`10000000-0000-4000-8000-${String(i).padStart(12,'0')}`,kind:'introduction',direction:'meaningToWord',revealed:true,graded:false,
      word:{word:`word${i}`,reading:'/ˌser.ənˈdɪp.ə.ti/',definition:`释义 ${i}`,pos:'名词',example:`A sample sentence ${i}.`,translation:`例句 ${i}。`}}));
    fixture={type:'round',roundID,language:'en',cards,currentID:cards[start]?.id,...extra};
    receive(fixture);await paint();return fixture;
  }
  async function finish() {
    for(let i=0;i<6;i++){
      const animations=document.getAnimations().filter(a=>a.playState!=='finished');
      if(!animations.length){await paint();if(!document.getAnimations().some(a=>a.playState!=='finished'))return;}
      for(const a of animations)a.finish();
      await paint();
    }
    check(false,'animations failed to settle');
  }
  async function seek(fraction) {
    for(const a of document.getAnimations()){a.pause();a.currentTime=a.effect.getTiming().duration*fraction;}
    await paint();
  }

  // The native window needs transformed paper outlines, not its viewport or
  // rectangular envelopes. Compare bridge geometry against WebKit paint bounds.
  function checkSurfaceMap(label){
    const layout=window.testSurfaceLayout;
    check(layout&&layout.width===root.clientWidth&&layout.height===root.clientHeight,`surface viewport follows layout: ${label}`);
    check(layout.polygons.length<=6,'input geometry is bounded independently of round length');
    const boxes=layout.polygons.map(points=>({left:Math.min(...points.map(p=>p.x)),right:Math.max(...points.map(p=>p.x)),top:Math.min(...points.map(p=>p.y)),bottom:Math.max(...points.map(p=>p.y))}));
    const same=(a,b)=>['left','right','top','bottom'].every(key=>Math.abs(a[key]-b[key])<.6);
    const library=root.querySelector('.ln-library'),complete=root.querySelector('.ln-complete');
    const surfaces=!library.hidden?[library]:!complete.hidden?[complete]:[...root.querySelectorAll('.ln-paper,.ln-question-note')].filter(node=>node.getClientRects().length&&+getComputedStyle(node).opacity>.005);
    for(const node of surfaces)check(boxes.some(box=>same(box,rect(node))),`native outline follows a visible ${node.className}: ${label}; painted=${JSON.stringify(rect(node))}; reported=${JSON.stringify(boxes)}`);
    for(const box of boxes)check(surfaces.some(node=>same(box,rect(node))),`native outline cannot retain hidden or stale paper: ${label}`);
    check(boxes.every(box=>box.bottom<root.clientHeight-4),`transparent bottom margin is excluded: ${label}`);
  }
  if(section==='interaction'){
  {
  await load(3,1);
  const savedStudy=front(),studyEditor=savedStudy.querySelector('textarea'),studyID=savedStudy.dataset.cardId;
  studyEditor.value='学习中的追问';
  studyEditor.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));await paint();
  const studyRequest=sent.filter(message=>message.op==='question').at(-1);
  studyEditor.value='学习草稿';studyEditor.dispatchEvent(new Event('input',{bubbles:true}));
  const libraryCards=fixture.cards.map((card,index)=>({...card,id:crypto.randomUUID(),kind:'browse',word:{...card.word,word:`entry${index}`}}));
  const ordered=[libraryCards[2],libraryCards[0],libraryCards[1]];
  const allCards=[...fixture.cards,...libraryCards];
  const search=root.querySelector('.ln-search');search.value='entry';
  receive({type:'library'});await paint();
  const staleSearch=sent.filter(message=>message.op==='search').at(-1);
  root.querySelector('.ln-library-close').click();
  receive({type:'library'});await paint();
  const currentSearch=sent.filter(message=>message.op==='search').at(-1);
  const searchPayload={type:'search',roundID:fixture.roundID,query:'entry',words:ordered.map(card=>({id:card.id,text:card.word.word,definition:card.word.definition}))};
  receive({...searchPayload,requestID:staleSearch.requestID});
  check(!root.querySelector('.ln-library-result'),'reopening the same query rejects a previous request identity');
  receive({...searchPayload,requestID:currentSearch.requestID});
  check(!root.querySelector('.ln-library-results').inert,'current search results restore interaction');
  root.querySelectorAll('.ln-library-result')[1].click();await paint();
  const browseRequest=sent.filter(message=>message.op==='browse').at(-1);
  check(browseRequest.wordID===libraryCards[0].id&&browseRequest.query==='entry'&&browseRequest.requestID===currentSearch.requestID,'selection carries the displayed result snapshot and selected word');
  const libraryPatch={...fixture,type:'patch',cards:allCards,view:'library',visibleIDs:ordered.map(card=>card.id)};
  receive({...libraryPatch,focusID:libraryCards[0].id});await paint();
  const retainedBrowse=front(),browseEditor=retainedBrowse.querySelector('textarea');
  browseEditor.value='词库草稿';browseEditor.dispatchEvent(new Event('input',{bubbles:true}));
  check(front().dataset.cardId===libraryCards[0].id&&front().querySelector('.ln-card-number').textContent==='02 / 03','selected result opens at its search position');
  check(savedStudy.hidden&&savedStudy.inert&&studyEditor.value==='学习草稿','hidden learning papers retain their editor and draft');
  check(root.querySelectorAll('.ln-assembly:not([hidden])').length===3,'only result papers appear in the browsing stack');
  receive({type:'reply',roundID:fixture.roundID,cardID:studyRequest.cardID,requestID:studyRequest.requestID,delta:'浏览期间收到的回复',done:true});await paint();
  const completions=sent.filter(message=>message.op==='completeRound').length;
  for(const reduced of [false,true]){
    window.testReducedMotion(reduced);
    receive({...libraryPatch,focusID:libraryCards[0].id});
    receive({type:'navigate',direction:-1});await finish();
    check(front().dataset.cardId===ordered[0].id,'previous library entry follows search order');
    for(const [direction,destination] of [[-1,2],[1,0]]){
      const outgoing=front();
      receive({type:'navigate',direction});
      if(reduced)check(!document.getAnimations().length,'reduced motion wraps without an animation');
      else{
        await seek(.5);
        check(document.getAnimations().some(animation=>animation.effect.target===outgoing),'library boundary uses a paper animation');
        check(front()===outgoing&&outgoing.inert,'library boundary retains and locks its outgoing paper until settlement');
        check(getComputedStyle(outgoing.querySelector('.ln-question-note')).opacity==='0','library boundary hides the outgoing note during motion');
        checkSurfaceMap('library boundary');
      }
      await finish();
      check(front().dataset.cardId===ordered[destination].id,'library boundary wraps in the requested direction');
      const layers=[...root.querySelectorAll('.ln-assembly:not([hidden])')].sort((a,b)=>Number(b.style.zIndex)-Number(a.style.zIndex));
      check(layers.every((node,depth)=>node.dataset.cardId===ordered[(destination+depth)%ordered.length].id),'wrapping retains the search-result stack order');
    }
    receive({type:'navigate',direction:1});await finish();
    receive({type:'navigate',direction:1});await finish();
    check(front().dataset.cardId===ordered[2].id,'next library entry follows search order');
    receive({type:'navigate',direction:1});await finish();
    check(front().dataset.cardId===ordered[0].id&&sent.filter(message=>message.op==='completeRound').length===completions,'repeated library wrapping never completes the learning round');
  }
  window.testReducedMotion(false);
  receive({type:'navigate',direction:-1});await seek(.3);
  receive({type:'navigate',direction:-1});await finish();
  check(front()===retainedBrowse&&browseEditor.value==='词库草稿','queued reverse input crosses the boundary without replacing the paper or draft');
  receive({...libraryPatch,visibleIDs:[libraryCards[0].id],focusID:libraryCards[0].id});await paint();
  check(front()===retainedBrowse&&browseEditor.value==='词库草稿'&&front().querySelector('.ln-card-number').textContent==='01 / 01','filtering to one result preserves its card and draft');
  check(root.querySelectorAll('.ln-assembly:not([hidden])').length===1,'one search result never shows an unrelated second card');
  for(const direction of [-1,1]){
    receive({type:'navigate',direction});await paint();
    check(front()===retainedBrowse&&!document.getAnimations().length&&sent.filter(message=>message.op==='completeRound').length===completions,'one library result stays in place without looping or finishing study');
  }
  [...front().querySelectorAll('.ln-study-actions button')].find(button=>button.textContent==='返回学习').click();await paint();
  check(sent.some(message=>message.op==='returnToStudy'&&message.cardID===retainedBrowse.dataset.cardId),'the paper offers an explicit return to learning');
  receive({...libraryPatch,view:'study',visibleIDs:fixture.cards.map(card=>card.id),focusID:studyID});await paint();
  check(front()===savedStudy&&studyEditor.value==='学习草稿'&&savedStudy.querySelector('.ln-feed').textContent.includes('浏览期间收到的回复'),'returning restores the original learning paper, draft and background reply');
  check(retainedBrowse.hidden&&retainedBrowse.inert,'library papers leave the learning stack and input regions');
  const retainedNodes=[...root.querySelectorAll('.ln-assembly')];
  await load(2);
  check(retainedNodes.every(node=>!node.isConnected),'replacing the round discards visible and inactive papers together');
  sent.length=0;
  }
  {
    await load(2);
    const library=root.querySelector('.ln-library'),search=root.querySelector('.ln-search');
    search.value='同一个查询';receive({type:'library'});await paint();
    search.setSelectionRange(1,3);
    const previousSearch=sent.filter(message=>message.op==='search').at(-1),previousRound=fixture.roundID;
    const japanese={...fixture,roundID:crypto.randomUUID(),language:'ja',preserveLibrary:true,animateEntry:true,announcement:'不应显示的新轮次提示'};
    receive(japanese);await paint();
    const currentSearch=sent.filter(message=>message.op==='search').at(-1);
    check(!library.hidden&&root.querySelector('.ln-deck').inert&&!document.getAnimations().length,'switching language retains the library and never animates to a study card');
    check(library.querySelector('h2').textContent==='日语词库'&&library.querySelector('.ln-library-status').hidden,'library language is persistent rather than a temporary round announcement');
    check(search.value==='同一个查询'&&document.activeElement===search&&search.selectionStart===1&&search.selectionEnd===3,'language switching preserves query, focus and selection');
    check(currentSearch.roundID===japanese.roundID&&currentSearch.query===search.value,'language replacement issues a query owned by the new round');
    receive({type:'search',roundID:previousRound,requestID:previousSearch.requestID,query:search.value,words:[{id:'stale',text:'old-language',definition:'过期'}]});
    check(!library.querySelector('.ln-library-result'),'previous-language results cannot return after replacement');
    receive({type:'search',roundID:japanese.roundID,requestID:currentSearch.requestID,query:search.value,words:[{id:'fresh',text:'空',reading:'そら',definition:'天空'}]});
    check(library.querySelector('.ln-library-word').textContent==='空','the retained panel receives only the selected-language results');
    const moves=()=>sent.filter(message=>message.op==='moveWindow').length;
    const before=moves();
    library.querySelector('h2').dispatchEvent(new PointerEvent('pointerdown',{button:0,bubbles:true,cancelable:true}));
    library.querySelector('header').dispatchEvent(new PointerEvent('pointerdown',{button:0,bubbles:true,cancelable:true}));
    await paint();
    check(moves()===before+2,'both the library heading and header whitespace drag the native window');
    for(const target of [search,library.querySelector('.ln-library-close'),library.querySelector('.ln-library-word')]){
      target.dispatchEvent(new PointerEvent('pointerdown',{button:0,bubbles:true,cancelable:true}));
    }
    library.querySelector('header').dispatchEvent(new PointerEvent('pointerdown',{button:2,bubbles:true,cancelable:true}));
    await paint();
    check(moves()===before+2,'editing, closing, selecting results and secondary clicks are not window drags');
    library.querySelector('.ln-library-close').click();
    await paint();
    check(sent.some(message=>message.op==='closeLibrary'&&message.roundID===japanese.roundID),'closing the library explicitly returns ownership to study');
    await load(2);
    const original=front(),pending=fixture.cards.map((card,index)=>index?card:{...card,enrichmentStatus:'loading',word:{...card.word,definition:''}});
    receive({...fixture,type:'patch',cards:pending.map(card=>({...card,enrichmentStatus:'queued'}))});await paint();
    check(front()===original&&front().querySelector('.ln-definition').textContent==='等待补全中文释义…'&&front().querySelector('.ln-language').textContent.includes('等待补全'),'queued preparation is distinct from an active request without replacing the paper');
    receive({...fixture,type:'patch',cards:pending});await paint();
    check(front()===original&&front().querySelector('.ln-definition').textContent==='正在补全中文释义…','automatic preparation is shown on the existing paper');
    const prepared=pending.map((card,index)=>index?card:{...card,enrichmentStatus:undefined,word:{...card.word,definition:'已经补全的释义'}});
    receive({...fixture,type:'patch',cards:prepared});await paint();
    check(front()===original&&front().querySelector('.ln-definition').textContent==='已经补全的释义'&&!document.getAnimations().length,'automatic completion updates in place without an answer turn');
    const hidden=prepared.map((card,index)=>index?card:{...card,kind:'recall',revealed:false,enrichmentStatus:'loading'});
    receive({...fixture,type:'patch',cards:hidden});await paint();
    receive({...fixture,type:'patch',cards:hidden.map(card=>({...card,enrichmentStatus:undefined}))});await paint();
    check(front().querySelector('.ln-question-note').hidden&&front().querySelector('.ln-reading').hidden&&front().querySelector('.ln-word').textContent==='已经补全的释义','hidden assessment answers stay hidden throughout preparation');
    await load(2);sent.length=0;
  }
  const readingCard=front(),readingActions=readingCard.querySelector('.ln-study-actions');
  check(readingActions.hidden&&!readingActions.children.length,'new-word reading has no acknowledgment or replacement action');
  let recall={...fixture.cards[1],kind:'recall',revealed:false};
  fixture.cards[1]=recall;
  receive({...fixture,type:'patch',focusID:recall.id});
  const assessmentCard=front(),assessmentActions=assessmentCard.querySelector('.ln-study-actions');
  check(!assessmentActions.hidden&&assessmentActions.textContent==='看看答案','recall still requires answer reveal');
  const questionNote=assessmentCard.querySelector('.ln-question-note'),questionInput=questionNote.querySelector('textarea');
  check(questionNote.hidden&&!questionNote.getClientRects().length,'unrevealed recall has no painted follow-up note');
  questionInput.focus();check(document.activeElement!==questionInput,'hidden follow-up cannot receive keyboard focus');
  questionInput.value='premature question';questionInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));await paint();
  check(!sent.some(message=>message.op==='question'),'unrevealed follow-up cannot submit even through a synthetic event');questionInput.value='';
  checkSurfaceMap('unrevealed assessment');
  const answerPaper=assessmentCard.querySelector('.ln-paper'),paperBounds=rect(answerPaper),revealBounds=rect(assessmentActions);
  const contactShadow=assessmentCard.querySelector('.ln-ground-shadow'),contactOpacity=+getComputedStyle(contactShadow).opacity;
  check(Math.abs((revealBounds.left+revealBounds.right-paperBounds.left-paperBounds.right)/2)<1&&Math.abs((revealBounds.top+revealBounds.bottom-paperBounds.top-paperBounds.bottom)/2)<1,'reveal action is centered on the paper');
  check(getComputedStyle(assessmentActions.querySelector('button')).borderTopWidth==='0px','reveal is text without button chrome');
  assessmentActions.querySelector('button').click();await paint();
  check(sent.some(message=>message.op==='reveal'&&message.cardID===recall.id),'recall sends explicit reveal');
  recall={...recall,revealed:true};fixture.cards[1]=recall;receive({...fixture,type:'patch'});
  check(assessmentCard.querySelector('.ln-reveal-front')?.inert&&assessmentCard.inert,'turning faces cannot be interacted with');
  check(document.activeElement===root,'reveal restores keyboard routing after its disabled action loses focus');
  for(const elapsed of [0,168,336,560,784,1000,1120,1200,1359.999]){
    await seek(elapsed/1360);
    for(const paper of assessmentCard.querySelectorAll('.ln-paper')){
      const box=rect(paper);
      check(box.left>=11&&box.right<=root.clientWidth-11&&box.top>=11&&box.bottom<=root.clientHeight-11,'picked-up answer stays inside the application');
    }
    if(elapsed<=1000)check(+getComputedStyle(questionNote).opacity===0,'follow-up stays hidden until the paper is nearly settled');
    if(elapsed===168){
      const held=rect(assessmentCard.querySelector('.ln-reveal-front'));
      check((paperBounds.top+paperBounds.bottom-held.top-held.bottom)/2>20,'paper visibly lifts before turning');
      check((held.left+held.right-paperBounds.left-paperBounds.right)/2>10,'pickup travels away from the stationary stack');
      check(+getComputedStyle(assessmentCard.querySelector('.ln-reveal-shadow')).opacity>.2,'pickup has a separate moving shadow');
    }
    if(elapsed===560)check(+getComputedStyle(assessmentCard.querySelector('.ln-reveal-backing')).opacity>.95,'opaque backing covers the edge crossing');
    if([336,560,784].includes(elapsed))check(+getComputedStyle(contactShadow).opacity===0,'airborne paper leaves no stationary contact-shadow rectangle');
    if(elapsed===0||elapsed>=1120)check(+getComputedStyle(contactShadow).opacity===contactOpacity,'contact shadow matches the resting paper at pickup and landing');
    if(elapsed>=1120)check(near(paperBounds,rect(answerPaper)),'later note arrival does not slow the paper landing');
    if(elapsed===1120)check(+getComputedStyle(questionNote).opacity>0&&+getComputedStyle(questionNote).opacity<.2,'follow-up only begins to emerge as the paper settles');
    if(elapsed===1200)check(+getComputedStyle(questionNote).opacity>.4&&+getComputedStyle(questionNote).opacity<.6,'follow-up continues fading gently after landing');
    const painted=[...root.querySelectorAll('.ln-paper,.ln-question-note,.ln-reveal-backing')].filter(node=>node.getClientRects().length&&+getComputedStyle(node).opacity>.005);
    const outlines=window.testSurfaceLayout.polygons.map(points=>({left:Math.min(...points.map(p=>p.x)),right:Math.max(...points.map(p=>p.x)),top:Math.min(...points.map(p=>p.y)),bottom:Math.max(...points.map(p=>p.y))}));
    const same=(a,b)=>['left','right','top','bottom'].every(key=>Math.abs(a[key]-b[key])<.6);
    check(painted.every(node=>outlines.some(box=>same(box,rect(node))))&&outlines.every(box=>painted.some(node=>same(box,rect(node)))),'turning paper and backing match native input outlines without stale regions');
  }
  await finish();
  check(+getComputedStyle(contactShadow).opacity===contactOpacity&&!assessmentCard.querySelector('.ln-reveal-shadow'),'settlement restores the contact shadow and removes its airborne counterpart');
  check(!assessmentCard.querySelector('.ln-reveal-front')&&!assessmentCard.inert&&assessmentCard.querySelector('.ln-paper')===answerPaper&&questionNote.querySelector('textarea')===questionInput,'settled answer retains its live paper and editor');
  check(!questionNote.hidden&&+getComputedStyle(questionNote).opacity===1,'follow-up becomes available after the turn');
  check(document.activeElement===root,'settled answer retains keyboard navigation focus');
  check(assessmentActions.querySelectorAll('button').length===4,'revealed recall retains all four grades');
  assessmentActions.querySelectorAll('button')[2].click();await paint();
  check(sent.some(message=>message.op==='grade'&&message.grade===4&&message.cardID===recall.id),'recall sends the selected grade');
  recall={...recall,graded:true};fixture.cards[1]=recall;receive({...fixture,type:'patch'});
  check(assessmentActions.textContent.includes('已记下这次复习'),'graded recall acknowledges the assessment');
  receive({...fixture,type:'patch',focusID:fixture.cards[0].id});
  check(front()===readingCard&&readingActions.hidden&&!readingActions.children.length,'returning to reading keeps the same paper without actions');

  async function loadQuestion(){
    await load(2);
    fixture.cards[0]={...fixture.cards[0],kind:'review',revealed:false};receive({...fixture,type:'patch'});await paint();
    return front();
  }
  function revealQuestion(){fixture.cards[0]={...fixture.cards[0],revealed:true};receive({...fixture,type:'patch'});}
  for(const interruption of ['reading','navigation','replacement','library','resize','reduced']){
    const card=await loadQuestion(),paper=card.querySelector('.ln-paper'),editor=card.querySelector('textarea');
    if(interruption==='reading'){card.querySelector('[data-zoom="word"]').click();await finish();}
    const base=rect(paper);revealQuestion();await seek(.3);
    if(interruption==='reading'){
      root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await finish();
      check(!root.classList.contains('has-reader')&&!card.querySelector('.ln-reveal-front')&&editor===card.querySelector('textarea'),'restoring during a reveal retains the editor and clears both effects');
    }else if(interruption==='navigation'){
      receive({type:'navigate',direction:1});await finish();
      check(front().dataset.cardId===fixture.cards[1].id,'queued navigation continues after answer settlement');
    }else if(interruption==='replacement'){
      await load(3);await finish();check(!card.isConnected&&!root.querySelector('.ln-reveal-front'),'replacement discards the old reveal without stale completion');
    }else if(interruption==='library'){
      receive({type:'library'});await finish();check(!root.querySelector('.ln-library').hidden&&!root.querySelector('.ln-reveal-front'),'opening library clears the active turn');root.querySelector('.ln-library-close').click();
    }else if(interruption==='resize'){
      root.style.width='700px';await paint();await finish();check(rect(paper).right<=700&&!root.querySelector('.ln-reveal-front'),'resizing settles the answer inside the new window');root.style.width='100%';await paint();
    }else{
      testReducedMotion(true);await finish();check(!root.querySelector('.ln-reveal-front')&&!document.getAnimations().length&&near(base,rect(paper)),'reduced motion finishes an active answer turn');testReducedMotion(false);
    }
    check(!root.querySelector('.ln-reveal-front,.ln-reveal-backing,.ln-reveal-shadow'),`interrupted answer leaves no temporary painted surface: ${interruption}`);
  }
  for(const width of [700,940]){
    root.style.width=width+'px';const card=await loadQuestion(),paper=card.querySelector('.ln-paper');
    card.querySelector('[data-zoom="word"]').click();await finish();const base=rect(paper);
    revealQuestion();
    for(const progress of [0,.15,.3,.48,.6,.78,.92,.999999]){
      await seek(progress);
      if(progress===.3||progress===.48||progress===.6)check(+getComputedStyle(card.querySelector('.ln-ground-shadow')).opacity===0,'enlarged airborne paper leaves no stationary contact-shadow rectangle');
      for(const face of card.querySelectorAll('.ln-paper,.ln-reveal-backing')){
        const box=rect(face);check(box.left>=11&&box.right<=width-11&&box.top>=11&&box.bottom<=root.clientHeight-11,'enlarged pickup, turn and landing stay inside the viewport');
      }
    }
    await finish();check(near(base,rect(paper))&&!card.querySelector('.ln-reveal-shadow'),'enlarged paper lands at its original reading pose without a stale shadow');
    root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await finish();
  }
  root.style.width='100%';
  await loadQuestion();testReducedMotion(true);revealQuestion();
  check(!root.querySelector('.ln-reveal-front')&&!document.getAnimations().length&&!front().querySelector('.ln-question-note').hidden,'reduced motion reveals directly with a usable follow-up');testReducedMotion(false);
  front().querySelector('.ln-study-actions button').focus();
  receive({type:'navigate',direction:1});await finish();
  check(document.activeElement===root,'navigation retains keyboard routing when an answer control becomes inert');

  for(const [width,count,direction] of [[700,2,1],[940,70,-1]]){
    root.style.width=width+'px';await load(count,direction===1?0:1);checkSurfaceMap('rest');
    receive({type:'navigate',direction});
    for(const progress of [0,.5,.99999]){await seek(progress);checkSurfaceMap(`navigation ${direction} at ${progress}`);}
    await finish();checkSurfaceMap('settled');
  }
  for(const width of [700,940])for(const kind of ['word','note']){
    root.style.width=width+'px';await load(4);
    front().querySelector(`[data-zoom="${kind}"]`).click();
    for(const progress of [0,.5,.99999]){await seek(progress);checkSurfaceMap(`${kind} zoom at ${progress}`);}
    await finish();checkSurfaceMap('enlarged');
    const messagesBefore=sent.filter(message=>message.op==='windowSurfaceLayout').length;
    await paint();await paint();
    check(sent.filter(message=>message.op==='windowSurfaceLayout').length===messagesBefore,'idle papers send no recurring input-map traffic');
    root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await seek(.5);checkSurfaceMap('restoring');
    await finish();checkSurfaceMap('restored');
  }
  root.style.width='100%';await load(3);
  receive({type:'library'});await paint();checkSurfaceMap('library');
  root.querySelector('.ln-library-close').click();await paint();checkSurfaceMap('closed library');
  await load(0);checkSurfaceMap('completion');
  sent.length=0;

  // Text owns selection from pointer-down through release, even when the
  // pointer crosses onto blank paper. Synthetic events check routing; native
  // mouse and edit-menu behavior is also checked in the packaged application.
  await load(3);
  const gestureCard=front(),gesturePaper=gestureCard.querySelector('.ln-paper');
  for(const node of [root,gesturePaper,gestureCard.querySelector('.ln-paper-head')]){
    const style=getComputedStyle(node);
    check((style.getPropertyValue('user-select')||style.getPropertyValue('-webkit-user-select'))==='none','blank paper and window header cannot start native text selection');
  }
  const gestureNote=gestureCard.querySelector('.ln-question-note'),gestureInput=gestureCard.querySelector('textarea');
  gestureInput.value='选择留言';
  gestureInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
  await paint();
  const gestureRequest=sent.filter(m=>m.op==='question').at(-1);
  receive({type:'reply',roundID:fixture.roundID,cardID:gestureRequest.cardID,requestID:gestureRequest.requestID,delta:'Select a word or a whole sentence.\n也可以选择中文回复。',done:true});
  gestureInput.value='保留的草稿';gestureInput.dispatchEvent(new Event('input',{bubbles:true}));
  gesturePaper.setPointerCapture=()=>{throw Error('text selection must not acquire paper pointer capture');};
  for(const kind of [null,'word','note']){
    if(kind){gestureCard.querySelector(`[data-zoom="${kind}"]`).click();await finish();}
    const surface=kind==='note'?gestureNote:kind==='word'?gesturePaper:gestureCard;
    for(const node of surface.querySelectorAll('.ln-selectable,textarea')){
      const style=getComputedStyle(node);
      const selectionStyle=style.getPropertyValue('user-select')||style.getPropertyValue('-webkit-user-select');
      check(selectionStyle==='text'&&style.cursor==='text',`selectable content advertises native text interaction: ${node.tagName}.${node.className}, ${selectionStyle}, ${style.cursor}`);
      const isEditor=node===gestureInput;
      if(isEditor){node.focus();node.setSelectionRange(1,4);}
      else{
        const range=document.createRange();range.selectNodeContents(node);
        window.getSelection().removeAllRanges();window.getSelection().addRange(range);
      }
      const selected=isEditor?node.value.slice(node.selectionStart,node.selectionEnd):window.getSelection().toString();
      check(selected.length>0,'selection fixture has actual content');
      const doubleClick=new MouseEvent('dblclick',{button:0,bubbles:true,cancelable:true});
      node.dispatchEvent(doubleClick);
      check(!doubleClick.defaultPrevented&&root.classList.contains('has-reader')===!!kind&&!document.getAnimations().length,'double-click text keeps native selection without toggling reading');
      node.dispatchEvent(new PointerEvent('pointerdown',{pointerId:31,button:0,clientX:420,clientY:260,bubbles:true,cancelable:true}));
      const move=new PointerEvent('pointermove',{pointerId:31,button:0,clientX:240,clientY:260,bubbles:true,cancelable:true});
      gesturePaper.dispatchEvent(move);
      gesturePaper.dispatchEvent(new PointerEvent('pointerup',{pointerId:31,button:0,clientX:240,clientY:260,bubbles:true}));
      check(!move.defaultPrevented&&!document.getAnimations().length&&front()===gestureCard,'dragging text across blank paper cannot switch cards');
      for(const options of [{key:'ArrowLeft'},{key:'ArrowRight',shiftKey:true},{key:'ArrowRight',altKey:true}]){
        const key=new KeyboardEvent('keydown',{...options,bubbles:true,cancelable:true});
        (isEditor?node:root).dispatchEvent(key);
        check(!key.defaultPrevented&&!document.getAnimations().length,'selection and editing keys stay native');
      }
      check((isEditor?node.value.slice(node.selectionStart,node.selectionEnd):window.getSelection().toString())===selected,'paper handlers preserve the selected range');
      window.getSelection().removeAllRanges();
    }
    const selectSurface=kind==='note'?gestureNote:gesturePaper;
    root.focus();
    selectSurface.querySelector('.ln-selectable').dispatchEvent(new PointerEvent('pointerdown',{button:0,bubbles:true}));
    for(const viaMenu of [true,false]){
      if(viaMenu)receive({type:'selectAll'});
      else{
        const key=new KeyboardEvent('keydown',{key:'a',metaKey:true,bubbles:true,cancelable:true});root.dispatchEvent(key);
        check(key.defaultPrevented,'document select-all shortcut uses the current paper boundary');
      }
      const selection=window.getSelection(),text=selection.toString();
      check(selection.rangeCount===1&&selectSurface.contains(selection.getRangeAt(0).commonAncestorContainer),'select-all stays inside the current paper');
      check(!text.includes('word1')&&!text.includes('word2')&&!text.includes('保留的草稿')&&!text.includes('放大')&&!text.includes('还原'),'select-all excludes covered papers, editor and controls');
      check(kind==='note'?text.includes('选择留言')&&text.includes('whole sentence')&&!text.includes('word0'):text.includes('word0')&&text.includes('例句 0')&&!text.includes('选择留言'),'select-all contains only the intended word or conversation');
    }
    window.getSelection().removeAllRanges();
    if(kind!=='word'){
      gestureInput.focus();gestureInput.setSelectionRange(1,4);
      receive({type:'selectAll'});
      check(document.activeElement===gestureInput&&gestureInput.selectionStart===0&&gestureInput.selectionEnd===gestureInput.value.length,'native menu select-all targets the focused draft');
      gestureInput.blur();window.getSelection().removeAllRanges();
    }
    if(kind){root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await finish();}
  }
  for(const options of [{shiftKey:true},{metaKey:true},{ctrlKey:true},{altKey:true}]){
    gesturePaper.dispatchEvent(new MouseEvent('dblclick',{...options,bubbles:true,cancelable:true}));
    gesturePaper.dispatchEvent(new PointerEvent('pointerdown',{...options,pointerId:32,button:0,clientX:420,clientY:260,bubbles:true}));
    gesturePaper.dispatchEvent(new PointerEvent('pointermove',{pointerId:32,clientX:240,clientY:260,bubbles:true}));
    gesturePaper.dispatchEvent(new PointerEvent('pointerup',{pointerId:32,clientX:240,clientY:260,bubbles:true}));
    const key=new KeyboardEvent('keydown',{...options,key:'ArrowRight',bubbles:true,cancelable:true});root.dispatchEvent(key);
    check(!key.defaultPrevented&&!root.classList.contains('has-reader')&&!document.getAnimations().length,'modified gestures and arrows are not paper commands');
  }
  const gestureHead=gestureCard.querySelector('.ln-paper-head');
  gestureHead.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true}));
  check(!root.classList.contains('has-reader'),'window movement header does not also zoom');
  const movesBefore=sent.filter(message=>message.op==='moveWindow').length;
  gestureHead.dispatchEvent(new PointerEvent('pointerdown',{button:0,bubbles:true}));
  await paint();
  check(sent.filter(message=>message.op==='moveWindow').length===movesBefore+1,'header retains native window movement');
  gestureInput.blur();
  root.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true}));await finish();
  check(front()!==gestureCard,'ordinary arrow navigation remains available without a selection');

  const search=root.querySelector('.ln-search');search.value='unique';
  receive({type:'library'});await paint();
  const selectionSearch=sent.filter(message=>message.op==='search').at(-1);
  receive({type:'selectAll'});
  check(document.activeElement===search&&search.selectionStart===0&&search.selectionEnd===6,'search keeps native input select-all');
  receive({type:'search',roundID:fixture.roundID,query:'unique',requestID:selectionSearch.requestID,words:[{id:'library-only',text:'unique entry',definition:'词库结果'}]});
  search.blur();root.focus();receive({type:'selectAll'});
  check(window.getSelection().toString().includes('unique entry')&&!window.getSelection().toString().includes('word'),'library select-all cannot reach the deck');
  window.getSelection().removeAllRanges();root.querySelector('.ln-library-close').click();
  for(const direction of ['meaningToWord','wordToMeaning']){
    await load(3);
    const cards=fixture.cards.map((card,i)=>i===0?{...card,kind:'recall',direction,revealed:false}:card);
    receive({type:'patch',roundID:fixture.roundID,cards,currentID:cards[0].id});
    root.focus();receive({type:'selectAll'});
    const text=window.getSelection().toString();
    check(!text.includes('word1')&&!text.includes('sample sentence')&&!text.includes('名词')&&!text.includes('/ˌser.'),'select-all excludes hidden answers and rear cards');
    check(direction==='meaningToWord'?text.includes('释义 0')&&!text.includes('word0'):text.includes('word0')&&!text.includes('释义 0'),'select-all retains only the unrevealed prompt');
    window.getSelection().removeAllRanges();
  }
  // Resolve actual hit targets, not just dispatches to hand-picked elements:
  // full-width text containers otherwise pass selection tests while stealing
  // blank rows and short-line tails from paper gestures.
  const hitAt=(point)=>{
    const node=document.elementFromPoint(point.x,point.y);
    check(node,'hit-test fixture remains inside the viewport');
    return node;
  };
  const trailingBlank=container=>{
    const spans=[...container.querySelectorAll('.ln-selectable')];
    const last=spans.at(-1),range=document.createRange();range.selectNodeContents(last);
    const line=[...range.getClientRects()].at(-1),block=rect(container);
    check(block.right-line.right>12,'fixture has genuine whitespace after its final text line');
    return {x:(line.right+block.right)/2,y:(line.top+line.bottom)/2};
  };
  const checkBlank=(point,surface,cursor,label)=>{
    const node=hitAt(point);
    check(surface.contains(node)&&!node.closest('.ln-selectable')&&getComputedStyle(node).cursor===cursor,`blank ${label} belongs to paper, not text: ${node.className}`);
  };
  for(const width of [700,940]){
    root.style.width=width+'px';await load(3);
    const cards=fixture.cards.map((card,i)=>i===0?{...card,word:{...card.word,word:'resilient',reading:'/rɪˈzɪliənt/',pos:'形容词',definition:'有韧性的；能够从困境中恢复，也能够适应变化。'}}:card);
    receive({type:'patch',roundID:fixture.roundID,cards,currentID:cards[0].id});await paint();
    const card=front(),paper=card.querySelector('.ln-paper');
    for(const enlarged of [false,true]){
      const cursor=enlarged?'zoom-out':'grab';
      for(const node of paper.querySelectorAll('.ln-selectable')){
        const range=document.createRange();range.setStart(node.firstChild,0);range.setEnd(node.firstChild,1);
        const glyph=rect(range),target=hitAt({x:(glyph.left+glyph.right)/2,y:(glyph.top+glyph.bottom)/2});
        check(target.closest('.ln-selectable')===node&&getComputedStyle(target).cursor==='text','actual glyph stays selectable after content reconciliation and zoom');
      }
      for(const selector of ['.ln-word','.ln-reading','.ln-definition','.ln-original','.ln-translation']){
        checkBlank(trailingBlank(card.querySelector(selector)),paper,cursor,selector);
      }
      const phonetic=rect(card.querySelector('.ln-phonetic .ln-selectable'));
      const pos=rect(card.querySelector('.ln-pos .ln-selectable'));
      checkBlank({x:(phonetic.right+pos.left)/2,y:(pos.top+pos.bottom)/2},paper,cursor,'pronunciation separator');
      const definition=card.querySelector('.ln-definition .ln-selectable');
      check(definition.getClientRects().length>1,'definition fixture exercises a wrapped inline region');
      const point=trailingBlank(card.querySelector('.ln-reading'));
      const event=new MouseEvent('dblclick',{button:0,clientX:point.x,clientY:point.y,bubbles:true,cancelable:true});
      hitAt(point).dispatchEvent(event);await finish();
      check(event.defaultPrevented&&root.classList.contains('has-reader')===!enlarged,'right-side reading whitespace toggles zoom in both sizes');
    }
    const point=trailingBlank(card.querySelector('.ln-reading'));
    paper.setPointerCapture=()=>{};paper.hasPointerCapture=()=>false;
    hitAt(point).dispatchEvent(new PointerEvent('pointerdown',{pointerId:39,button:0,clientX:point.x,clientY:point.y,bubbles:true}));
    paper.dispatchEvent(new PointerEvent('pointermove',{pointerId:39,clientX:point.x-100,clientY:point.y,bubbles:true,cancelable:true}));
    paper.dispatchEvent(new PointerEvent('pointerup',{pointerId:39,clientX:point.x-100,clientY:point.y,bubbles:true}));await finish();
    check(front()!==card,'dragging from the reading row whitespace switches cards');
  }
  root.style.width='100%';await load(3);
  const replyCard=front(),replyNote=replyCard.querySelector('.ln-question-note'),replyInput=replyCard.querySelector('textarea');
  replyInput.value='Check reply whitespace';
  replyInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));await paint();
  const replyRequest=sent.filter(m=>m.op==='question').at(-1);
  receive({type:'reply',roundID:fixture.roundID,cardID:replyRequest.cardID,requestID:replyRequest.requestID,delta:'A reply with several words.\nShort.',done:true});await paint();
  for(const enlarged of [false,true]){
    const paragraph=replyCard.querySelector('.ln-message.assistant p');
    const point=trailingBlank(paragraph);
    checkBlank(point,replyNote,enlarged?'zoom-out':'zoom-in','reply short-line tail');
    hitAt(point).dispatchEvent(new MouseEvent('dblclick',{button:0,clientX:point.x,clientY:point.y,bubbles:true,cancelable:true}));await finish();
    check(root.classList.contains('has-reader')===!enlarged,'reply trailing whitespace toggles note reading');
  }
  sent.length=0;

  for(const count of [2,4,20]) {
    await load(count);
    const nodes=[...root.querySelectorAll('.ln-assembly')];
    const identities=nodes.map(node=>node.querySelector('.ln-word').textContent);
    for(const direction of [1,-1]) {
      const outgoing=front();
      const incoming=nodes[direction===1?1:0];
      const layers=nodes.map(node=>node.style.zIndex);
      receive({type:'navigate',direction});
      check(document.getAnimations().length>0,'navigation produces an actual WebKit animation');
      await seek(.1);
      check(+getComputedStyle(outgoing.querySelector('.ln-question-note')).opacity>.99,'note remains during pickup');
      check(+getComputedStyle(incoming.querySelector('.ln-question-note')).opacity===0,'incoming note stays hidden during pickup');
      await seek(.5);
      check(+getComputedStyle(outgoing.querySelector('.ln-question-note')).opacity<.01,'note disappears during transition');
      check(+getComputedStyle(incoming.querySelector('.ln-question-note')).opacity===0,'incoming note does not appear through the lifted paper');
      const moving=nodes[0];
      const movingRect=rect(moving.querySelector('.ln-paper'));
      const otherRects=nodes.filter(n=>n!==moving&&!n.hidden).map(n=>rect(n.querySelector('.ln-paper')));
      check(otherRects.every(r=>movingRect.right<r.left),'layer handoff happens after paper clears the stack');
      await seek(.8);
      const arrivingNote=+getComputedStyle(incoming.querySelector('.ln-question-note')).opacity;
      check(arrivingNote>0&&arrivingNote<1,'incoming note returns gradually during settlement');
      check(+getComputedStyle(outgoing.querySelector('.ln-question-note')).opacity===0,'outgoing note cannot reappear during settlement');
      await seek(.99999);
      const before=nodes.map(n=>rect(n.querySelector('.ln-paper')));
      await finish();
      for(let i=0;i<nodes.length;i++)if(!nodes[i].hidden)check(near(before[i],rect(nodes[i].querySelector('.ln-paper'))),'settlement does not jump');
      check(nodes.every((n,i)=>n.querySelector('.ln-word').textContent===identities[i]),'papers retain their own content');
      check(front()===nodes[direction===1?1:0],'navigation selects the expected card');
      check(nodes.every((node,i)=>i===0||node.style.zIndex===layers[i]),'stationary layers remain unchanged through navigation');
      check(+getComputedStyle(front().querySelector('.ln-question-note')).opacity===1,'settled note is visible');
    }
  }

  await load(4);
  const original=front(),input=original.querySelector('textarea');
  input.value='未发送的草稿';input.dispatchEvent(new Event('input',{bubbles:true}));
  receive({type:'navigate',direction:1});receive({type:'navigate',direction:1});await finish();
  check(front().dataset.cardId===fixture.cards[2].id,'rapid navigation queues one next action');
  receive({type:'navigate',direction:-1});await finish();receive({type:'navigate',direction:-1});await finish();
  check(front()===original&&input.value==='未发送的草稿','returning preserves DOM and draft');

  input.value='请解释';input.dispatchEvent(new Event('input',{bubbles:true}));
  input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true,cancelable:true}));
  check(!sent.some(m=>m.op==='question'),'IME composition does not submit');
  input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',shiftKey:true,bubbles:true,cancelable:true}));
  check(!sent.some(m=>m.op==='question'),'Shift Enter does not submit');
  input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
  await paint();
  const request=sent.filter(m=>m.op==='question').at(-1);
  check(request&&request.roundID===fixture.roundID,'question carries round identity');
  receive({type:'navigate',direction:1});
  receive({type:'reply',roundID:fixture.roundID,cardID:request.cardID,requestID:request.requestID,delta:'属于第一张的回复',done:true});
  await finish();
  check(original.querySelector('.ln-feed').textContent.includes('属于第一张')&&!front().querySelector('.ln-feed').textContent,'reply stays with its originating card');
  receive({type:'navigate',direction:-1});await finish();
  input.value='阅读时的草稿';input.dispatchEvent(new Event('input',{bubbles:true}));

  for(const kind of ['word','note']){
    const target=original.querySelector(kind==='word'?'.ln-paper':'.ln-question-note');
    const textBoxes=()=>[...target.querySelectorAll('.ln-phonetic,.ln-pos,.ln-message p')].map(node=>{
      const range=document.createRange();range.selectNodeContents(node);return rect(range);
    });
    const before=rect(target);
    target.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true}));
    await seek(.99999);
    const enlarged=rect(target);
    const textBefore=textBoxes();
    await finish();
    const crisp=rect(target);
    check(near(enlarged,crisp,.2),'reading settlement does not move the paper: '+kind+' '+JSON.stringify({enlarged,crisp}));
    check(textBefore.every((box,i)=>near(box,textBoxes()[i],.2)),'reading settlement preserves glyph geometry: '+kind);
    check(crisp.left>=-1&&crisp.right<=root.clientWidth+1&&crisp.top>=-1&&crisp.bottom<=root.clientHeight+1,'reading zoom fits the window');
    const rightEdge=document.elementFromPoint(crisp.right-12,crisp.top+crisp.height/2);
    check(target.contains(rightEdge),'reading paper is not clipped by an ancestor: '+kind+' '+rightEdge?.className);
    check(input.value==='阅读时的草稿','reading zoom retains the input instance');
    check(+getComputedStyle(root.querySelector('.ln-deck')).opacity===.12&&+getComputedStyle(root.querySelector('.is-covered')).opacity===1,'reading fades a single opaque background stack');
    root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await seek(0);
    check(textBefore.every((box,i)=>near(box,textBoxes()[i],.2)),'closing starts with the same glyph geometry: '+kind);
    await finish();
    check(near(before,rect(target),2),'reading zoom restores the original paper');
  }

  receive({type:'navigate',direction:1});
  const old=fixture;
  await load(2);
  await finish();
  receive({type:'reply',roundID:old.roundID,cardID:request.cardID,requestID:request.requestID,delta:'旧轮次内容',done:true});
  check(front().dataset.cardId===fixture.cards[0].id&&!root.querySelector('.ln-feed').textContent,'old animation and replies cannot mutate a replacement round');

  const paper=front().querySelector('.ln-paper');
  paper.setPointerCapture=()=>{};paper.hasPointerCapture=()=>false;
  paper.dispatchEvent(new PointerEvent('pointerdown',{pointerId:7,button:0,clientX:400,clientY:200,bubbles:true}));
  paper.dispatchEvent(new PointerEvent('pointermove',{pointerId:7,button:0,clientX:420,clientY:200,bubbles:true,cancelable:true}));
  await paint();
  paper.dispatchEvent(new PointerEvent('pointercancel',{pointerId:7,bubbles:true}));
  await load(3);await finish();
  check(front().dataset.cardId===fixture.cards[0].id,'cancelled gesture cannot settle into a new round');

  receive({type:'navigate',direction:1});
  root.style.width='700px';await paint();await finish();
  check(front().getBoundingClientRect().width<410,'resizing during navigation settles with current geometry');
  for(const selector of ['.ln-paper','.ln-question-note']){
    const target=front().querySelector(selector);
    target.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));await finish();
    const enlarged=rect(target);
    check(enlarged.left>=-1&&enlarged.right<=701&&enlarged.top>=-1&&enlarged.bottom<=851,'zoom fits a narrow window');
    root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await finish();
  }
  root.style.width='100%';await paint();

  // Equivalent pulls should feel equivalent, including first-to-last wrapping.
  for(const width of [700,940]){
    root.style.width=width+'px';const travel=[];
    for(const [start,dx] of [[1,-120],[1,120],[0,120]]){
      await load(4,start);const paper=front().querySelector('.ln-paper'),before=rect(paper),beforeLayout=window.testSurfaceLayout;
      paper.setPointerCapture=()=>{};paper.hasPointerCapture=()=>false;
      paper.dispatchEvent(new PointerEvent('pointerdown',{pointerId:51,button:0,clientX:400,clientY:300,bubbles:true}));
      paper.dispatchEvent(new PointerEvent('pointermove',{pointerId:51,clientX:400+dx,clientY:300,bubbles:true,cancelable:true}));
      await paint();
      // Drag painting schedules its outline on the next frame, followed by
      // the native bridge round trip. Wait for that new message, not merely
      // the paint callback, while the pointer remains still in the held pose.
      for(let i=0;i<6&&window.testSurfaceLayout===beforeLayout;i++)await paint();
      check(window.testSurfaceLayout!==beforeLayout,'held drag publishes an updated native outline');
      checkSurfaceMap(`expanded held paper and tucked note: ${width}, ${start}, ${dx}`);
      const held=rect(paper);travel.push((held.left+held.right-before.left-before.right)/2);
      paper.dispatchEvent(new PointerEvent('pointercancel',{pointerId:51,bubbles:true}));await finish();
      check(near(before,rect(paper)),'expanded drag cancellation returns to the same paper pose');
    }
    check(travel[1]>=Math.abs(travel[0])*.9&&travel[1]>90,'right dragging has a useful range comparable to left dragging');
    check(Math.abs(travel[2]-travel[1])<1,'first-card right drag is not compressed');
  }

  // Measure the actual projected WebKit surfaces throughout the motion, not
  // just the resting cards. Large pointer travel must not clip the attached note.
  for(const width of [700,820,940])for(const count of [2,4]){
    root.style.width=width+'px';
    for(const direction of [1,-1])for(const gesture of ['keyboard','release','cancel']){
      await load(count,direction===1?0:1);
      const nodes=[...root.querySelectorAll('.ln-assembly')];
      const checkBounds=phase=>{
        const viewport=root.getBoundingClientRect();
        for(const node of nodes)for(const surface of node.querySelectorAll('.ln-paper,.ln-question-note')){
          if(+getComputedStyle(surface).opacity<=.001)continue;
          const edge=surface.getBoundingClientRect();
          if(surface.classList.contains('ln-paper'))check(edge.width>surface.offsetWidth*.3,
            `turning paper retains a visible face: ${width}, ${direction}, ${gesture}, ${phase}`);
          check(edge.left>=viewport.left+7.5&&edge.right<=viewport.right-7.5,
            `visible paper fits window: ${width}, ${count}, ${direction}, ${gesture}, ${phase}, ${surface.className}, ${edge.left}, ${edge.right}`);
        }
      };
      if(gesture==='keyboard')receive({type:'navigate',direction});
      else{
        const paper=front().querySelector('.ln-paper'),dx=-400*direction;
        paper.setPointerCapture=()=>{};paper.hasPointerCapture=()=>false;
        paper.dispatchEvent(new PointerEvent('pointerdown',{pointerId:19,button:0,clientX:400,clientY:300,bubbles:true}));
        paper.dispatchEvent(new PointerEvent('pointermove',{pointerId:19,button:0,clientX:400+dx,clientY:300,bubbles:true,cancelable:true}));
        await paint();checkBounds('held');
        paper.dispatchEvent(new PointerEvent(gesture==='cancel'?'pointercancel':'pointerup',{pointerId:19,button:0,clientX:400+dx,clientY:300,bubbles:true}));
      }
      const animations=document.getAnimations();
      check(animations.length>0,'bounds fixture starts an actual animation');
      for(const a of animations)a.pause();
      for(let frame=0;frame<=120;frame++){
        for(const a of animations)a.currentTime=a.effect.getTiming().duration*frame/120;
        // Layout reads flush the paused animation's current transform synchronously.
        checkBounds(frame);
        if(frame===60&&gesture!=='cancel'){
          const moving=nodes[0].querySelector('.ln-paper').getBoundingClientRect();
          check(nodes.slice(1).every(node=>moving.right<node.querySelector('.ln-paper').getBoundingClientRect().left),'contained layer handoff stays clear of the stack');
        }
      }
      await finish();checkBounds('settled');
    }
  }
  root.style.width='100%';await load(3,1);
  const active=front(), editor=active.querySelector('textarea');
  editor.value='长回复';editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));await paint();
  const longRequest=sent.filter(m=>m.op==='question').at(-1);
  const envelope={type:'reply',roundID:fixture.roundID,cardID:longRequest.cardID,requestID:longRequest.requestID};
  receive({...envelope,delta:('一段较长的解释。\n').repeat(60)});await paint();
  const scroller=active.querySelector('.ln-scroll');
  scroller.scrollTop=0;scroller.dispatchEvent(new Event('scroll'));
  receive({...envelope,delta:'继续追加一段解释。'});await paint();
  check(scroller.scrollTop===0,'streaming respects manual scroll position');
  receive({...envelope,done:true});
  scroller.scrollTop=40;
  editor.value='阅读时保留的草稿';editor.dispatchEvent(new Event('input',{bubbles:true}));
  editor.setSelectionRange(2,4);
  const scrollPosition=scroller.scrollTop;
  active.querySelector('.ln-question-note').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));await finish();
  check(scroller.scrollTop===scrollPosition&&editor.selectionStart===2&&editor.selectionEnd===4,'reading keeps reply scroll position and native draft selection');
  root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await finish();
  check(scroller.scrollTop===scrollPosition&&editor.value==='阅读时保留的草稿','closing reading preserves reply position and draft');
  testReducedMotion(true);
  receive({type:'navigate',direction:-1});
  check(!document.getAnimations().length&&front().dataset.cardId===fixture.cards[0].id,'reduced motion switches directly');
  testReducedMotion(false);
    return 'library, preparation, answer reveal, text ownership, navigation, streaming and input geometry';
  }
  check(section==='reading','the requested interaction section exists');
  for(const width of [700,940]){
    root.style.width=width+'px';root.style.height=(width===700?650:850)+'px';await paint();
    for(const kind of ['word','note']){
      await load(width===700?12:70,width===700?0:23);
      const card=front(),target=card.querySelector(kind==='word'?'.ln-paper':'.ln-question-note');
      const surrounding=card.querySelector(kind==='word'?'.ln-question-note':'.ln-paper');
      const before=rect(target),order=[...root.querySelectorAll('.ln-assembly')];
      target.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      await seek(0);
      check(near(before,rect(target),.2)&&+getComputedStyle(surrounding).opacity===1,'zoom pickup retains paper and surrounding opacity');
      const times=document.getAnimations().map(a=>a.effect.getTiming().duration);
      check(times.length>1&&times.every(time=>time===times[0]),'paper and surrounding fades share a timeline');
      check(times.length<=8,'reading animates a fixed number of surfaces even in a long stack');
      let previousWidth=before.width,previousOpacity=1;
      for(let i=1;i<=20;i++){
        await seek(i/21);
        const box=rect(target),opacity=+getComputedStyle(surrounding).opacity;
        check(box.width>=previousWidth-.1&&box.left>=0&&box.right<=width&&box.top>=0&&box.bottom<=root.clientHeight,`zoom grows smoothly inside the window: ${JSON.stringify({width,kind,step:i,previousWidth,box,height:root.clientHeight})}`);
        check(opacity<=previousOpacity+.001,'surrounding paper fades continuously while enlarging');
        if(i===10)check(opacity>0&&opacity<1,'surrounding paper has intermediate visibility');
        check([...root.querySelectorAll('.ln-deck .ln-assembly')].every(n=>+getComputedStyle(n).opacity===1),'background papers remain opaque to keep covered text hidden');
        previousWidth=box.width;previousOpacity=opacity;
      }
      await finish();
      // A normal data refresh must not override the settled reading appearance.
      receive({...fixture,type:'patch'});
      check(+getComputedStyle(surrounding).opacity===(kind==='word'?0:.12),'data reconciliation retains reading opacity');
      fixture.cards.push({...fixture.cards[0],id:'appended-while-reading'});
      receive({...fixture,type:'patch'});
      const appended=root.querySelector('[data-card-id="appended-while-reading"]');
      order.push(appended);
      check(appended.parentNode===root.querySelector('.ln-deck')&&root.classList.contains('has-reader'),'new cards join the faded stack without interrupting reading');
      root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
      await seek(.4);
      receive({type:'navigate',direction:1});
      check(front()===card&&root.classList.contains('has-reader'),'navigation stays inactive during restoration');
      await finish();
      check(near(before,rect(target),.2)&&!root.classList.contains('has-reader'),'closing restores the original geometry and interaction');
      check(!root.querySelector('.ln-reader-foreground')&&[...root.querySelectorAll('.ln-assembly')].every((node,i)=>node===order[i]),'closing restores each original node in deck order');
      target.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));await seek(.4);
      testReducedMotion(true);await paint();
      check(root.classList.contains('has-reader')&&!document.getAnimations().length,'enabling reduced motion settles an active zoom');
      root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
      check(!root.classList.contains('has-reader')&&!document.getAnimations().length&&near(before,rect(target),.2),'reduced motion restores immediately');
      target.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      check(root.classList.contains('has-reader')&&!document.getAnimations().length,'reduced motion enlarges immediately');
      root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
      testReducedMotion(false);
      target.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));await seek(.4);
      await load(3);await finish();
      check(!root.classList.contains('has-reader')&&!root.querySelector('.ln-assembly[aria-modal="true"]'),'replacement round cancels every reading effect');
    }
  }
  for(const closing of [false,true]){
    await load(3);
    const target=front().querySelector('.ln-question-note');
    target.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
    if(closing){await finish();root.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));}
    await seek(.4);
    root.style.width='700px';await paint();await finish();
    check(!root.classList.contains('has-reader')&&root.querySelector('.ln-reading-shade').hidden&&!target.style.transform,'resize cancels opening and closing without stale reading styles');
    root.style.width='940px';await paint();
  }
  await load(3);
  const removed=front();
  removed.querySelector('.ln-question-note').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));await seek(.4);
  fixture.cards.shift();receive({...fixture,type:'patch'});await finish();
  check(!removed.isConnected&&!root.classList.contains('has-reader')&&!root.querySelector('.ln-reader-foreground'),'removing the reading card cancels its host without restoring a stale node');
  async function loadTail(count,target,start=count-1){
    await load(count,start);
    fixture.cards=fixture.cards.map((card,index)=>({...card,kind:'review',graded:index!==target,revealed:target===0||index!==target}));
    fixture.pendingID=fixture.cards[target]?.id;
    receive({...fixture,type:'patch'});await paint();
  }
  for(const [count,target] of [[2,0],[6,0],[6,3]])for(const gesture of [false,true]){
    await loadTail(count,target);
    const tail=front(),paper=tail.querySelector('.ln-paper'),editor=tail.querySelector('textarea');
    editor.value='末尾保留的草稿';editor.dispatchEvent(new Event('input',{bubbles:true}));
    const completions=sent.filter(message=>message.op==='completeRound').length;
    if(gesture){
      paper.setPointerCapture=()=>{};paper.hasPointerCapture=()=>false;
      paper.dispatchEvent(new PointerEvent('pointerdown',{pointerId:71,button:0,clientX:400,clientY:300,bubbles:true}));
      paper.dispatchEvent(new PointerEvent('pointermove',{pointerId:71,clientX:280,clientY:300,bubbles:true,cancelable:true}));await paint();
      paper.dispatchEvent(new PointerEvent('pointerup',{pointerId:71,clientX:280,clientY:300,bubbles:true}));
    }else root.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true}));
    await seek(.5);
    check(document.getAnimations().some(animation=>animation.effect.target===tail),'tail continuation uses a paper animation');
    check(front()===tail&&tail.inert,'tail is retained and locked until the handoff finishes');
    check(getComputedStyle(tail.querySelector('.ln-question-note')).opacity==='0','tail note disappears during the handoff');
    checkSurfaceMap('study tail return');
    await finish();
    check(front().dataset.cardId===fixture.cards[0].id,'manual study navigation wraps to the first card regardless of pending assessments');
    check(tail.isConnected&&editor.value==='末尾保留的草稿','tail continuation retains paper identity and draft');
    check(sent.filter(message=>message.op==='completeRound').length===completions,'pending continuation does not ask native code to jump focus');
    const order=[...root.querySelectorAll('.ln-assembly')].sort((a,b)=>Number(b.style.zIndex)-Number(a.style.zIndex));
    check(order.every((node,depth)=>node.dataset.cardId===fixture.cards[depth].id),'returning retains the full visible stack order');
    if(gesture){
      const firstPaper=front().querySelector('.ln-paper');firstPaper.setPointerCapture=()=>{};firstPaper.hasPointerCapture=()=>false;
      firstPaper.dispatchEvent(new PointerEvent('pointerdown',{pointerId:72,button:0,clientX:400,clientY:300,bubbles:true}));
      firstPaper.dispatchEvent(new PointerEvent('pointermove',{pointerId:72,clientX:520,clientY:300,bubbles:true,cancelable:true}));await paint();
      firstPaper.dispatchEvent(new PointerEvent('pointerup',{pointerId:72,clientX:520,clientY:300,bubbles:true}));
    }else receive({type:'navigate',direction:-1});
    await seek(.5);
    check(document.getAnimations().length&&front().inert,'first-to-last study navigation has an owned transition');
    checkSurfaceMap('first-to-last study wrap');await finish();
    check(front()===tail&&editor.value==='末尾保留的草稿','reverse navigation from the first study paper returns to the last paper and draft');
    check(sent.filter(message=>message.op==='completeRound').length===completions,'manual wrapping never grades or ends the round');
  }
  await loadTail(6,0,4);
  receive({type:'navigate',direction:1});await seek(.3);
  receive({type:'navigate',direction:1});await finish();
  check(front().dataset.cardId===fixture.pendingID,'queued forward input at the tail keeps its animated continuation');
  await loadTail(6,3);
  receive({type:'navigate',direction:1});await seek(.3);
  root.style.width='700px';await paint();await finish();
  check(front().dataset.cardId===fixture.cards[0].id,'resizing during a manual tail wrap retains its destination');
  checkSurfaceMap('resized study return');root.style.width='940px';await paint();
  await loadTail(6,3);
  receive({type:'navigate',direction:1});await seek(.3);await load(2);await finish();
  check(front().dataset.cardId===fixture.cards[0].id&&!document.getAnimations().length,'round replacement cancels a pending tail return');
  await loadTail(6,3);testReducedMotion(true);
  receive({type:'navigate',direction:1});await paint();
  check(front().dataset.cardId===fixture.cards[0].id&&!document.getAnimations().length,'reduced motion wraps forward to the first card');
  receive({type:'navigate',direction:-1});await paint();
  check(front().dataset.cardId===fixture.cards[5].id&&!document.getAnimations().length,'reduced motion wraps backward to the last card');testReducedMotion(false);
  for(const target of [0,3]){
    await loadTail(6,target);
    receive({...fixture,type:'patch',advanceFrom:front().dataset.cardId});await seek(.5);
    check(document.getAnimations().length&&front().inert,'grading-driven continuation still animates');await finish();
    check(front().dataset.cardId===fixture.pendingID,'grading-driven continuation seeks the pending assessment');
  }
  await loadTail(1,0);
  const single=front(),completionCount=sent.filter(message=>message.op==='completeRound').length;
  receive({type:'navigate',direction:1});await finish();
  check(front()===single&&!document.getAnimations().length&&sent.filter(message=>message.op==='completeRound').length===completionCount,'one unfinished paper stays in place without looping or ending');
  check(front().querySelector('.ln-language').textContent==='当前只有一张词卡。','single-card navigation gives visible feedback');
  fixture.cards[0]={...fixture.cards[0],graded:true};fixture.pendingID=null;receive({...fixture,type:'patch'});
  receive({type:'navigate',direction:1});await paint();
  check(sent.filter(message=>message.op==='completeRound').length===completionCount,'manual navigation never completes a fully graded round');
  receive({...fixture,type:'patch',advanceFrom:fixture.cards[0].id});await paint();
  check(sent.filter(message=>message.op==='completeRound').length===completionCount+1,'acknowledged final grading still requests completion');

  await load(3);
  receive({type:'feedback',roundID:fixture.roundID,message:'正在用 AI 更新词条…',persistent:true});
  check(front().querySelector('.ln-language').textContent==='正在用 AI 更新词条…','assistant work is visible on the paper');
  receive({type:'navigate',direction:1});await finish();
  check(front().querySelector('.ln-language').textContent==='正在用 AI 更新词条…','background work remains visible after navigation');
  receive({...fixture,type:'patch',announcement:'词条已更新，已保存到本地。'});await paint();
  check(front().querySelector('.ln-language').textContent==='词条已更新，已保存到本地。','completion replaces pending feedback');
  const oldRound=fixture.roundID;
  await load(3,0,{animateEntry:true,announcement:'已开始英语学习 · 3 张'});await seek(.4);
  check(root.querySelector('.ln-round-front')&&document.getAnimations().length,'menu round replacement turns the current word paper into the new round');
  receive({type:'feedback',roundID:oldRound,message:'旧请求的状态'});await finish();
  check(front().querySelector('.ln-language').textContent==='已开始英语学习 · 3 张','replacement discards stale status and visibly acknowledges the new workload');

  // The new-round action retains its summary face until the first real paper
  // turns over, then opens the rear stack and its eligible follow-up note.
  await load(0);
  const start=root.querySelector('.ln-start'),starts=sent.filter(message=>message.op==='startRound').length;
  start.click();start.click();await paint();
  check(start.disabled&&sent.filter(message=>message.op==='startRound').length===starts+1,'repeated activation sends only one new-round request');
  receive({type:'actionFailed',roundID:fixture.roundID});
  check(!start.disabled,'a failed new round can be retried');
  start.click();await load(0);
  check(start.disabled&&root.querySelector('.ln-summary-turn')&&document.getAnimations().length,'an empty workload also turns into its summary instead of jumping');await finish();
  check(!start.disabled&&!document.getAnimations().length&&!root.querySelector('.ln-complete').hidden,'the empty workload settles as a usable summary without inventing cards');
  await load(3);
  await load(0,0,{animateEntry:true,announcement:'暂无待学词卡 · 英语新词学习'});await seek(.5);
  check(root.querySelector('.ln-summary-turn')&&document.getAnimations().length,'the learn-only menu animates from a word paper into an empty workload');
  checkSurfaceMap('empty workload turn');await finish();
  check(!root.querySelector('.ln-summary-turn,.ln-reveal-front')&&!root.querySelector('.ln-complete').hidden,'empty workload cleanup retains its real summary and removes temporary surfaces');
  await load(1);
  check(!document.getAnimations().length,'loading without a summary action remains immediate');
  for(const [width,count] of [[700,1],[700,4],[940,70]]){
    root.style.width=width+'px';await load(0);start.click();await load(count);await seek(0);
    const active=front(),paper=active.querySelector('.ln-paper'),editor=active.querySelector('textarea'),note=active.querySelector('.ln-question-note');
    check(root.querySelector('.ln-round-front')&&active.inert,'a new round lifts the inert summary over the live word paper');
    check(document.getAnimations().length<=11&&root.querySelectorAll('.ln-round-stack').length<=2,'entrance animation surfaces stay bounded for long rounds');
    for(const fraction of [.18,.45,.6,.72,.88,.999999]){
      await seek(fraction);
      const groups=[...root.querySelectorAll('.ln-round-stack')];
      if(fraction<.6)check(groups.every(group=>+getComputedStyle(group).opacity===0),'rear cards wait until the summary has turned');
      if(fraction<.8)check(+getComputedStyle(note).opacity===0,'follow-up waits for the stack to open');
      if(fraction===.88)check(+getComputedStyle(note).opacity>0&&+getComputedStyle(note).opacity<1,'follow-up enters gradually during the late spread');
      const faces=[paper,note,...active.querySelectorAll('.ln-round-front,.ln-reveal-backing'),...groups.filter(group=>+getComputedStyle(group).opacity>.005).map(group=>group.querySelector('.ln-paper'))]
        .filter(node=>node.getClientRects().length&&+getComputedStyle(node).opacity>.005);
      const boxes=window.testSurfaceLayout.polygons.map(points=>({left:Math.min(...points.map(p=>p.x)),right:Math.max(...points.map(p=>p.x)),top:Math.min(...points.map(p=>p.y)),bottom:Math.max(...points.map(p=>p.y))}));
      const same=(a,b)=>['left','right','top','bottom'].every(key=>Math.abs(a[key]-b[key])<.6);
      check(faces.every(node=>boxes.some(box=>same(box,rect(node))))&&boxes.every(box=>faces.some(node=>same(box,rect(node)))),'native entrance outlines follow only the exposed moving faces');
      check(boxes.every(box=>box.left>=7&&box.right<=width-7&&box.top>=7&&box.bottom<=root.clientHeight-7),'the turning summary and spreading stack remain inside the window');
    }
    await finish();
    check(!root.querySelector('.ln-round-front,.ln-round-stack,.ln-reveal-shadow')&&!active.inert&&editor===active.querySelector('textarea'),'entrance cleanup keeps the live card and editor without temporary surfaces');
    check(root.querySelectorAll('.ln-deck > .ln-assembly').length===count,'all real cards return to the deck in their original order');
    check(+getComputedStyle(note).opacity===1,'eligible follow-up is fully visible after entrance');
    checkSurfaceMap('new-round settlement');
  }
  async function enterRound(){await load(0);start.click();await load(3);await seek(.3);return front();}
  for(const interruption of ['replacement','library','resize','reduced','navigation']){
    const active=await enterRound();
    if(interruption==='replacement'){await load(2);await finish();check(!active.isConnected,'replacement removes every old entrance card');}
    if(interruption==='library'){receive({type:'library'});await finish();check(!root.querySelector('.ln-library').hidden,'library opening settles the entrance');root.querySelector('.ln-library-close').click();}
    if(interruption==='resize'){root.style.width='700px';await paint();await finish();check(rect(front().querySelector('.ln-paper')).right<=700,'resize settles into the new viewport');root.style.width='940px';await paint();}
    if(interruption==='reduced'){testReducedMotion(true);await finish();testReducedMotion(false);}
    if(interruption==='navigation'){receive({type:'navigate',direction:1});check(front()===active,'navigation waits for entrance');await finish();check(front().dataset.cardId===fixture.cards[1].id,'queued navigation starts after the entrance settles');}
    check(!root.querySelector('.ln-round-front,.ln-round-stack,.ln-reveal-backing,.ln-reveal-shadow')&&!document.getAnimations().length,'interrupted entrance leaves no stale effects: '+interruption);
  }
  await load(0);testReducedMotion(true);start.click();await load(3);
  check(!document.getAnimations().length&&!front().inert,'reduced motion starts the next round directly');testReducedMotion(false);
  await load(0);start.click();
  const question={id:crypto.randomUUID(),kind:'review',direction:'meaningToWord',revealed:false,graded:false,word:{word:'solace',reading:'/ˈsɒlɪs/',definition:'慰藉',pos:'名词',example:'',translation:''}};
  receive({type:'round',roundID:crypto.randomUUID(),language:'en',cards:[question],currentID:question.id});await seek(.9);
  check(front().querySelector('.ln-question-note').hidden,'unrevealed review never exposes a follow-up during entrance');await finish();
  check(front().querySelector('.ln-question-note').hidden&&front().querySelector('.ln-study-actions button').textContent==='看看答案','entrance preserves the new round assessment and reveal rules');
  root.style.width='100%';root.style.height='100%';await paint();
  return 'paper continuity, window bounds, draft/reply identity, zoom, IME, cancellation, resize and reduced motion';
}
