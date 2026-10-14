const puppeteer=require('puppeteer-core');
const variants=[
 {site:'vesta',id:'baseline',css:''},
 {site:'vesta',id:'post_contain',css:'.wd-carousel-container.slider-type-post{contain:layout!important;}'},
 {site:'vesta',id:'post_content_visibility',css:'@media(max-width:767px){.wd-carousel-container.slider-type-post{content-visibility:auto;contain-intrinsic-size:auto 650px;}}'},
 {site:'vesta',id:'owl_preinit_block',css:'@media(max-width:767px){.wd-carousel-container > .owl-carousel.wd-owl:not(.owl-loaded){display:block!important;}}'},
 {site:'vesta',id:'owl_preinit_minheight',css:'@media(max-width:767px){.wd-carousel-container.slider-type-post>.owl-carousel:not(.owl-loaded){min-height:650px!important;}}'},
 {site:'cutella',id:'baseline',block:[]},
 {site:'cutella',id:'no_dashicons',block:['/wp-includes/css/dashicons.min.css']},
 {site:'cutella',id:'no_revslider_js',block:['/plugins/revslider/public/js/sr7.js','/plugins/revslider/public/js/libs/tptools.js']}
];
const urlOf=site=>site==='vesta'?'https://vesta-cosmetics.ir/':'https://cutellashop.ir/';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function trial(browser,test){
 const page=await browser.newPage();
 await page.setViewport({width:412,height:915,isMobile:true,hasTouch:true,deviceScaleFactor:2});
 await page.setUserAgent('Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36');
 const blocked=[];
 if(test.block?.length){
  await page.setRequestInterception(true);
  page.on('request',r=>{
   if(test.block.some(s=>r.url().includes(s))){blocked.push(r.url());r.abort();}else r.continue();
  });
 }
 await page.evaluateOnNewDocument(css=>{
  window.__shifts=[];
  new PerformanceObserver(list=>{
   for(const e of list.getEntries()){
    if(!e.hadRecentInput) window.__shifts.push({time:Math.round(e.startTime),value:e.value,nodes:(e.sources||[]).map(x=>x.node?.className?.toString().slice(0,80))});
   }
  }).observe({type:'layout-shift',buffered:true});
  if(css){
   const inject=()=>{
    if(!document.head)return;
    let el=document.getElementById('vc-experiment-css');
    if(el)return;
    el=document.createElement('style');el.id='vc-experiment-css';el.textContent=css;document.head.append(el);
   };
   const obs=new MutationObserver(inject);
   obs.observe(document,{subtree:true,childList:true});
   inject();
  }
 },test.css||'');
 let fail=null;
 const errors=[];
 page.on('pageerror',e=>errors.push(String(e).slice(0,250)));
 const started=Date.now();
 try{await page.goto(urlOf(test.site),{waitUntil:'domcontentloaded',timeout:70000});await sleep(8000);}
 catch(e){fail=String(e).slice(0,260);}
 const output=await page.evaluate(()=>{
  const entries=performance.getEntriesByType('resource');
  const nav=performance.getEntriesByType('navigation')[0];
  const shifts=window.__shifts||[];
  const h=document.querySelector('h1');
  let images=document.images;
  const broken=[...images].filter(x=>x.complete && x.naturalWidth===0 && !x.getAttribute('data-src')).slice(0,5).map(x=>x.src);
  const carousel=[...document.querySelectorAll('.owl-carousel.wd-owl')];
  return {
   title:document.title,
   cls:Math.round(shifts.reduce((a,b)=>a+b.value,0)*1000)/1000,
   shifts:shifts.filter(x=>x.value>0.01).slice(0,5),
   htmlReady:document.readyState,
   navDuration:Math.round(nav?.duration||0),
   contentCount:document.querySelectorAll('.product,.product-grid-item,.wd-product').length,
   carouselCount:carousel.length,
   carouselLoaded:carousel.filter(x=>x.classList.contains('owl-loaded')).length,
   heroVisible:!!document.querySelector('.cutella-banner-track img, .main-wrapp-img img'),
   bannerDimensions:[...document.querySelectorAll('.cutella-banner-track img, .main-wrapp-img img')].slice(0,2).map(x=>({w:x.naturalWidth,h:x.naturalHeight})),
   broken,
   scripts:entries.filter(x=>/revslider|dashicons/.test(x.name)).map(x=>({url:x.name.slice(-110),ms:Math.round(x.duration),bytes:x.transferSize})).slice(0,8),
   cssInjected:!!document.getElementById('vc-experiment-css'),
   h1:h?.textContent?.trim().slice(0,60)
  };
 });
 output.site=test.site;output.variant=test.id;output.errors=errors.slice(0,5);output.blocked=blocked;output.failure=fail;output.wallTime=Date.now()-started;
 console.log('TRIAL',JSON.stringify(output));
 await page.close();
 return output;
}
(async()=>{
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
 const results=[];
 for(const v of variants){
  try{results.push(await trial(browser,v));}catch(e){console.log('TRIAL_ERROR',v.site,v.id,String(e));}
 }
 await browser.close();
 const base=results.find(x=>x.site==='vesta'&&x.variant==='baseline');
 const cut=results.find(x=>x.site==='cutella'&&x.variant==='baseline');
 for(const r of results){const b=r.site==='vesta'?base:cut;console.log('COMPARISON',r.site,r.variant,'CLS',r.cls,'delta',b?Number((r.cls-b.cls).toFixed(3)):null,'images',r.broken.length,'products',r.contentCount,'carousel_loaded',r.carouselLoaded,'fail',r.failure);}
})().catch(e=>{console.error(e);process.exit(1)});
