const puppeteer=require('puppeteer-core');
const variants=[
 {id:'baseline_a',css:''},
 {id:'defer_lower_rows',css:'@media(max-width:767px){article#post-59383 .wpb-content-wrapper > .vc_row:nth-of-type(n+6){content-visibility:auto;contain-intrinsic-size:auto 520px;}}'},
 {id:'baseline_b',css:''},
 {id:'defer_product_cards',css:'@media(max-width:767px){.wd-carousel-container.slider-type-product .wd-product{content-visibility:auto;contain-intrinsic-size:auto 350px;}}'},
 {id:'defer_lower_carousels',css:'@media(max-width:767px){article#post-59383 .wd-carousel-container.slider-type-product:nth-of-type(n+5){content-visibility:auto;contain-intrinsic-size:auto 430px;}}'},
 {id:'baseline_c',css:''}
];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function test(v){
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage','--disk-cache-size=0']});
 const page=await browser.newPage();
 await page.setViewport({width:412,height:915,isMobile:true,hasTouch:true,deviceScaleFactor:2});
 await page.setCacheEnabled(false);
 const cdp=await page.target().createCDPSession();
 await cdp.send('Network.enable');
 await cdp.send('Network.setCacheDisabled',{cacheDisabled:true});
 await cdp.send('Emulation.setCPUThrottlingRate',{rate:4});
 await page.evaluateOnNewDocument(css=>{
   window.__perf={fcp:null,lcp:null,cls:0,longTasks:0,longTaskMs:0};
   try{
    new PerformanceObserver(l=>{for(const e of l.getEntries())if(e.name==='first-contentful-paint')window.__perf.fcp=Math.round(e.startTime);}).observe({type:'paint',buffered:true});
    new PerformanceObserver(l=>{for(const e of l.getEntries())window.__perf.lcp=Math.round(e.startTime);}).observe({type:'largest-contentful-paint',buffered:true});
    new PerformanceObserver(l=>{for(const e of l.getEntries())if(!e.hadRecentInput)window.__perf.cls+=e.value;}).observe({type:'layout-shift',buffered:true});
    new PerformanceObserver(l=>{for(const e of l.getEntries()){window.__perf.longTasks++;window.__perf.longTaskMs+=e.duration;}}).observe({type:'longtask',buffered:true});
   }catch(e){}
   if(!css)return;
   const inject=()=>{
    if(!document.head||document.getElementById('vc-ab-css'))return;
    const style=document.createElement('style');style.id='vc-ab-css';style.textContent=css;document.head.appendChild(style);
   };
   const obs=new MutationObserver(inject);
   obs.observe(document,{childList:true,subtree:true});
   inject();
 },v.css);
 const errors=[];page.on('pageerror',e=>errors.push(String(e).slice(0,180)));
 let failure='';
 let http=0;
 try{
  const r=await page.goto('https://vesta-cosmetics.ir/',{waitUntil:'domcontentloaded',timeout:65000});
  http=r?.status()||0;
  await sleep(8500);
 }catch(e){failure=String(e).slice(0,180);}
 const before=await page.evaluate(()=>{
  const cs=[...document.querySelectorAll('.owl-carousel.wd-owl')];
  const products=[...document.querySelectorAll('.product-wrapper')];
  const cv=[...document.querySelectorAll('.vc_row')].filter(e=>getComputedStyle(e).contentVisibility==='auto');
  return {
   perf:{...window.__perf,cls:+window.__perf.cls.toFixed(4),longTaskMs:Math.round(window.__perf.longTaskMs)},
   hasCss:!!document.getElementById('vc-ab-css'),
   carouselCount:cs.length,
   loadedCarousels:cs.filter(x=>x.classList.contains('owl-loaded')).length,
   productCards:products.length,
   webpSources:document.querySelectorAll('picture source[type="image/webp"]').length,
   lazyImages:document.querySelectorAll('img[loading="lazy"]').length,
   deferredRows:cv.length,
   bodyHeight:document.body.scrollHeight,
   heroLoaded:!![...document.querySelectorAll('picture img')].find(i=>i.naturalWidth>0)
  };
 });
 let scroll={};
 try{
  await page.evaluate(()=>window.scrollTo({top:Math.round(document.body.scrollHeight*0.65),behavior:'instant'}));
  await sleep(1400);
  scroll=await page.evaluate(()=>{
   const p=[...document.querySelectorAll('.product-wrapper')];
   const visible=p.filter(e=>{const r=e.getBoundingClientRect();return r.top<window.innerHeight&&r.bottom>0;});
   const loaded=[...document.querySelectorAll('.owl-carousel.wd-owl')].filter(x=>x.classList.contains('owl-loaded')).length;
   return {scrollY:Math.round(scrollY),visibleProductCards:visible.length,visibleProductImgsLoaded:visible.filter(e=>e.querySelector('img')?.naturalWidth>0).length,loadedCarousels:loaded,bodyHeight:document.body.scrollHeight};
  });
 }catch(e){scroll.error=String(e).slice(0,130);}
 const out={variant:v.id,http,before,scroll,pageErrors:errors.slice(0,4),failure};
 console.log('VESTA_RENDER_LAB',JSON.stringify(out));
 await browser.close();
 return out;
}
(async()=>{
 const results=[];
 for(const v of variants){results.push(await test(v));}
 const base=results.filter(r=>r.variant.startsWith('baseline')&&r.http===200);
 const avg=k=>base.reduce((a,b)=>a+(b.before.perf[k]||0),0)/Math.max(base.length,1);
 console.log('RENDER_LAB_BASELINE',JSON.stringify({fcp:avg('fcp'),lcp:avg('lcp'),cls:avg('cls'),longTaskMs:avg('longTaskMs'),samples:base.length}));
 for(const r of results.filter(r=>!r.variant.startsWith('baseline'))){
  const x=r.before.perf;
  console.log('RENDER_LAB_DELTA',JSON.stringify({variant:r.variant,dFCP:Math.round((x.fcp||0)-avg('fcp')),dLCP:Math.round((x.lcp||0)-avg('lcp')),dCLS:+((x.cls||0)-avg('cls')).toFixed(4),dLongTaskMs:Math.round((x.longTaskMs||0)-avg('longTaskMs')),carouselCount:r.before.carouselCount,carouselLoaded:r.before.loadedCarousels,productCards:r.before.productCards,scroll:r.scroll,errors:r.pageErrors,failure:r.failure}));
 }
})().catch(e=>{console.error('LAB_ERROR',e.stack);process.exit(1)});
