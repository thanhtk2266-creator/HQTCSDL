import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import net from 'node:net';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const database=`CruiseWeek1DataApi_${randomBytes(5).toString('hex')}`;
const sqlcmd=process.env.SQLCMD_PATH||'sqlcmd',sqlServer=process.env.SQL_SERVER||'.';
const runSql=(db,statement)=>{
 const result=spawnSync(sqlcmd,['-S',sqlServer,'-d',db,'-E','-C','-I','-b','-l','10','-Q',statement],{encoding:'utf8',windowsHide:true,env:process.env});
 if(result.error||result.status!==0)throw Error(result.error?.message||result.stderr||result.stdout);
 return result.stdout.trim();
};
const dropDatabase=()=>runSql('master',`IF DB_ID(N'${database}') IS NOT NULL BEGIN ALTER DATABASE [${database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${database}]; END;`);
const check=async(name,action)=>{await action();console.log('PASS '+name);};
async function startServer(port){
 const child=spawn(process.execPath,['server.mjs'],{cwd:root,env:{...process.env,SQL_DATABASE:database,PORT:String(port)},windowsHide:true});
 let output='',errors='';
 await new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>{child.kill();reject(Error('Server không khởi động: '+errors));},20000);
  child.stdout.on('data',chunk=>{output+=chunk;if(output.includes(`http://localhost:${port}`)){clearTimeout(timer);resolve();}});
  child.stderr.on('data',chunk=>errors+=chunk);
  child.on('error',reject);
  child.on('exit',code=>{if(code)reject(Error(errors||output));});
 });
 return child;
}
async function call(base,path,body,cookie){
 const response=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{...(body===undefined?{}:{'Content-Type':'application/json'}),...(cookie?{Cookie:cookie}:{})},body:body===undefined?undefined:JSON.stringify(body)});
 return{status:response.status,data:await response.json(),cookie:response.headers.get('set-cookie')?.split(';')[0]};
}
async function login(base,email){
 const result=await call(base,'/api/login',{email,password:'Aurora123!'});
 assert.equal(result.status,200,JSON.stringify(result.data));
 return result.cookie;
}

let server;
try{
 dropDatabase();
 const setup=spawnSync(process.execPath,['scripts/setup.mjs'],{cwd:root,encoding:'utf8',windowsHide:true,env:{...process.env,SQL_DATABASE:database}});
 if(setup.error||setup.status!==0)throw Error(setup.error?.message||setup.stderr||setup.stdout);
 const socket=net.createServer();await new Promise(resolve=>socket.listen(0,'127.0.0.1',resolve));const port=socket.address().port;await new Promise(resolve=>socket.close(resolve));
 server=await startServer(port);const base=`http://127.0.0.1:${port}`;

 await check('API hoạt động trên tàu trả dữ liệu đã seed',async()=>{
  const cookie=await login(base,'checkin@demo.local');
  const response=await call(base,'/api/activity/data',undefined,cookie);
  assert.equal(response.status,200,JSON.stringify(response.data));
  assert.equal(response.data.cruises.length,1);
  assert.equal(response.data.zones.length,3);
  assert.equal(response.data.activities.length,3);
  assert.equal(response.data.policy.length,1);
  assert(response.data.activities.some(activity=>activity.Name==='Yoga đón bình minh'));
 });
 await check('API tour bờ trả dữ liệu đã seed',async()=>{
  const cookie=await login(base,'shore@demo.local');
  const response=await call(base,'/api/shore/data',undefined,cookie);
  assert.equal(response.status,200,JSON.stringify(response.data));
  assert.equal(response.data.cruises.length,1);
  assert.equal(response.data.stops.length,2);
  assert.equal(response.data.providers.length,1);
  assert.equal(response.data.activities.length,2);
  assert(response.data.activities.some(activity=>activity.Name==='Khám phá vịnh Hạ Long'));
 });
}finally{
 if(server){server.kill();await new Promise(resolve=>server.once('exit',resolve));}
 try{dropDatabase();console.log('Database kiểm thử tạm đã được xóa.');}catch(error){console.error('Không xóa được database kiểm thử:',error.message);}
}
