/* Export the painted paper outlines to native window mouse routing. */
(() => {
  'use strict';
  function create({root,send,getSurfaces,isMoving}) {
    const corners=new WeakMap();
    let frame=0,last='';
    function markersFor(node) {
      let markers=corners.get(node);
      if(!markers){
        const style=getComputedStyle(node);
        markers=[[0,0],[1,0],[1,1],[0,1]].map(([right,bottom])=>{
          const marker=document.createElement('span');
          marker.className='ln-surface-corner';marker.setAttribute('aria-hidden','true');
          marker.style[right?'right':'left']=`${-parseFloat(style[right?'borderRightWidth':'borderLeftWidth'])}px`;
          marker.style[bottom?'bottom':'top']=`${-parseFloat(style[bottom?'borderBottomWidth':'borderTopWidth'])}px`;
          node.append(marker);return marker;
        });
        corners.set(node,markers);
      }
      return markers;
    }
    function outline(node) {
      // Zero-size points follow WebKit's full ancestor transforms/perspective.
      // An axis-aligned bounding box would reserve empty space at tilted corners.
      return markersFor(node).map(marker=>{
        const point=marker.getBoundingClientRect();
        return {x:Math.round(point.x*4)/4,y:Math.round(point.y*4)/4};
      });
    }
    function publish() {
      frame=0;
      const polygons=getSurfaces().filter(node=>node.getClientRects().length && +getComputedStyle(node).opacity>.005).map(outline);
      const surfaceLayout={width:root.clientWidth,height:root.clientHeight,polygons};
      const signature=JSON.stringify(surfaceLayout);
      if(signature!==last){last=signature;send('windowSurfaceLayout',{surfaceLayout});}
      if(isMoving())invalidate();
    }
    function invalidate() { if(!frame)frame=requestAnimationFrame(publish); }
    return Object.freeze({invalidate,prepare:nodes=>nodes.forEach(markersFor)});
  }
  globalThis.PaperSurfaces=Object.freeze({create});
})();
