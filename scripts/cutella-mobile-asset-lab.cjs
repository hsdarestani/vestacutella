const puppeteer=require('puppeteer-core');

const modes=[
 {id:'baseline1',block:[]},
 {id:'block_revslider1',block:['/revslider/public/js/sr7.js','/revslider/public/js/libs/tptools.js']},
 {id:'baseline2',block:[]},
 {id:'block_revslider2',block:['/revslider/public/js/sr7.js','/revslider/public/js/libs/tptools.js']},
 {id:'baseline3',block:[]},
 {id:'block_revslider3',block:['/revslider/public/js/sr7.js','/revslider/public/js/libs/tptools.js']}
];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function check(m){
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage','--disk-cache-size=0']});
 const page=await browser.newPage();
 await page.setViewport({width:412,height:915,isMobile:true,hasTouch:true,deviceScaleFactor:2});
 await page.setCacheEnabled(false);
 const cdp=await page.target().createCDPSession();
 await cdp.send('Network.enable');
 await cdp.send('Network.setCacheDisabled',{cacheDisabled:true});
 await cdp.send('Network.emulateNetworkConditions',{offline:false,latency:120,downloadThroughput:190000,uploadThroughput:75000,connectionType:'cellular3g'});
 await cdp.send('Emulation.setCPUThrottlingRate',{rate:4});
 const blocked=[];const errors=[];const failed=[];
 page.on('pageerror',e=>errors.push(String(e).slice(0,180)));
 page.on('requestfailed',r=>{const u=r.url();if(!m.block.some(s=>u.includes(s)))failed.push({url:u.slice(0,170),failure:r.failure()?.errorText});});
 if(m.block.length){
  await page.setRequestInterception(true);
  page.on('request',r=>{
    if(m.block.some(s=>r.url().includes(s))){blocked.push(r.url());r.abort('blockedbyclient');}
    else r.continue();
  });
 }
 await page.evaluateOnNewDocument(()=>{
  window.__webVital={fcp:null,lcp:null,cls:0};
  try{
   new PerformanceObserver(list=>{for(const e of list.getEntries())if(e.name==='first-contentful-paint')window.__webVital.fcp=Math.round(e.startTime);}).observe({type:'paint',buffered:true});
   new PerformanceObserver(list=>{for(const e of list.getEntries())window.__webVital.lcp=Math.round(e.startTime);}).observe({type:'largest-contentful-paint',buffered:true});
   new PerformanceObserver(list=>{for(const e of list.getEntries())if(!e.hadRecentInput)window.__webVital.cls+=e.value;}).observe({type:'layout-shift',buffered:true});
  }catch(e){}
 });
 const start=Date.now();
 let http=0;let err='';
 try{
  let r=await page.goto('https://cutellashop.ir/',{waitUntil:'domcontentloaded',timeout:50000});
  http=r?.status()||0;
  await sleep(11000);
 }catch(e){err=String(e).slice(0,200);}
 let details={};
 try{
 details=await page.evaluate(()=>{
   const b=document.querySelector('.cutella-banner-track img,.cutella-banner-slide img');
   const banner=document.querySelector('.cutella-banner-track');
   const header=document.querySelector('header,.cutella-site-header,.cutella-header');
   const buttons=[...document.querySelectorAll('button,a')];
   return {
     ...window.__webVital,
     bannerExists:!!banner,
     bannerLoaded:!!b&&b.naturalWidth>0,
     bannerNatural:b?{w:b.naturalWidth,h:b.naturalHeight}:null,
     bannerRect:banner?{w:Math.round(banner.getBoundingClientRect().width),h:Math.round(banner.getBoundingClientRect().height)}:null,
     headerText:header?.innerText.slice(0,100)||null,
     navButtons:buttons.filter(b=>/سبد خرید|جستجو|ورود|حساب|فروشگاه/.test(b.textContent||'')).length,
     products:document.querySelectorAll('.cutella-product-card,.product-wrapper').length,
     imagesLoaded:[...document.images].filter(i=>i.naturalWidth>0).length,
     slideDots:document.querySelectorAll('.cutella-slider-dots button').length,
     revSliderModules:document.querySelectorAll('rs-module,.rev_slider,.rev_slider_wrapper').length,
     dashiconElements:document.querySelectorAll('[class*="dashicons"]').length,
     bodyHeight:document.body.scrollHeight
   };
 });
 }catch(e){err+=String(e);}
 const result={mode:m.id,http,ms:Date.now()-start,details,blocked:blocked.map(u=>u.slice(-115)),errors:errors.slice(0,4),failed:failed.slice(0,3),error:err};
 console.log('CUTELLA_LAB',JSON.stringify(result));
 await browser.close();
 return result;
}
(async()=>{
 const results=[];
 for(const m of modes){results.push(await check(m));}
 const baselines=results.filter(r=>r.mode.startsWith('baseline'));
 const avg=(key)=>baselines.reduce((s,r)=>s+(r.details?.[key]||0),0)/baselines.length;
 console.log('BASELINE_AVERAGES',JSON.stringify({FCP:avg('fcp'),LCP:avg('lcp'),CLS:avg('cls')}));
 for(const r of results)if(!r.mode.startsWith('baseline'))console.log('EXPERIMENT_DELTA',r.mode,JSON.stringify({
  dFCP:Math.round((r.details.fcp||0)-avg('fcp')),
  dLCP:Math.round((r.details.lcp||0)-avg('lcp')),
  bannerLoaded:r.details.bannerLoaded,
  hasProducts:r.details.products,
  jsErrors:r.errors.length,
  failedRequests:r.failed.length
 }));
})().catch(e=>{console.error('CUTELLA_LAB_FAILURE',e.stack);process.exit(1)});
