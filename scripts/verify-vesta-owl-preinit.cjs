const puppeteer=require('puppeteer-core');
(async()=>{
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage','--disk-cache-size=0']});
 const page=await browser.newPage();
 await page.setViewport({width:412,height:915,isMobile:true,hasTouch:true,deviceScaleFactor:2});
 await page.setCacheEnabled(false);
 await page.evaluateOnNewDocument(()=>{
  window.__shifts=[];
  new PerformanceObserver(l=>{
   for(const e of l.getEntries())if(!e.hadRecentInput)window.__shifts.push({value:e.value,t:Math.round(e.startTime)});
  }).observe({type:'layout-shift',buffered:true});
 });
 const errors=[];
 page.on('pageerror',e=>errors.push(String(e).slice(0,180)));
 const response=await page.goto('https://vesta-cosmetics.ir/',{waitUntil:'domcontentloaded',timeout:75000});
 await new Promise(r=>setTimeout(r,9000));
 const data=await page.evaluate(()=>{
  const owl=[...document.querySelectorAll('.owl-carousel.wd-owl')];
  return {
   cssPresent:!!document.getElementById('vc-owl-preinit-layout'),
   cls:+(window.__shifts||[]).reduce((a,x)=>a+x.value,0).toFixed(4),
   carousels:owl.length,
   loaded:owl.filter(x=>x.classList.contains('owl-loaded')).length,
   productCards:document.querySelectorAll('.product-wrapper').length,
   webpSources:document.querySelectorAll('picture source[type="image/webp"]').length,
   heroLoaded:!!document.querySelector('picture img.naturalWidth, .main-wrapp-img img'),
   pageTitle:document.title
  };
 });
 data.http=response?.status();data.jsErrors=errors;
 console.log('PRODUCTION_CLS_VERIFICATION',JSON.stringify(data));
 const ok=data.http===200&&data.cssPresent&&data.cls<0.65&&data.carousels>=13&&data.loaded>=13&&data.productCards>=125&&data.webpSources>=9&&errors.length===0;
 await browser.close();
 if(!ok){console.error('PRODUCTION_CLS_REGRESSION_OR_NO_IMPROVEMENT');process.exit(2);}
 console.log('PRODUCTION_CLS_IMPROVED_AND_STORE_STABLE');
})().catch(e=>{console.error('CLS_VERIFY_ERROR',e.stack);process.exit(1)});
