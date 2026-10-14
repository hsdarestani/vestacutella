const puppeteer=require('puppeteer-core');
(async()=>{
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
 const page=await browser.newPage();
 await page.setViewport({width:412,height:915,deviceScaleFactor:2,isMobile:true,hasTouch:true});
 await page.evaluateOnNewDocument(()=>{
  const rect=n=>{const r=n?.getBoundingClientRect();return r?{x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.width),h:Math.round(r.height)}:null};
  const desc=n=>n?{tag:n.tagName,cls:String(n.className||'').slice(0,110),id:n.id||'',rect:rect(n),style:{display:getComputedStyle(n).display,height:getComputedStyle(n).height,minHeight:getComputedStyle(n).minHeight,overflow:getComputedStyle(n).overflow}}:null;
  window.__vc_shifts=[];
  window.__vc_samples=[];
  new PerformanceObserver(list=>{
   for(const e of list.getEntries()){
    if(e.hadRecentInput)continue;
    window.__vc_shifts.push({time:Math.round(e.startTime),value:e.value,sources:(e.sources||[]).map(s=>({node:desc(s.node),parent:desc(s.node?.parentElement),grandparent:desc(s.node?.parentElement?.parentElement),previous:{x:s.previousRect?.x,y:s.previousRect?.y,w:s.previousRect?.width,h:s.previousRect?.height},current:{x:s.currentRect?.x,y:s.currentRect?.y,w:s.currentRect?.width,h:s.currentRect?.height}}))});
   }
  }).observe({type:'layout-shift',buffered:true});
  let num=0;
  const timer=setInterval(()=>{
   const els=Array.from(document.querySelectorAll('.owl-carousel.wd-owl'));
   const sample={t:Math.round(performance.now()),found:els.length,items:els.slice(0,18).map((el,index)=>({index,me:desc(el),parent:desc(el.parentElement),grandparent:desc(el.parentElement?.parentElement),childCount:el.children.length}))};
   window.__vc_samples.push(sample);
   if(++num>=35)clearInterval(timer);
  },300);
 });
 await page.goto('https://vesta-cosmetics.ir/',{waitUntil:'domcontentloaded',timeout:75000});
 await new Promise(r=>setTimeout(r,9000));
 const result=await page.evaluate(()=>{
  const samples=window.__vc_samples||[];
  const interesting=[600,1500,2400,3300,4200,5100,7500,9900,11000];
  const selected=interesting.map(t=>samples.reduce((best,s)=>!best || Math.abs(s.t-t)<Math.abs(best.t-t)?s:best,null)).filter(Boolean);
  return {shifts:window.__vc_shifts||[],samples:selected};
 });
 console.log('SHIFT_EVENTS',JSON.stringify(result.shifts).slice(0,23000));
 for(const s of result.samples){
  console.log('CAROUSEL_SAMPLE',s.t,s.found,JSON.stringify(s.items).slice(0,13000));
 }
 await browser.close();
})().catch(e=>{console.error('DOM_AUDIT_ERROR',e.stack);process.exit(1)});
