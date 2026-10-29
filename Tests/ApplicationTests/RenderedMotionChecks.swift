import Foundation
import AppKit
import WebKit

extension ApplicationChecks {
    @MainActor static func renderedMotionChecks(_ renderer: WebKitFixture) async throws {
        func execute(_ script: String) async throws {
            let _: Any = try await withCheckedThrowingContinuation { continuation in
                renderer.webView.callAsyncJavaScript(script + ";return true;", arguments: [:], in: nil, in: .page) {
                    continuation.resume(with: $0)
                }
            }
        }
        func snapshot() async throws -> NSBitmapImageRep {
            let image = try await renderer.webView.takeSnapshot(configuration: nil)
            guard let data = image.tiffRepresentation, let pixels = NSBitmapImageRep(data: data),
                  !pixels.isPlanar, pixels.bitsPerSample == 8, pixels.samplesPerPixel == 4 else {
                throw ApplicationFailure(message: "unsupported WebKit snapshot format")
            }
            return pixels
        }
        func compare(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep, _ label: String) throws {
            try check(before.pixelsWide == after.pixelsWide && before.pixelsHigh == after.pixelsHigh, "snapshot dimensions changed")
            let left = before.bitmapData!, right = after.bitmapData!
            var changed = 0
            // A regular grid includes every region, including shadows outside the papers.
            // It avoids expensive per-pixel object allocation in the development build.
            for y in stride(from: 0, to: before.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: before.pixelsWide, by: 2) {
                    let a = y * before.bytesPerRow + x * 4, b = y * after.bytesPerRow + x * 4
                    if abs(Int(left[a]) - Int(right[b])) > 8 || abs(Int(left[a+1]) - Int(right[b+1])) > 8 ||
                        abs(Int(left[a+2]) - Int(right[b+2])) > 8 || abs(Int(left[a+3]) - Int(right[b+3])) > 8 { changed += 1 }
                }
            }
            if changed > 8 {
                let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-render-failure-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try before.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("before.png"))
                try after.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("after.png"))
                throw ApplicationFailure(message: "\(label): \(changed) sampled pixels changed; frames: \(directory.path)")
            }
        }
        func checkEditorPaint(_ label: String) async throws {
            let metrics: Any = try await withCheckedThrowingContinuation { continuation in
                renderer.webView.callAsyncJavaScript("""
                const note=document.querySelector('.is-front .ln-question-note');
                const box=note.querySelector('textarea').getBoundingClientRect();
                const rgb=getComputedStyle(note).backgroundColor.match(/[\\d.]+/g).slice(0,3).map(Number);
                return [box.x,box.y,box.width,box.height,...rgb];
                """, arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
            }
            guard let m = metrics as? [Double], m.count == 7 else { throw ApplicationFailure(message: "editor paint bounds") }
            let pixels = try await snapshot(), data = pixels.bitmapData!
            let scale = Double(pixels.pixelsWide) / renderer.webView.bounds.width
            var ink = 0
            // Exclude the underline: a painted border must not count as visible text.
            for y in Int((m[1]+1)*scale)..<Int((m[1]+m[3]-4)*scale) {
                for x in Int((m[0]+1)*scale)..<Int((m[0]+m[2]-1)*scale) {
                    let offset = y * pixels.bytesPerRow + x * 4
                    if (0..<3).contains(where: { abs(Double(data[offset+$0])-m[4+$0]) > 55 }) { ink += 1 }
                }
            }
            try check(ink > 30, "\(label): native editor text is missing from its painted area")
        }
        try await execute("""
        window.frameProbe={
          paint:()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))),
          async load(count,front=0,view='study'){
            window.nativeReceive({type:'round',roundID:'rendered-motion',language:'en',currentID:'frame-'+front,view,
              cards:Array.from({length:count},(_,i)=>({id:'frame-'+i,kind:view==='library'?'browse':'introduction',direction:'wordToMeaning',revealed:true,graded:false,
                word:{word:['serendipity','resilient','solace','glimpse'][i%4]+i,reading:'/ˌser.ənˈdɪp.ə.ti/',definition:'纸张 '+i+' 的释义',pos:'名词',example:'This text belongs to sheet '+i+'.',translation:'这张纸的例句 '+i}}))});
            document.querySelectorAll('.ln-feed').forEach((feed,i)=>{const p=document.createElement('p');p.textContent='这张便笺 '+i+' 的独立回复';feed.append(p);});
            await this.paint();
          },
          async seek(time){for(const a of document.getAnimations()){a.pause();a.currentTime=a.effect.getTiming().duration*time;}await this.paint();},
          async finish(){for(const a of document.getAnimations())a.finish();await this.paint();},
          async drag(dx){
            const paper=document.querySelector('.is-front .ln-paper');
            paper.setPointerCapture=()=>{};paper.hasPointerCapture=()=>false;
            paper.dispatchEvent(new PointerEvent('pointerdown',{pointerId:42,button:0,clientX:400,clientY:300,bubbles:true}));
            paper.dispatchEvent(new PointerEvent('pointermove',{pointerId:42,button:0,clientX:400+dx,clientY:300,bubbles:true,cancelable:true}));
            this.paper=paper;this.dx=dx;await this.paint();
          },
          async release(cancel=false){
            this.paper.dispatchEvent(new PointerEvent(cancel?'pointercancel':'pointerup',{pointerId:42,button:0,clientX:400+this.dx,clientY:300,bubbles:true}));
            await this.seek(0);
          }
        };
        """)
        for width in [700,940] {
          try await execute("document.getElementById('layered-note-preview').style.width='\(width)px';await frameProbe.paint()")
          for count in (width == 700 ? [2,4] : [2,4,12,70]) {
            for start in (count > 12 ? [0] : Set([0,count-2]).sorted()) {
                try await execute("await frameProbe.load(\(count),\(start))")
                for direction in [1,-1] {
                    let resting = try await snapshot()
                    try await execute("window.nativeReceive({type:'navigate',direction:\(direction)});await frameProbe.seek(0)")
                    try compare(resting, await snapshot(), "\(width) wide, \(count) cards from \(start), \(direction): animation start")
                    try await execute("await frameProbe.seek(.999999)")
                    let lastFrame = try await snapshot()
                    try await execute("await frameProbe.finish()")
                    try compare(lastFrame, await snapshot(), "\(width) wide, \(count) cards from \(start), \(direction): animation settlement")
                }
            }
          }
        }
        for direction in [1,-1] {
            try await execute("await frameProbe.load(4,1);await frameProbe.drag(\(-260*direction))")
            let held = try await snapshot()
            try await execute("await frameProbe.release()")
            try compare(held, await snapshot(), "\(direction): gesture release")
            try await execute("await frameProbe.finish()")
        }
        for view in ["library", "study"] {
        for (width,count) in [(700,2),(940,6)] {
          for direction in [-1,1] {
            let start = direction > 0 ? count - 1 : 0
            let destination = direction > 0 ? 0 : count - 1
            try await execute("""
            document.getElementById('layered-note-preview').style.width='\(width)px';
            await frameProbe.load(\(count),\(start),'\(view)');await frameProbe.drag(\(-120*direction));
            """)
            let held = try await snapshot()
            try await execute("""
            await frameProbe.release();
            if(!document.getAnimations().some(a=>a.effect.target===frameProbe.paper.closest('.ln-assembly')))
              throw Error('\(view) boundary did not start a paper animation');
            """)
            try compare(held, await snapshot(), "\(width) wide, \(view) boundary \(direction): gesture release")
            try await execute("await frameProbe.seek(.999999)")
            let finalFrame = try await snapshot()
            try await execute("""
            await frameProbe.finish();
            if(document.querySelector('.is-front').dataset.cardId!=='frame-\(destination)')
              throw Error('\(view) boundary settled on the wrong paper');
            """)
            try compare(finalFrame, await snapshot(), "\(width) wide, \(view) boundary \(direction): settlement")
          }
        }
        }
        for (width, count, target, dragged) in [(940,6,0,false),(940,6,3,true),(700,2,0,true),(700,6,3,false)] {
            try await execute("""
            document.getElementById('layered-note-preview').style.width='\(width)px';
            await frameProbe.load(\(count),\(count-1));
            const cards=Array.from(document.querySelectorAll('.ln-assembly'),(node,i)=>({id:'frame-'+i,kind:'review',direction:'wordToMeaning',revealed:true,graded:i!==\(target),
              word:{word:['serendipity','resilient','solace','glimpse'][i%4]+i,reading:'/ˌser.ənˈdɪp.ə.ti/',definition:'纸张 '+i+' 的释义',pos:'名词',example:'This text belongs to sheet '+i+'.',translation:'这张纸的例句 '+i}}));
            nativeReceive({type:'patch',roundID:'rendered-motion',cards,currentID:'frame-\(count-1)',pendingID:'frame-\(target)'});await frameProbe.paint();
            """)
            if dragged { try await execute("await frameProbe.drag(-120)") }
            let before = try await snapshot()
            if dragged { try await execute("await frameProbe.release()") }
            else { try await execute("nativeReceive({type:'navigate',direction:1});await frameProbe.seek(0)") }
            try compare(before, await snapshot(), "\(width) wide, tail to \(target): return pickup")
            try await execute("await frameProbe.seek(.999999)")
            let finalFrame = try await snapshot()
            try await execute("await frameProbe.finish()")
            try compare(finalFrame, await snapshot(), "\(width) wide, tail to \(target): return settlement")
        }
        try await execute("document.getElementById('layered-note-preview').style.width='940px';await frameProbe.paint()")
        try await execute("await frameProbe.load(4,1);await frameProbe.drag(-28)")
        let held = try await snapshot()
        try await execute("await frameProbe.release(true)")
        try compare(held, await snapshot(), "cancelled gesture return")
        try await execute("await frameProbe.finish()")
        try await execute("document.getElementById('layered-note-preview').style.width='700px';await frameProbe.load(4,1);await frameProbe.drag(260)")
        let tucked = try await snapshot()
        try await execute("await frameProbe.release(true)")
        try compare(tucked, await snapshot(), "narrow rightward drag retains paper and tucked note at cancellation")
        try await execute("await frameProbe.seek(.999999)")
        let returned = try await snapshot()
        try await execute("await frameProbe.finish()")
        try compare(returned, await snapshot(), "narrow rightward drag restores the note without a landing jump")
        try await execute("document.getElementById('layered-note-preview').style.width='940px';await frameProbe.paint()")
        for selector in [".ln-paper", ".ln-question-note"] {
            try await execute("await frameProbe.load(4)")
            let resting = try await snapshot()
            try await execute("document.querySelector('.is-front \(selector)').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));await frameProbe.seek(0)")
            try compare(resting, await snapshot(), "reading pickup preserves paper, note and shadows: \(selector)")
            try await execute("await frameProbe.seek(.999999)")
            let enlarged = try await snapshot()
            try await execute("await frameProbe.finish()")
            try compare(enlarged, await snapshot(), "reading text settlement: \(selector)")
            if selector == ".ln-question-note" { try await checkEditorPaint("settled writing invitation") }
            try await execute("document.getElementById('layered-note-preview').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await frameProbe.seek(0)")
            try compare(enlarged, await snapshot(), "reading text at closing pickup: \(selector)")
            try await execute("await frameProbe.seek(.999999)")
            let restored = try await snapshot()
            try await execute("await frameProbe.finish()")
            try compare(restored, await snapshot(), "reading cleanup preserves all painted surfaces: \(selector)")
            try compare(resting, await snapshot(), "reading restores all paper surfaces: \(selector)")
            for fraction in [0.08,0.35,0.7] {
                try await execute("document.querySelector('.is-front \(selector)').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));await frameProbe.seek(\(fraction))")
                let interrupted = try await snapshot()
                try await execute("document.getElementById('layered-note-preview').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await frameProbe.seek(0)")
                try compare(interrupted, await snapshot(), "interrupted reading reverses without a jump at \(fraction): \(selector)")
                try await execute("await frameProbe.finish()")
                try compare(resting, await snapshot(), "interrupted reading restores surfaces: \(selector)")
            }
        }
        try await execute("""
        await frameProbe.load(4);
        const input=document.querySelector('.is-front textarea');
        input.value='阅读时的草稿';input.dispatchEvent(new Event('input',{bubbles:true}));
        document.querySelector('.is-front .ln-question-note').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
        await frameProbe.finish();
        """)
        try await checkEditorPaint("settled draft")
        try await execute("document.getElementById('layered-note-preview').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await frameProbe.finish()")
        for enlarged in [false, true] {
            try await execute("""
            window.answerFixture={type:'round',roundID:'answer-paint',language:'en',currentID:'answer',cards:[
              {id:'answer',kind:'review',direction:'meaningToWord',revealed:false,graded:false,
               word:{word:'serendipity',reading:'/ˌser.ənˈdɪp.ə.ti/',definition:'意外发现美好事物的运气',pos:'名词',example:'A moment of serendipity.',translation:'一次美好的偶然。'}}]};
            nativeReceive(answerFixture);await frameProbe.paint();
            """)
            if enlarged {
                try await execute("document.querySelector('.is-front [data-zoom=word]').click();await frameProbe.finish()")
            }
            let prompt = try await snapshot()
            try await execute("""
            answerFixture.cards=[{...answerFixture.cards[0],revealed:true}];
            nativeReceive({...answerFixture,type:'patch'});await frameProbe.seek(0);
            if(!document.querySelector('.ln-reveal-front')||!document.getAnimations().length)throw new Error('answer paint check must start a real turn');
            """)
            try compare(prompt, await snapshot(), "answer turn preserves prompt at pickup, enlarged: \(enlarged)")
            for elapsed in [336,560,784] {
                try await execute("await frameProbe.seek(\(Double(elapsed)/1360))")
                let lifted = try await snapshot()
                // A lifted paper must leave no fixed rectangular contact shadow.
                // Hide only that surface: the airborne shadow and all faces stay intact.
                try await execute("document.querySelector('.is-front .ln-ground-shadow').style.visibility='hidden';await frameProbe.paint()")
                try compare(lifted, await snapshot(), "answer turn leaves no stationary shadow at \(elapsed)ms, enlarged: \(enlarged)")
                if elapsed == 560 {
                    let center: Any = try await withCheckedThrowingContinuation { continuation in
                        renderer.webView.callAsyncJavaScript("""
                        document.querySelectorAll('.is-front .ln-paper,.is-front .ln-reveal-backing').forEach(node=>node.style.visibility='hidden');
                        await frameProbe.paint();
                        const box=document.querySelector('.ln-reveal-shadow').getBoundingClientRect();
                        return [(box.left+box.right)/2,(box.top+box.bottom)/2];
                        """, arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
                    }
                    guard let point = center as? [Double], point.count == 2 else { throw ApplicationFailure(message: "airborne shadow center") }
                    let shadow = try await snapshot()
                    try await execute("document.querySelector('.ln-reveal-shadow').style.visibility='hidden';await frameProbe.paint()")
                    let clear = try await snapshot()
                    let scale = Double(shadow.pixelsWide) / renderer.webView.bounds.width
                    let x = Int(point[0]*scale), y = Int(point[1]*scale)
                    try check(x >= 0 && x < shadow.pixelsWide && y >= 0 && y < shadow.pixelsHigh, "airborne shadow center remains in the snapshot")
                    let a = y * shadow.bytesPerRow + x * 4, b = y * clear.bytesPerRow + x * 4
                    try check((0..<4).contains { abs(Int(shadow.bitmapData![a+$0])-Int(clear.bitmapData![b+$0])) > 8 }, "airborne shadow paints its center instead of leaving a hollow rectangle, enlarged: \(enlarged)")
                    try await execute("document.querySelectorAll('.is-front .ln-paper,.is-front .ln-reveal-backing,.ln-reveal-shadow').forEach(node=>node.style.removeProperty('visibility'));await frameProbe.paint()")
                }
                try await execute("document.querySelector('.is-front .ln-ground-shadow').style.removeProperty('visibility');await frameProbe.paint()")
            }
            try await execute("await frameProbe.seek(.999999)")
            let answer = try await snapshot()
            try await execute("await frameProbe.finish()")
            try compare(answer, await snapshot(), "answer turn preserves text and note at settlement, enlarged: \(enlarged)")
        }
        try await execute("delete window.answerFixture")
        for (width, count) in [(700,1),(700,4),(940,70)] {
            try await execute("""
            document.getElementById('layered-note-preview').style.width='\(width)px';
            nativeReceive({type:'round',roundID:'summary',language:'en',cards:[],title:'这一轮先到这里',caption:'本轮小结',summary:'还有 1 张词卡未完成。',detail:'本轮留言已清空'});
            await frameProbe.paint();
            """)
            let summary = try await snapshot()
            try await execute("""
            document.querySelector('.ln-start').click();await frameProbe.load(\(count));await frameProbe.seek(0);
            if(!document.querySelector('.ln-round-front')||!document.getAnimations().length)throw Error('new-round paint check must start a real entrance');
            """)
            try compare(summary, await snapshot(), "\(width) wide, \(count) new cards: summary pickup")
            try await execute("await frameProbe.seek(.999999)")
            let spread = try await snapshot()
            try await execute("await frameProbe.finish()")
            try compare(spread, await snapshot(), "\(width) wide, \(count) new cards: spread and note settlement")
        }
        try await execute("delete window.frameProbe")
        print("PASS: rendered paper, text, note and shadow continuity at pickup, turn, settlement and gesture release")
    }
}
