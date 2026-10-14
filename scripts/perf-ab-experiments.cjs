const puppeteer=require('puppeteer-core');
const samples=[
 {id:'baseline_a',css:''},
 {id:'all_carousel_contain',css:'@media(max-width:767px){.wd-carousel-container:has(>.owl-carousel){contain:layout!important;}}'},
 {id:'baseline_b',css:''},
 {id:'all_owl_preinit_block',css:'@media(max-width:767px){.wd-carousel-container>.owl-carousel.wd-owl:not(.owl-loaded){display:block!important;}}'},
 {id:'baseline_c',css:''},
 {id:'post_content_visibility',css:'@media(max-width:767px){.wd-carousel-container.slider-type-post{content-visibility:auto;contain-intrinsic-size:auto 650px;}}'}
]
(async()=>{
 for(const test of samples){
  const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage','--disk-cache-size=0']});
  const page=await browser.newPage();
  await page.setViewport({width:412,height:915,isMobile:true,hasTouch:true,deviceScaleFactor:2});
  await page.setCacheEnabled(false);
  await page.evaluateOnNewDocument(css=>{
    window.__shifts=[];
    new PerformanceObserver(l=>{
      for(const e of l.getEntries())if(!e.hadRecentInput)window.__shifts.push({t:Math.round(e.startTime),v:e.value,src:(e.sources||[]).slice(0,3).map(a=>a.node?.parentElement?.id||a.node?.className?.toString().slice(0,50))});
    }).observe({type:'layout-shift',buffered:true});
    if(!css)return;
    const add=()=>{
      if(!document.head||document.getElementById('ab-contain'))return;
      const e=document.createElement('style');e.id='ab-contain';e.textContent=css;document.head.append(e);
    };
    new MutationObserver(add).observe(document,{childList:true,subtree:true});add();
  },test.css);
  const err=[];
  page.on('pageerror',x=>err.push(String(x).slice(0,180)));
  let fail='';
  try{await page.goto('https://vesta-cosmetics.ir/',{waitUntil:'domcontentloaded',timeout:75000});await new Promise(r=>setTimeout(r,9000));}catch(e){fail=String(e).slice(0,180)}
  const d=await page.evaluate(()=>{
    const c=[...document.querySelectorAll('.owl-carousel.wd-owl')];
    const lp=document.querySelector('.wd-carousel-container.slider-type-post');
    return {
      cls:Math.round((window.__shifts||[]).reduce((a,b)=>a+b.v,0)*10000)/10000,
      shifts:(window.__shifts||[]).filter(x=>x.v>.01).slice(0,4),
      loaded:c.filter(x=>x.classList.contains('owl-loaded')).length,
      total:c.length,
      images:document.querySelectorAll('picture source[type="image/webp"]').length,
      postHeight:lp?Math.round(lp.getBoundingClientRect().height):0,
      css:!!document.getElementById('ab-contain'),
      products:document.querySelectorAll('.product-wrapper').length
    };
  });
  console.log('COLD_CONTROL',test.id,JSON.stringify({...d,error:err.slice(0,3),fail}));
  await browser.close();
 }
})().catch(e=>{console.error(e.stack);process.exit(1)});
