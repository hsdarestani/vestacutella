const puppeteer = require('puppeteer-core');
(async()=>{
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
 const page=await browser.newPage();
 await page.setViewport({width:412,height:915,deviceScaleFactor:2,isMobile:true,hasTouch:true});
 await page.evaluateOnNewDocument(()=>{
   window.__vc_shifts=[];
   new PerformanceObserver(list=>{
     for(const e of list.getEntries()){
       if(e.hadRecentInput) continue;
       const sources=(e.sources||[]).slice(0,5).map(s=>{
         const n=s.node; let id='';
         if(n){id=n.tagName?.toLowerCase()||''; if(n.id)id+='#'+n.id;if(n.className&&typeof n.className==='string')id+='.'+n.className.trim().split(/\s+/).slice(0,4).join('.')}
         return {node:id,old:s.previousRect,new:s.currentRect};
       });
       window.__vc_shifts.push({value:e.value,time:Math.round(e.startTime),sources});
     }
   }).observe({type:'layout-shift',buffered:true});
 });
 await page.goto('https://vesta-cosmetics.ir/',{waitUntil:'domcontentloaded',timeout:70000});
 async function snapshot(label){
  const data=await page.evaluate(()=>{
   const sel=['#carousel-998','#carousel-998 > .owl-carousel','#carousel-998 .owl-stage','.wd-products','.whb-mobile-center','.main-wrapp-img','.wd-carousel-container','.wpb_wrapper > .owl-carousel'];
   const arr=sel.map(q=>{let e=document.querySelector(q);if(!e)return {q,found:false};let a=getComputedStyle(e);let r=e.getBoundingClientRect();return {q,found:true,y:Math.round(r.y),h:Math.round(r.height),minHeight:a.minHeight,visibility:a.visibility,display:a.display,position:a.position,overflow:a.overflow,children:e.children.length}});
   const shifts=window.__vc_shifts||[];
   return {arr,shifts:shifts.slice(-12),sum:shifts.reduce((a,b)=>a+b.value,0),images:document.images.length,ready:document.readyState};
  });
  console.log('SNAPSHOT',label,JSON.stringify(data).slice(0,13500));
 }
 await snapshot('domloaded');
 for(const [ms,label] of [[1500,'t1.5'],[3500,'t5'],[6000,'t11'],[7000,'t18']]){await new Promise(r=>setTimeout(r,ms));await snapshot(label);}
 await browser.close();
})().catch(e=>{console.error('DOM_AUDIT_ERROR',e.stack);process.exit(1)});
