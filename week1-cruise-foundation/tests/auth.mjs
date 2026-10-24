import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import net from 'node:net';
import {fileURLToPath} from 'node:url';
import {query,jsonQuery,hashPassword,literal,verifyPassword} from '../src/db.mjs';

let checks=0;
const check=async(name,fn)=>{await fn();checks++;console.log('PASS '+name);};
async function start(seconds){
 const socket=net.createServer();await new Promise(resolve=>socket.listen(0,'127.0.0.1',resolve));const port=socket.address().port;await new Promise(resolve=>socket.close(resolve));
 const child=spawn(process.execPath,['server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),env:{...process.env,PORT:String(port),...(seconds?{SESSION_TTL_SECONDS:String(seconds)}:{})},windowsHide:true});
 await new Promise((resolve,reject)=>{let out='',errors='';const timer=setTimeout(()=>{child.kill();reject(Error('Server không khởi động: '+errors));},20000);child.stderr.on('data',v=>errors+=v);child.stdout.on('data',v=>{out+=v;if(out.includes('http://localhost:')){clearTimeout(timer);resolve();}});child.on('error',reject);child.on('exit',code=>{clearTimeout(timer);if(code)reject(Error(errors));});});
 return {child,base:'http://127.0.0.1:'+port};
}
async function call(base,url,body,cookie,headers={}){
 const r=await fetch(base+url,{method:body===undefined?'GET':'POST',headers:{...(body===undefined?{}:{'Content-Type':'application/json'}),...(cookie?{Cookie:cookie}:{}),...headers},body:body===undefined?undefined:JSON.stringify(body)});
 const data=await r.json();return {status:r.status,data,cookie:r.headers.get('set-cookie')?.split(';')[0],setCookie:r.headers.get('set-cookie')};
}
const server=await start();let fixtureId;
try{
 const base=server.base;
 await check('Scrypt đúng, sai mật khẩu và salt riêng',()=>{const a=hashPassword('Aurora123!'),b=hashPassword('Aurora123!');assert.notEqual(a,b);assert(verifyPassword('Aurora123!',a));assert(!verifyPassword('wrong',a));assert(!verifyPassword('Aurora123!','invalid'));});
 await check('Mật khẩu trong DB là hash',async()=>{const users=await jsonQuery('SELECT PasswordHash FROM Users FOR JSON PATH');assert(users.length>=27);assert(users.every(u=>/^[a-f0-9]{32}:[a-f0-9]{128}$/.test(u.PasswordHash)));assert(new Set(users.map(u=>u.PasswordHash)).size===users.length);});
 await check('API chưa đăng nhập trả 401',async()=>assert.equal((await call(base,'/api/state')).status,401));
 await check('Sai mật khẩu bị chặn',async()=>assert.equal((await call(base,'/api/login',{email:'guest1@demo.local',password:'wrong'})).status,401));
 await check('Đầu vào thiếu bị chặn',async()=>assert.equal((await call(base,'/api/login',{})).status,400));
 await check('Email SQL injection không đăng nhập được',async()=>assert.equal((await call(base,'/api/login',{email:"' OR 1=1 --",password:'Aurora123!'})).status,401));
 await check('Nguồn POST khác bị chặn',async()=>assert.equal((await call(base,'/api/login',{email:'admin@demo.local',password:'Aurora123!'},undefined,{Origin:'https://untrusted.example'})).status,403));
 let guestCookie,adminCookie;
 await check('Cookie HttpOnly, SameSite và không trả hash',async()=>{const r=await call(base,'/api/login',{email:'guest1@demo.local',password:'Aurora123!',role:'ADMIN'});assert.equal(r.status,200);assert(r.setCookie.includes('HttpOnly'));assert(r.setCookie.includes('SameSite=Strict'));guestCookie=r.cookie;const me=await call(base,'/api/me',undefined,guestCookie);assert.equal(me.data.Name,'Nguyễn Minh Anh');assert.deepEqual(me.data.roles,['PASSENGER']);assert(!JSON.stringify(me.data).includes('PasswordHash'));});
 const me=(await call(base,'/api/me',undefined,guestCookie)).data;
 const stateResponse=await call(base,'/api/state',undefined,guestCookie);
 assert.equal(stateResponse.status,200,JSON.stringify(stateResponse.data));
 const mine=stateResponse.data;
 await check('Khách chỉ thấy booking và tài khoản của mình',()=>{assert(mine.bookings.length>0);assert(mine.bookings.every(b=>b.UserId===me.UserId));assert(mine.accounts.every(a=>mine.bookings.some(b=>b.BookingId===a.BookingId)));assert(mine.transactions.every(t=>mine.accounts.some(a=>a.AccountId===t.AccountId)));});
 await check('Xem trực tiếp booking của mình',async()=>assert.equal((await call(base,'/api/bookings/'+mine.bookings[0].BookingId,undefined,guestCookie)).status,200));
 const other=(await jsonQuery(`SELECT TOP(1) b.BookingId FROM Bookings b JOIN Passengers p ON p.PassengerId=b.PassengerId WHERE p.UserId<>${me.UserId} FOR JSON PATH`))[0];
 await check('Đổi URL xem booking khách khác bị chặn',async()=>assert.equal((await call(base,'/api/bookings/'+other.BookingId,undefined,guestCookie)).status,403));
 await check('Khách không vào danh sách người dùng admin',async()=>assert.equal((await call(base,'/api/admin/users',undefined,guestCookie)).status,403));
 await check('Giả cookie bị chặn',async()=>assert.equal((await call(base,'/api/me',undefined,'aurora_week1='+'a'.repeat(64))).status,401));
 const accounts=[['guest1','PASSENGER'],['itinerary','ITINERARY'],['checkin','ACTIVITY'],['shore','SHORE'],['pos','POS'],['finance','FINANCE'],['operations','OPERATIONS'],['admin','ADMIN']];
 for(const [name,role] of accounts)await check('Vai trò '+role+' và chặn bộ phận khác',async()=>{
  const r=await call(base,'/api/login',{email:name+'@demo.local',password:'Aurora123!'});assert.equal(r.status,200);
  assert.deepEqual((await call(base,'/api/me',undefined,r.cookie)).data.roles,[role]);
  assert.equal((await call(base,'/api/departments/'+role,undefined,r.cookie)).status,200);
  if(role==='ADMIN'){adminCookie=r.cookie;assert.equal((await call(base,'/api/admin/users',undefined,r.cookie)).status,200);}
  else assert.equal((await call(base,'/api/departments/ADMIN',undefined,r.cookie)).status,403);
  const stateResponse=await call(base,'/api/state',undefined,r.cookie);
  assert.equal(stateResponse.status,200,`Không tải được dữ liệu vai trò ${role}: ${JSON.stringify(stateResponse.data)}`);
  const state=stateResponse.data;
  for(const key of ['cruises','activities','bookings','accounts','checkinDevices','checkinRegistrations'])assert(Array.isArray(state[key]),`/api/state thiếu mảng ${key} cho ${role}.`);
  if(['POS','ITINERARY'].includes(role))assert.equal(state.bookings.length,0);
  if(!['PASSENGER','FINANCE','ADMIN'].includes(role))assert.equal(state.accounts.length,0);
  if(role==='ACTIVITY'){assert(state.activities.every(a=>a.Kind==='ONBOARD'));assert(state.checkinRegistrations.every(r=>r.Kind==='ONBOARD'));}
  if(role==='SHORE'){assert(state.activities.every(a=>a.Kind==='SHORE'));assert(state.checkinRegistrations.every(r=>r.Kind==='SHORE'));}
 });
 await check('Danh sách admin không có mật khẩu',async()=>assert(!JSON.stringify((await call(base,'/api/admin/users',undefined,adminCookie)).data).includes('PasswordHash')));
 await check('Logout vô hiệu phiên cũ',async()=>{assert.equal((await call(base,'/api/logout',{},guestCookie)).status,200);assert.equal((await call(base,'/api/me',undefined,guestCookie)).status,401);});
 const email='auth-test-'+crypto.randomUUID()+'@test.local';
 const hash=hashPassword('AuthTest123!');
 await query(`INSERT Users(Name,Email,PasswordHash) VALUES(N'Test auth',${literal(email)},${literal(hash)});`);
 const inserted=await jsonQuery(`SELECT UserId FROM Users WHERE Email=${literal(email)} FOR JSON PATH`);fixtureId=inserted[0]?.UserId;
 if(!fixtureId)throw Error('Không tạo được fixture');
 await query(`INSERT UserRoles(UserId,RoleId) SELECT ${fixtureId},RoleId FROM Roles WHERE Code='ADMIN';`);
 const fixtureLogin=await call(base,'/api/login',{email,password:'AuthTest123!'});assert.equal(fixtureLogin.status,200);
 await check('Khóa tài khoản chặn phiên đang đăng nhập',async()=>{await query(`UPDATE Users SET Active=0 WHERE UserId=${fixtureId};`);assert.equal((await call(base,'/api/me',undefined,fixtureLogin.cookie)).status,401);assert.equal((await call(base,'/api/login',{email,password:'AuthTest123!'})).status,401);});
 await check('Tài khoản chưa có quyền không được đăng nhập',async()=>{await query(`UPDATE Users SET Active=1 WHERE UserId=${fixtureId}; DELETE UserRoles WHERE UserId=${fixtureId};`);assert.equal((await call(base,'/api/login',{email,password:'AuthTest123!'})).status,403);});
 const short=await start(1);
 try{await check('Phiên hết hạn bị chặn',async()=>{const r=await call(short.base,'/api/login',{email:'guest1@demo.local',password:'Aurora123!'});assert.equal(r.status,200);await new Promise(resolve=>setTimeout(resolve,1200));assert.equal((await call(short.base,'/api/me',undefined,r.cookie)).status,401);});}finally{short.child.kill();}
 console.log(JSON.stringify({tests:checks,failures:0}));
}finally{
 server.child.kill();
 if(fixtureId)await query(`DELETE UserRoles WHERE UserId=${fixtureId}; DELETE Users WHERE UserId=${fixtureId}; DELETE AuditLog WHERE Entity='UserRole' AND EntityId=${fixtureId};`);
}
