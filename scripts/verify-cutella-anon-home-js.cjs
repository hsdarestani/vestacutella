const puppeteer=require('puppeteer-core');
(async()=>{
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
 const page=await browser.newPage();
 await page.setViewport({width:412,height:915,isMobile:true,deviceScaleFactor:2,hasTouch:true});
 const errors=[];page.on('pageerror',e=>errors.push(String(e).slice(0,200)));
 const r=await page.goto('https://cutellashop.ir/',{waitUntil:'domcontentloaded',timeout:70000});
 await new Promise(x=>setTimeout(x,11000));
 const home=await page.evaluate(()=>{
  const banner=document.querySelector('.cutella-banner-track img,.cutella-banner-slide img');
  const scripts=[...document.querySelectorAll('script[src]')].filter(x=>x.src.includes('/revslider/public/js/')).map(x=>x.src.slice(-125));
  return {
   htmlReady:document.readyState,
   revSliderScripts:scripts,
   bannerLoaded:!!banner&&banner.naturalWidth>0,
   bannerDimension:banner?{w:banner.naturalWidth,h:banner.naturalHeight}:null,
   productCards:document.querySelectorAll('.cutella-product-card').length,
   slideDots:document.querySelectorAll('.cutella-slider-dots button').length,
   loadedImages:[...document.images].filter(x=>x.naturalWidth>0).length,
   htmlBytes:document.documentElement.outerHTML.length,
   title:document.title
  };
 });
 console.log('CUTELLA_GUEST_VERIFY',JSON.stringify({http:r?.status(),home,errors}));
 const good=r?.status()===200&&home.revSliderScripts.length===0&&home.bannerLoaded&&home.productCards>=25&&home.slideDots>=10&&home.loadedImages>=20&&errors.length===0;
 for(const path of ['/shop/','/cart/','/checkout/','/my-account/','/wp-login.php']){
  const p=await page.goto('https://cutellashop.ir'+path,{waitUntil:'domcontentloaded',timeout:45000});
  console.log('CUTELLA_DYNAMIC_ROUTE',JSON.stringify({path,http:p?.status(),finalUrl:page.url()}));
  if(![200,301,302].includes(p?.status()))throw new Error('Dynamic route failed: '+path);
 }
 await browser.close();
 if(!good){console.error('CUTELLA_ANON_HOME_FAILED_VERIFY');process.exit(2);}
 console.log('CUTELLA_ANON_HOME_JS_VERIFIED');
})().catch(e=>{console.error(e.stack);process.exit(1)});
