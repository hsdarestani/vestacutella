const puppeteer = require('puppeteer-core');
const CSS = '#nomarg{min-height:405px!important}';
const variants = [
  {name:'baseline1',css:''},
  {name:'reserve405a',css:CSS},
  {name:'baseline2',css:''},
  {name:'reserve405b',css:CSS},
];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function measure(v){
  const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',
    args:['--no-sandbox','--disable-dev-shm-usage','--disk-cache-size=0']});
  const page=await browser.newPage();
  await page.setViewport({width:412,height:915,isMobile:true,hasTouch:true,deviceScaleFactor:2});
  await page.setCacheEnabled(false);
  const sess=await page.target().createCDPSession();
  await sess.send('Network.enable');
  await sess.send('Network.setCacheDisabled',{cacheDisabled:true});
  await sess.send('Emulation.setCPUThrottlingRate',{rate:4});
  const errors=[];
  page.on('pageerror',e=>errors.push(String(e).slice(0,160)));
  await page.evaluateOnNewDocument(css=>{
    window.__measure={lcp:0,cls:0,shifts:[],longTaskMs:0};
    new PerformanceObserver(list=>{for(const e of list.getEntries())window.__measure.lcp=Math.round(e.startTime)}).observe({type:'largest-contentful-paint',buffered:true});
    new PerformanceObserver(list=>{for(const e of list.getEntries()){if(!e.hadRecentInput){window.__measure.cls+=e.value;window.__measure.shifts.push({t:Math.round(e.startTime),v:+e.value.toFixed(4),nodes:e.sources?.slice(0,2).map(x=>x.node?.id||x.node?.className?.toString().slice(0,45))})}}}).observe({type:'layout-shift',buffered:true});
    new PerformanceObserver(list=>{for(const e of list.getEntries())window.__measure.longTaskMs+=e.duration}).observe({type:'longtask',buffered:true});
    if(css){
      const inject=()=>{if(!document.head||document.getElementById('vc-nomarg-experiment'))return;
        const el=document.createElement('style');el.id='vc-nomarg-experiment';el.textContent=css;document.head.appendChild(el)};
      const observer=new MutationObserver(inject);observer.observe(document,{subtree:true,childList:true});inject();
    }
  },v.css);
  const response=await page.goto('https://vesta-cosmetics.ir/',{waitUntil:'domcontentloaded',timeout:70000});
  await sleep(11000);
  const result=await page.evaluate(()=>{
    const rows=[...document.querySelectorAll('#nomarg')];
    const cs=[...document.querySelectorAll('.owl-carousel.wd-owl')];
    const b=document.querySelector('.vc-oct-banner-mobile-webp img');
    return {
      data:window.__measure,
      rows:rows.map(e=>({height:Math.round(e.getBoundingClientRect().height),minHeight:getComputedStyle(e).minHeight})),
      carousels:cs.length,loaded:cs.filter(e=>e.classList.contains('owl-loaded')).length,
      products:document.querySelectorAll('.product-wrapper').length,
      bodyHeight:document.body.scrollHeight,
      bannerLoaded:!!b?.naturalWidth,
      picture:!!document.querySelector('.vc-oct-banner-mobile-webp source'),
    };
  });
  result.data.cls=+result.data.cls.toFixed(4);result.data.longTaskMs=Math.round(result.data.longTaskMs);
  console.log('NOMARG_AB',JSON.stringify({variant:v.name,status:response?.status(),...result,errors}));
  await browser.close();
}
(async()=>{for(const v of variants)await measure(v)})().catch(e=>{console.error('NOMARG_LAB_FAILED',e.stack);process.exit(1)});
