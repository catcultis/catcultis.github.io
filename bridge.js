/* Catcul integration bridge. Jeeliz FaceFilter and demo code: Apache 2.0; see ../../LICENSE. */
(function(){
 let capturePending=false,ready=false;
 const report=(type,extra={})=>parent.postMessage({source:'catcul-jeeliz',type,...extra},location.origin);
 window.jeelizBridgeReady=()=>{ready=true;report('ready')};
 window.jeelizBridgeError=code=>{const e=document.getElementById('jeeliz-error');if(e){e.hidden=false;e.textContent='Could not start this filter. Check camera permission and WebGL support. ('+String(code)+')';}report('error',{code:String(code)});};
 window.jeelizBridgeFrame=()=>{
  if(!capturePending)return;capturePending=false;
  try{const canvas=document.getElementById('jeeFaceFilterCanvas');const out=document.createElement('canvas');out.width=canvas.width;out.height=canvas.height;const c=out.getContext('2d');c.translate(out.width,0);c.scale(-1,1);c.drawImage(canvas,0,0);report('photo',{data:out.toDataURL('image/jpeg',.92),width:out.width,height:out.height});}catch(e){report('error',{code:'photo unavailable'});}
 };
 window.addEventListener('message',e=>{if(e.source!==parent || e.origin!==location.origin || e.data?.source!=='catcul-parent')return;
  if(e.data.action==='capture'){if(ready)capturePending=true;else report('error',{code:'still starting'});}
  if(e.data.action==='stop'){try{JEELIZFACEFILTER.destroy();}catch(e){} }
 });
 window.addEventListener('error',e=>window.jeelizBridgeError(e.message||'script error'));
 window.addEventListener('pagehide',()=>{try{JEELIZFACEFILTER.destroy()}catch(e){}});
})();
