const http=require('http'),fs=require('fs');
const getJson=u=>new Promise((res,rej)=>http.get(u,r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>res(JSON.parse(d)))}).on('error',rej));
(async()=>{
  const pages=(await getJson('http://127.0.0.1:9444/json')).filter(p=>p.type==='page');
  const ws=new WebSocket(pages[0].webSocketDebuggerUrl); await new Promise(r=>ws.onopen=r);
  let id=0; const pend=new Map(); ws.onmessage=m=>{const d=JSON.parse(m.data); if(d.id&&pend.has(d.id)){pend.get(d.id)(d);pend.delete(d.id)}};
  const send=(method,params={})=>new Promise(r=>{const i=++id;pend.set(i,r);ws.send(JSON.stringify({id:i,method,params}))});
  await send('Page.enable'); await send('Page.navigate',{url:'http://127.0.0.1:8099/render.html'}); await new Promise(r=>setTimeout(r,1500));
  const icons=process.argv.slice(2); const size=64;
  for(const ic of icons){
    const r=await send('Runtime.evaluate',{expression:`window.renderAll(${JSON.stringify(ic)},${size})`,returnByValue:true,awaitPromise:true});
    const arr=r.result&&r.result.result&&r.result.result.value;
    if(!arr){console.log(ic,'FAIL',JSON.stringify(r).slice(0,300));continue}
    fs.mkdirSync('/tmp/gi/frames/'+ic,{recursive:true});
    arr.forEach((u,i)=>fs.writeFileSync(`/tmp/gi/frames/${ic}/f${String(i).padStart(3,'0')}.png`,Buffer.from(u.split(',')[1],'base64')));
    console.log(ic,arr.length,'frames');
  }
  ws.close();
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
