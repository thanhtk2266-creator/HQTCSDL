import {spawnSync} from 'node:child_process';
import {readFile,mkdir,writeFile,unlink} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {query,jsonQuery,hashPassword,database,literal} from '../src/db.mjs';

// Bản tuần 1 không được dùng database của bản đầy đủ.
if(database.toLowerCase()==='cruisecoursework')throw Error('Hãy dùng CruiseWeek1 hoặc database thử nghiệm riêng, không dùng CruiseCoursework.');
const base=new URL('../',import.meta.url);
const exists=await query("SELECT CASE WHEN OBJECT_ID('dbo.Ships') IS NULL THEN 0 ELSE 1 END;").catch(()=> '0');
const tempDir=new URL('.tmp/',base);await mkdir(tempDir,{recursive:true});
async function run(file){
 const source=(await readFile(new URL('database/'+file,base),'utf8')).replaceAll('CruiseWeek1',database);
 const temp=new URL('setup-'+file,tempDir);await writeFile(temp,'\uFEFF'+source,'utf8');
 try{
  const r=spawnSync(process.env.SQLCMD_PATH||'sqlcmd',['-S',process.env.SQL_SERVER||'.','-E','-C','-I','-b','-f','65001','-i',fileURLToPath(temp)],{encoding:'utf8',windowsHide:true});
  if(r.error||r.status!==0)throw Error(r.error?.message||r.stderr||r.stdout);
  console.log('OK '+file);
 }finally{await unlink(temp);}
}
if(exists.trim()!=='1'){
 await run('01-schema.sql');
 await run('03-seed.sql');
}else{
 const count=Number(await query('SELECT COUNT(*) FROM Users;'));
 if(count===0)throw Error('Database đã có schema nhưng chưa có seed. Kiểm tra dữ liệu và chạy 03-seed.sql trên database mới.');
 console.log('Giữ nguyên schema và dữ liệu đã có.');
}
await run('04-auth.sql');
await run('05-itinerary.sql');
await run('06-registration.sql');
await run('07-cancellation.sql');
await run('08-admin.sql');
await run('09-integrity.sql');
await run('10-pos-sync.sql');
await run('11-pos-receipts.sql');
await run('12-passenger-finance.sql');
await run('13-onboard-activities.sql');
await run('14-shore-excursions.sql');
await run('14-checkin.sql');
await run('15-feedback.sql');
await run('16-finance-notifications.sql');
await run('17-recipient-notifications.sql');
await run('18-shore-reminders.sql');
const pending=await jsonQuery("SELECT UserId FROM Users WHERE PasswordHash IS NULL AND Email LIKE '%@demo.local' FOR JSON PATH");
if(pending.length)await query(pending.map(u=>`UPDATE Users SET PasswordHash=${literal(hashPassword('Aurora123!'))} WHERE UserId=${u.UserId} AND PasswordHash IS NULL;`).join('\n'));
console.log(`Database ${database} sẵn sàng. Mật khẩu demo: Aurora123!`);
console.log('npm start → http://localhost:'+(process.env.PORT||3001));

