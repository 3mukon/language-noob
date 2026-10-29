import Foundation
import JavaScriptCore

extension LanguageNoobTests {
    static func motionTests() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let context = JSContext()!
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() ?? "unknown JavaScript error" }
        context.evaluateScript(try String(contentsOf: root.appendingPathComponent("Sources/LanguageNoob/Resources/paper-motion.js"), encoding: .utf8))
        context.evaluateScript("""
        (() => {
          const M=PaperMotion, geometry={width:940,left:200,w:400,h:466,spread:27,fan:14,nw:304,nh:224,nx:296,ny:267,noteAngle:-7},path=M.flight(geometry);
          function check(value,message){if(!value)throw Error(message);}
          function equal(a,b){return Object.keys(a).every(k=>Math.abs(a[k]-b[k])<.00001);}
          for(const count of [2,3,4,20])for(const start of new Set([0,count-2,count-1]))for(const direction of [1,-1]){
            const to=(start+direction+count)%count;
            for(let index=0;index<count;index++){
              const options={index,from:start,to,count,geometry,path,direction};
              const first=M.sample(options,0),last=M.sample(options,1);
              check(equal(first.pose,M.rest(M.slot(index,start,count),geometry)),`start pose: ${count},${direction},${index}`);
              check(equal(last.pose,M.rest(M.slot(index,to,count),geometry)),`end pose: ${count},${direction},${index}`);
              check(last.note===(index===to?1:0),'final attached note');
              check(first.ambient===(M.slot(index,start,count)<3?1:0),'initial shadow matches actual visibility');
              check(last.ambient===(M.slot(index,to,count)<3?1:0),'final shadow matches actual visibility');
              let previous=first.pose;
              for(let frame=1;frame<=240;frame++){
                const value=M.sample(options,frame/240),current=value.pose;
                check(Math.hypot(current.x-previous.x,current.y-previous.y)<15,'continuous trajectory');
                const face=M.bounds(current,geometry);
                check(face.right-face.left>geometry.w*.3,'the turning paper retains a visible face');
                previous=current;
              }
            }
            const outgoing={index:start,from:start,to,count,geometry,direction};
            check(M.sample(outgoing,.1).note===1,'note survives initial pickup');
            check(M.sample(outgoing,.5).note===0,'outgoing note disappears during motion');
            const moving={index:direction===1?start:to,from:start,to,count,geometry,direction};
            const apex=M.sample(moving,.5);
            const apexBounds=M.bounds(apex.pose,geometry);
            check(apexBounds.left+apex.shift>=8 && apexBounds.right<M.bounds(M.rest(2,geometry),geometry).left,'layer changes inside the window at a cleared edge');
          }
          for(const count of [2,3,4,20,70]){
            let layers=Array.from({length:count},(_,i)=>(count-i)*10),from=0;
            for(const direction of [...Array(count).fill(1),...Array(count).fill(-1),1,-1,1,-1]){
              const to=(from+direction+count)%count;
              const change=M.handoff(from,to,layers,direction),others=layers.filter((_,i)=>i!==change.index);
              check(direction>0?change.start>Math.max(...others):change.start<Math.min(...others),'pickup starts strictly outside stationary layers');
              check(direction>0?change.end<Math.min(...others):change.end>Math.max(...others),'handoff ends strictly outside stationary layers');
              layers[change.index]=change.end;
              const order=layers.map((layer,index)=>({layer,index})).sort((a,b)=>b.layer-a.layer);
              check(order.every((card,depth)=>M.slot(card.index,to,count)===depth),'only moving a single layer preserves the entire stack order');
              check(new Set(layers).size===count,'navigation never creates tied layers');
              from=to;
            }
          }
          const drag=M.pose(-105,-7,-2,1.01,0,2,12);
          for(const count of [2,6,20,70])for(const to of [...new Set([0,Math.floor(count/2)])]){
            const from=count-1;if(to===from)continue;
            const layers=Array.from({length:count},(_,index)=>(count-M.slot(index,from,count))*10);
            const change=M.handoff(from,to,layers,1);
            check(change.changes.length===to+1,'forward tail return carries exactly the intervening papers');
            for(const item of change.changes)layers[item.index]=item.end;
            const order=layers.map((layer,index)=>({layer,index})).sort((a,b)=>b.layer-a.layer);
            check(order.every((card,depth)=>M.slot(card.index,to,count)===depth),'wrapping preserves the complete stack order');
            check(new Set(layers).size===count,'returning never ties paper layers');
            for(const index of [...new Set([from,0,1,to,count-2])]){
              const options={index,from,to,count,geometry,path,direction:1,drag};
              check(equal(M.sample(options,0).pose,index===from?drag:M.rest(M.slot(index,from,count),geometry)),'wrapped pickup preserves the held paper and each underlying sheet');
              check(equal(M.sample(options,1).pose,M.rest(M.slot(index,to,count),geometry)),'wrapped landing matches the actual destination slot');
              let previous=M.sample(options,0).pose;
              for(let frame=1;frame<=240;frame++){
                const value=M.sample(options,frame/240),edge=M.bounds(value.pose,geometry,value.note>.001,value.noteX);
                check(Math.hypot(value.pose.x-previous.x,value.pose.y-previous.y)<15,'wrapped handoff has a continuous forward trajectory');
                check(edge.left+value.shift>=7.99&&edge.right+value.shift<=geometry.width-7.99,'wrapped papers and visible notes stay in the window');
                previous=value.pose;
              }
              if(M.slot(index,from,count)<to+1){
                const apex=M.sample(options,.5),edge=M.bounds(apex.pose,geometry);
                check(edge.right<M.bounds(M.rest(2,geometry),geometry).left,'all picked-up sheets clear the stack before their layer exchange');
              }
            }
          }
          check(equal(M.sample({index:0,from:0,to:1,count:2,geometry,drag},0).pose,drag),'release starts at the gesture pose');
          check(Math.abs(M.sample({index:0,from:0,to:1,count:2,geometry,drag},0).shadow-Math.min(.6,Math.abs(drag.x)/geometry.w))<.00001,'release retains the held shadow');
          for(const [width,left,nw] of [[700,75.3800239923,294],[820,140,304],[940,200,304]]){
            const g={...geometry,width,left,nw,spread:Math.min(27,(width-420)*.09)},path=M.flight(g);
            const right=M.drag(120,0,g),leftPull=M.drag(-120,0,g);
            check(right.x>=Math.abs(leftPull.x)*.95&&right.x>90,'rightward pull has the same useful travel as the left');
            for(const dx of [-400,-120,120,400]){
              const held=M.drag(dx,0,g),noteX=M.dockNote(held,g),edge=M.bounds(held,g,true,noteX);
              check(edge.left>=7.999&&edge.right<=width-7.999,'the note tucks inward without clipping a held paper');
              const next=dx<0?2:0,options={index:1,from:1,to:next,count:4,geometry:g,drag:held,path};
              const first=M.sample(options,0);
              check(equal(first.pose,held)&&Math.abs(first.noteX-noteX)<.00001,'release retains the actual paper and note poses');
              for(let frame=0;frame<=240;frame++){
                const value=M.sample(options,frame/240),edge=M.bounds(value.pose,g,value.note>.001,value.noteX);
                check(edge.left+value.shift>=7.99&&edge.right+value.shift<=width-7.99,'expanded travel keeps visible paper and note inside the window');
              }
            }
            const travel=direction=>Array.from({length:241},(_,frame)=>{
              const value=M.sample({index:1,from:1,to:1+direction,count:4,geometry:g,path},frame/240),edge=M.bounds(value.pose,g);
              return (edge.left+edge.right)/2+value.shift-left-g.w/2;
            });
            const leftRange=-Math.min(...travel(1)),rightRange=Math.max(...travel(-1));
            check(rightRange>=leftRange*.9&&rightRange<=leftRange*1.2,'reverse departure has a balanced visible excursion');
          }
        })();
        """)
        try check(failure == nil, failure ?? "motion geometry")
        print("PASS: motion endpoints, layers, note timing and continuity")
    }
}
