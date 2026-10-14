const puppeteer=require('puppeteer-core');
(async()=>{
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage','--disk-cache-size=0']});
 const page=await browser.newPage();
 await page.setViewport({width:412,height:915,deviceScaleFactor:2,isMobile:true,hasTouch:true});
 await page.setCacheEnabled(false);
 const err=[];page.on('pageerror',e=>err.push(String(e).slice(0,200)));
 await page.evaluateOnNewDocument(()=>{
  window.__vc={cls:0,lcp:0,longTasks:0};
  new PerformanceObserver(l=>{for(const e of l.getEntries())if(!e.hadRecentInput)window.__vc.cls+=e.value;}).observe({type:'layout-shift',buffered:true});
  new PerformanceObserver(l=>{for(const e of l.getEntries())window.__vc.lcp=Math.round(e.startTime);}).observe({type:'largest-contentful-paint',buffered:true});
  new PerformanceObserver(l=>{for(const e of l.getEntries())window.__vc.longTasks+=e.duration;}).observe({type:'longtask',buffered:true});
 });
 let res=await page.goto('https://vesta-cosmetics.ir/',{waitUntil:'domcontentloaded',timeout:70000});
 await new Promise(r=>setTimeout(r,9000));
 const pre=await page.evaluate(()=>{
  const cards=[...document.querySelectorAll('.wd-carousel-container.slider-type-product .product-wrapper')];
  const cars=[...document.querySelectorAll('.owl-carousel.wd-owl')];
  const styled=cards.filter(e=>getComputedStyle(e).contentVisibility==='auto').length;
  return {idPresent:!!document.getElementById('vc-mobile-product-render'),httpStatus:document.readyState,
   cards:cards.length,styled,cars:cars.length,loaded:cars.filter(x=>x.classList.contains('owl-loaded')).length,
   cls:+(window.__vc.cls||0).toFixed(4),lcp:window.__vc.lcp,longTasks:Math.round(window.__vc.longTasks),
   height:document.body.scrollHeight,webp:document.querySelectorAll('picture source[type="image/webp"]').length,
   oldOwlCss:!!document.getElementById('vc-owl-preinit-layout'),
   addToCart:document.querySelectorAll('button.single_add_to_cart_button,a.add_to_cart_button').length};
 });
 await page.evaluate(()=>window.scrollTo({top:document.body.scrollHeight*0.65,behavior:'instant'}));
 await new Promise(r=>setTimeout(r,2200));
 const sc=await page.evaluate(()=>{
  const cards=[...document.querySelectorAll('.wd-carousel-container.slider-type-product .product-wrapper')];
  const visible=cards.filter(e=>{const r=e.getBoundingClientRect();return r.top<innerHeight&&r.bottom>0;});
  return {visible:visible.length,imagesLoaded:visible.filter(e=>e.querySelector('img')?.naturalWidth>0).length,
   bodyHeight:document.body.scrollHeight,scrollY:scrollY,
   activeCarousels:[...document.querySelectorAll('.owl-carousel.wd-owl.owl-loaded')].length};
 });
 console.log('VESTA_POST_RENDER',JSON.stringify({http:res?.status(),pre,scroll:sc,errors:err}));
 const ok=res?.status()===200&&pre.idPresent&&pre.styled>=120&&pre.cards>=120&&pre.cars>=14&&pre.loaded>=14&&pre.cls<0.33&&pre.height>6900&&pre.height<7800&&pre.webp>=9&&pre.oldOwlCss&&pre.addToCart>=100&&sc.visible>0&&sc.imagesLoaded>0&&sc.activeCarousels>=14&&sc.bodyHeight<8000&&err.length===0;
 await browser.close();
 if(!ok){console.error('VESTA_POST_RENDER_FAILED');process.exit(2);}
 console.log('VESTA_PRODUCT_RENDER_VERIFIED');
})().catch(e=>{console.error(e.stack);process.exit(1)});
