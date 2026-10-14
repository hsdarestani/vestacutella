const puppeteer=require('puppeteer-core');
const hosts=['vesta-cosmetics.ir','cutellashop.ir'];
const paths=['/','/shop/','/cart/','/checkout/','/my-account/','/wp-login.php'];
(async()=>{
 const browser=await puppeteer.launch({headless:true,executablePath:'/usr/bin/google-chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
 let critical=0;
 for(const host of hosts){
  const context=await browser.createBrowserContext();
  const page=await context.newPage();
  await page.setViewport({width:412,height:915,isMobile:true,deviceScaleFactor:2,hasTouch:true});
  const errors=[];
  page.on('pageerror',e=>errors.push(String(e).slice(0,160)));
  for(const path of paths){
   let code=-1;
   let result={host,path};
   try{
    const response=await page.goto('https://'+host+path,{waitUntil:'domcontentloaded',timeout:45000});
    code=response?.status()||0;
    await new Promise(r=>setTimeout(r,600));
    result={...result,http:code,finalUrl:page.url(),title:await page.title(),diagnostic:await page.evaluate(()=>({
     products:document.querySelectorAll('a[href*="/product/"]').length,
     addToCartButtons:document.querySelectorAll('button.single_add_to_cart_button,[name="add-to-cart"],a.add_to_cart_button').length,
     hasWooCheckout:!!document.querySelector('form.checkout,#order_review,.woocommerce-checkout,.wc-block-checkout'),
     hasLoginFields:!!document.querySelector('form.login,form#loginform,input#user_login,input[name="username"]'),
     imagesLoaded:[...document.images].filter(i=>i.complete && i.naturalWidth>0).length,
     htmlBytes:document.documentElement.outerHTML.length
    }))};
   }catch(e){result.error=String(e).slice(0,200);critical++;}
   if(code>=500||code===0){critical++;}
   console.log('STORE_SMOKE',JSON.stringify(result));
  }
  try{
   const shop=await page.goto('https://'+host+'/shop/',{waitUntil:'domcontentloaded',timeout:45000});
   const url=await page.evaluate(()=>[...document.querySelectorAll('a[href*="/product/"]')].map(a=>a.href).find(x=>x.startsWith(location.origin+'/product/')));
   if(url){
    const p=await page.goto(url,{waitUntil:'domcontentloaded',timeout:45000});
    const details=await page.evaluate(()=>({hasAddToCart:!!document.querySelector('button.single_add_to_cart_button,[name="add-to-cart"],a.add_to_cart_button'),hasPrice:!!document.querySelector('.price,.woocommerce-Price-amount'),hasProductTitle:!!document.querySelector('h1.product_title,.product_title')})); 
    console.log('PRODUCT_SMOKE',JSON.stringify({host,url,http:p?.status(),...details}));
    if((p?.status()||0)>=500)critical++;
   }else console.log('PRODUCT_SMOKE',JSON.stringify({host,productLinkMissing:true}));
  }catch(e){console.log('PRODUCT_SMOKE',JSON.stringify({host,error:String(e).slice(0,250)}));critical++;}
  console.log('PAGE_JS_ERRORS',host,JSON.stringify([...new Set(errors)].slice(0,10)));
  await context.close();
 }
 const p=await browser.newPage();
 const app=await p.goto('https://app.vesta-cosmetics.ir/',{waitUntil:'domcontentloaded',timeout:35000}).catch(e=>null);
 console.log('APP_SMOKE',JSON.stringify({http:app?.status()||0,url:p.url()}));
 if((app?.status()||0)>=500||!app)critical++;
 await browser.close();
 console.log('SMOKE_COMPLETE critical='+critical);
 if(critical)process.exit(1);
})().catch(e=>{console.error('SMOKE_CRASH',e.stack);process.exit(1)});
