// Nền tảng đăng nhập, Tổng quan và quản lý chuyến/lịch trình trên SQL Server.
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {randomBytes} from 'node:crypto';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {query,jsonQuery,literal,verifyPassword,hashPassword} from './src/db.mjs';
import QRCode from 'qrcode';
const root=fileURLToPath(new URL('./public/',import.meta.url));
const port=Number(process.env.PORT||3001),cookieName='aurora_week1';
const sessions=new Map(),attempts=new Map(),ttl=Number(process.env.SESSION_TTL_SECONDS||28800)*1000;
if(!Number.isInteger(port)||port<1||port>65535||!Number.isFinite(ttl)||ttl<1000)throw Error('PORT hoặc SESSION_TTL_SECONDS không hợp lệ.');
const roles={PASSENGER:'Hành khách',ITINERARY:'Điều phối hành trình',ACTIVITY:'Quản lý hoạt động',SHORE:'Quản lý tour bờ',POS:'Nhân viên POS',FINANCE:'Tài chính – Lễ tân',OPERATIONS:'Quản lý vận hành',ADMIN:'Quản trị hệ thống'};
const fail=(status,message)=>{throw Object.assign(Error(message),{status});};
const id=v=>{const n=Number(v);if(!Number.isSafeInteger(n)||n<1)fail(400,'ID không hợp lệ.');return n;};
const maybeId=v=>v===undefined||v===null||v===''?0:(Number.isSafeInteger(Number(v))&&Number(v)>=0?Number(v):fail(400,'ID không hợp lệ.'));
const whole=(v,min,max,label='Số')=>{const n=Number(v);if(!Number.isSafeInteger(n)||n<min||n>max)fail(400,`${label} không hợp lệ.`);return n;};
const amount=(v,label='Số tiền')=>{const n=Number(v);if(!Number.isFinite(n)||n<0||n>1e12)fail(400,`${label} không hợp lệ.`);return n;};
const text=(v,max)=>{if(typeof v!=='string'||!v.trim()||v.length>max)fail(400,'Dữ liệu không hợp lệ.');return v;};
function dateOnly(v){const s=text(v,10).trim();if(!/^\d{4}-\d{2}-\d{2}$/.test(s))fail(400,'Ngày không hợp lệ.');const d=new Date(`${s}T00:00:00Z`);if(Number.isNaN(d.getTime())||d.toISOString().slice(0,10)!==s)fail(400,'Ngày không hợp lệ.');return s;}
function dateTime(v){const s=text(v,19).trim(),m=/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(s);if(!m)fail(400,'Giờ cảng không hợp lệ.');dateOnly(m[1]);if(Number(m[2])>23||Number(m[3])>59||Number(m[4]||0)>59)fail(400,'Giờ cảng không hợp lệ.');return `${m[1]}T${m[2]}:${m[3]}:${m[4]||'00'}`;}
async function requestJson(req){let raw='';for await(const chunk of req){raw+=chunk;if(raw.length>20000)fail(413,'Yêu cầu quá lớn.');}let body;try{body=JSON.parse(raw||'{}');}catch{fail(400,'JSON không hợp lệ.');}if(!body||typeof body!=='object'||Array.isArray(body))fail(400,'Dữ liệu gửi lên không hợp lệ.');return body;}
async function runProcedure(sql){try{return await query(sql);}catch(e){const message=String(e.message||'');const match=/Msg \d+, Level 16,[\s\S]*?Line \d+\s*\r?\n([^\r\n]+)/.exec(message);if(match)fail(422,match[1].trim());throw e;}}
const sessionId=req=>new RegExp(`(?:^|;\\s*)${cookieName}=([a-f0-9]{64})(?:;|$)`).exec(req.headers.cookie||'')?.[1];
function requireRoles(u,...allowed){if(!u.roles.includes('ADMIN')&&!allowed.some(r=>u.roles.includes(r)))fail(403,'Không có quyền truy cập chức năng này.');}
async function getUser(req){
 const sid=sessionId(req),s=sessions.get(sid);if(!s||s.expires<=Date.now()){sessions.delete(sid);return null;}
 const u=(await jsonQuery(`SELECT u.UserId,u.Name,u.Email,JSON_QUERY((SELECT r.Code FROM UserRoles ur JOIN Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=u.UserId FOR JSON PATH)) AS roles FROM Users u WHERE u.UserId=${s.userId} AND u.Active=1 FOR JSON PATH`))[0];
 if(!u){sessions.delete(sid);return null;}u.roles=u.roles.map(r=>r.Code).filter(r=>Object.hasOwn(roles,r));if(!u.roles.length)fail(403,'Tài khoản chưa được cấp vai trò.');return u;
}
function bookingQuery(u,bid){
 const guest=u.roles.includes('PASSENGER')&&!u.roles.includes('ADMIN');
 return `SELECT b.BookingId,b.CruiseId,b.CabinId,b.PackageId,p.UserId,u.Name,c.Name AS Cruise,cb.Number AS Cabin,pk.Name AS Package FROM Bookings b JOIN Passengers p ON p.PassengerId=b.PassengerId JOIN Users u ON u.UserId=p.UserId JOIN Cruises c ON c.CruiseId=b.CruiseId JOIN Cabins cb ON cb.CabinId=b.CabinId JOIN Packages pk ON pk.PackageId=b.PackageId WHERE ${guest?`p.UserId=${u.UserId}`:'1=1'}${bid===undefined?'':` AND b.BookingId=${id(bid)}`}`;
}
function passengerFinanceQuery(u){
 const owner=`JOIN dbo.Bookings b ON b.BookingId=ac.BookingId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId AND p.UserId=${u.UserId}`;
 return `SELECT
  JSON_QUERY((SELECT ac.AccountId,ac.BookingId,c.Name AS Cruise,cb.Number AS Cabin,pk.Name AS Package,ac.Status,
   CONVERT(decimal(18,2),COALESCE(SUM(CASE t.Status WHEN 'POSTED' THEN t.Amount WHEN 'REFUNDED' THEN t.Amount-COALESCE(t.RefundAmount,0) ELSE 0 END),0)) AS CurrentCharges,
   CONVERT(decimal(18,2),CASE WHEN ac.Status='OPEN' THEN COALESCE(SUM(CASE t.Status WHEN 'POSTED' THEN t.Amount WHEN 'REFUNDED' THEN t.Amount-COALESCE(t.RefundAmount,0) ELSE 0 END),0) ELSE 0 END) AS UnpaidAmount,
   CONVERT(decimal(18,2),COALESCE(SUM(CASE WHEN t.Status='REFUNDED' THEN COALESCE(t.RefundAmount,0) ELSE 0 END),0)) AS RefundedAmount,
   inv.InvoiceId,inv.Total AS InvoiceTotal,inv.CreatedAt AS InvoicedAt,pay.PaymentId,pay.Amount AS PaidAmount,pay.Method AS PaymentMethod,pay.CreatedAt AS PaidAt
   FROM dbo.Accounts ac ${owner}
   JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId JOIN dbo.Cabins cb ON cb.CabinId=b.CabinId JOIN dbo.Packages pk ON pk.PackageId=b.PackageId
   LEFT JOIN dbo.Transactions t ON t.AccountId=ac.AccountId
   LEFT JOIN dbo.Invoices inv ON inv.AccountId=ac.AccountId LEFT JOIN dbo.Payments pay ON pay.InvoiceId=inv.InvoiceId
   GROUP BY ac.AccountId,ac.BookingId,c.Name,cb.Number,pk.Name,ac.Status,inv.InvoiceId,inv.Total,inv.CreatedAt,pay.PaymentId,pay.Amount,pay.Method,pay.CreatedAt
   ORDER BY ac.AccountId FOR JSON PATH)) AS accounts,
  JSON_QUERY((SELECT t.TransactionId,t.AccountId,t.RegistrationId,t.ServiceId,t.DeviceId,t.Quantity,t.Amount,t.Status,t.RefundAmount,t.RefundedAt,t.CreatedAt,
   COALESCE(s.Name,a.Name,N'Dịch vụ') AS Description,CONVERT(decimal(18,2),CASE t.Status WHEN 'POSTED' THEN t.Amount WHEN 'REFUNDED' THEN t.Amount-COALESCE(t.RefundAmount,0) ELSE 0 END) AS NetAmount,
   JSON_QUERY((SELECT d.DisputeId,d.Reason,d.Status,d.SubmittedAt,d.ResolvedAt,d.Resolution FROM dbo.Disputes d WHERE d.TransactionId=t.TransactionId ORDER BY d.SubmittedAt DESC FOR JSON PATH)) AS disputes
   FROM dbo.Transactions t JOIN dbo.Accounts ac ON ac.AccountId=t.AccountId ${owner}
   LEFT JOIN dbo.Services s ON s.ServiceId=t.ServiceId LEFT JOIN dbo.Registrations r ON r.RegistrationId=t.RegistrationId LEFT JOIN dbo.Activities a ON a.ActivityId=r.ActivityId
   ORDER BY t.CreatedAt DESC,t.TransactionId DESC FOR JSON PATH)) AS transactions,
  JSON_QUERY((SELECT inv.InvoiceId,inv.AccountId,ac.BookingId,c.Name AS Cruise,cb.Number AS Cabin,inv.Total,inv.CreatedAt,
   pay.PaymentId,pay.Amount AS PaidAmount,pay.Method,pay.CreatedAt AS PaidAt
   FROM dbo.Invoices inv JOIN dbo.Accounts ac ON ac.AccountId=inv.AccountId ${owner}
   JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId JOIN dbo.Cabins cb ON cb.CabinId=b.CabinId
   LEFT JOIN dbo.Payments pay ON pay.InvoiceId=inv.InvoiceId ORDER BY inv.CreatedAt DESC FOR JSON PATH)) AS invoices
  FOR JSON PATH,WITHOUT_ARRAY_WRAPPER`;
}
function staffFinanceQuery(){
 return `SELECT
  JSON_QUERY((SELECT ac.AccountId,ac.BookingId,ac.Status,b.CruiseId,c.Name AS Cruise,u.Name AS Passenger,
   cb.Number AS Cabin,pk.Name AS Package,dbo.fn_AccountBalance(ac.AccountId) AS Balance,
   inv.InvoiceId,inv.Total AS InvoiceTotal,inv.CreatedAt AS InvoiceCreatedAt,
   pay.PaymentId,pay.Amount AS PaymentAmount,pay.Method AS PaymentMethod,pay.CreatedAt AS PaymentCreatedAt
   FROM dbo.Accounts ac JOIN dbo.Bookings b ON b.BookingId=ac.BookingId
   JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
   JOIN dbo.Users u ON u.UserId=p.UserId JOIN dbo.Cabins cb ON cb.CabinId=b.CabinId
   JOIN dbo.Packages pk ON pk.PackageId=b.PackageId
   LEFT JOIN dbo.Invoices inv ON inv.AccountId=ac.AccountId
   LEFT JOIN dbo.Payments pay ON pay.InvoiceId=inv.InvoiceId ORDER BY ac.AccountId FOR JSON PATH)) AS accounts,
  JSON_QUERY((SELECT t.TransactionId,t.AccountId,ac.BookingId,b.CruiseId,c.Name AS Cruise,u.Name AS Passenger,
   cb.Number AS Cabin,t.ServiceId,t.RegistrationId,t.ClientId,t.Quantity,t.Amount,t.RefundAmount,t.RefundedAt,
   t.Status,t.ReconciledAt,t.ReconciledBy,staff.Name AS ReconciledByName,t.CreatedAt,
   COALESCE(s.Name,a.Name,N'Dịch vụ') AS Description
   FROM dbo.Transactions t JOIN dbo.Accounts ac ON ac.AccountId=t.AccountId
   JOIN dbo.Bookings b ON b.BookingId=ac.BookingId JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId
   JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId JOIN dbo.Users u ON u.UserId=p.UserId
   JOIN dbo.Cabins cb ON cb.CabinId=b.CabinId LEFT JOIN dbo.Users staff ON staff.UserId=t.ReconciledBy
   LEFT JOIN dbo.Services s ON s.ServiceId=t.ServiceId LEFT JOIN dbo.Registrations r ON r.RegistrationId=t.RegistrationId
   LEFT JOIN dbo.Activities a ON a.ActivityId=r.ActivityId ORDER BY t.CreatedAt DESC,t.TransactionId DESC FOR JSON PATH)) AS transactions,
  JSON_QUERY((SELECT d.DisputeId,d.TransactionId,d.Reason,d.Status,d.SubmittedAt,d.SubmittedBy,d.ResolvedAt,
   d.ResolvedBy,d.Resolution,t.AccountId,ac.BookingId,b.CruiseId,c.Name AS Cruise,u.Name AS Passenger,
   cb.Number AS Cabin,t.Amount,COALESCE(s.Name,a.Name,N'Dịch vụ') AS Description
   FROM dbo.Disputes d JOIN dbo.Transactions t ON t.TransactionId=d.TransactionId
   JOIN dbo.Accounts ac ON ac.AccountId=t.AccountId JOIN dbo.Bookings b ON b.BookingId=ac.BookingId
   JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
   JOIN dbo.Users u ON u.UserId=p.UserId JOIN dbo.Cabins cb ON cb.CabinId=b.CabinId
   LEFT JOIN dbo.Services s ON s.ServiceId=t.ServiceId LEFT JOIN dbo.Registrations r ON r.RegistrationId=t.RegistrationId
   LEFT JOIN dbo.Activities a ON a.ActivityId=r.ActivityId ORDER BY d.SubmittedAt DESC,d.DisputeId DESC FOR JSON PATH)) AS disputes,
  JSON_QUERY((SELECT i.InvoiceId,i.AccountId,i.Total,i.CreatedAt,b.BookingId,c.Name AS Cruise,
   u.Name AS Passenger,cb.Number AS Cabin,pay.PaymentId,pay.Amount AS PaymentAmount,pay.Method AS PaymentMethod,
   pay.CreatedAt AS PaymentCreatedAt FROM dbo.Invoices i JOIN dbo.Accounts ac ON ac.AccountId=i.AccountId
   JOIN dbo.Bookings b ON b.BookingId=ac.BookingId JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId
   JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId JOIN dbo.Users u ON u.UserId=p.UserId
   JOIN dbo.Cabins cb ON cb.CabinId=b.CabinId LEFT JOIN dbo.Payments pay ON pay.InvoiceId=i.InvoiceId
   ORDER BY i.CreatedAt DESC,i.InvoiceId DESC FOR JSON PATH)) AS invoices
  FOR JSON PATH,WITHOUT_ARRAY_WRAPPER`;
}
async function state(u){
 const guest=u.roles.includes('PASSENGER')&&!u.roles.includes('ADMIN');
 const bs=guest?`SELECT b.BookingId FROM Bookings b JOIN Passengers p ON p.PassengerId=b.PassengerId WHERE p.UserId=${u.UserId}`:'SELECT BookingId FROM Bookings';
 const cs=guest?`SELECT CruiseId FROM Bookings WHERE BookingId IN(${bs})`:'SELECT CruiseId FROM Cruises';
 const guests=u.roles.some(r=>['PASSENGER','ACTIVITY','SHORE','FINANCE','OPERATIONS','ADMIN'].includes(r));
 const money=u.roles.some(r=>['PASSENGER','FINANCE','ADMIN'].includes(r));
 const itineraryAccess=u.roles.some(r=>['ITINERARY','ADMIN'].includes(r));
 const kind=u.roles.includes('ADMIN')?'':u.roles.includes('ACTIVITY')&&!u.roles.includes('SHORE')?" AND a.Kind='ONBOARD'":u.roles.includes('SHORE')&&!u.roles.includes('ACTIVITY')?" AND a.Kind='SHORE'":'';
 const registrationStats=guest
  ?`SELECT r.RegistrationId,a.ActivityId,a.CruiseId,r.BookingId,r.Status,r.PriceAtRegistration,r.CreatedAt,
    r.CancelledAt,r.CancelledBy,r.CancelReason,r.RefundAmount,DATEADD(hour,-pol.CancelHours,a.StartsAt) AS CancelDeadline,
    pol.RefundPercent,CAST(CASE WHEN ci.RegistrationId IS NULL THEN 0 ELSE 1 END AS bit) AS HasCheckedIn,
    CAST(CASE WHEN r.Status IN('CONFIRMED','WAITLIST') AND ci.RegistrationId IS NULL AND SYSDATETIME()<=DATEADD(hour,-pol.CancelHours,a.StartsAt) AND ac.Status='OPEN' THEN 1 ELSE 0 END AS bit) AS CanCancel,
    CASE WHEN r.Status='CONFIRMED' THEN 1 ELSE 0 END AS Confirmed,CASE WHEN r.Status='WAITLIST' THEN 1 ELSE 0 END AS Waitlist,
    CASE WHEN r.Status='WAITLIST' THEN (SELECT COUNT(*) FROM Registrations w WHERE w.ActivityId=r.ActivityId AND w.Status='WAITLIST' AND (w.CreatedAt<r.CreatedAt OR (w.CreatedAt=r.CreatedAt AND w.RegistrationId<=r.RegistrationId))) END AS WaitlistPosition
    FROM Activities a JOIN Registrations r ON r.ActivityId=a.ActivityId JOIN Bookings b ON b.BookingId=r.BookingId
    JOIN Passengers p ON p.PassengerId=b.PassengerId JOIN Accounts ac ON ac.BookingId=b.BookingId
    CROSS JOIN Policy pol LEFT JOIN CheckIns ci ON ci.RegistrationId=r.RegistrationId
    WHERE a.CruiseId IN(${cs}) AND p.UserId=${u.UserId} AND pol.PolicyId=1${kind}`
  :`SELECT a.ActivityId,a.CruiseId,SUM(CASE WHEN r.Status='CONFIRMED' THEN 1 ELSE 0 END) AS Confirmed,SUM(CASE WHEN r.Status='WAITLIST' THEN 1 ELSE 0 END) AS Waitlist FROM Activities a LEFT JOIN Registrations r ON r.ActivityId=a.ActivityId WHERE a.CruiseId IN(${cs})${kind} GROUP BY a.ActivityId,a.CruiseId`;
 const historyQuery=itineraryAccess?`SELECT h.ChangeId,h.CruiseId,h.ChangeType,h.Subject,h.OldSchedule,h.NewSchedule,h.Reason,h.Staff,h.CreatedAt FROM (
  SELECT cc.ChangeId,cc.CruiseId,cc.ChangeType,CONCAT(N'Chuyến: ',cc.NewName) AS Subject,
   CASE WHEN cc.ChangeType='CREATE' THEN N'—' ELSE CONCAT(cc.OldName,N' · ',CONVERT(nvarchar(10),cc.OldStartDate,23),N' — ',CONVERT(nvarchar(10),cc.OldEndDate,23),N' · ',cc.OldStatus) END AS OldSchedule,
   CONCAT(cc.NewName,N' · ',CONVERT(nvarchar(10),cc.NewStartDate,23),N' — ',CONVERT(nvarchar(10),cc.NewEndDate,23),N' · ',cc.NewStatus) AS NewSchedule,
   cc.Reason,u.Name AS Staff,cc.CreatedAt FROM dbo.CruiseChanges cc JOIN dbo.Users u ON u.UserId=cc.StaffId
  UNION ALL
  SELECT ic.ChangeId,s.CruiseId,ic.ChangeType,CONCAT(N'Điểm dừng: ',COALESCE(np.Name,op.Name,p.Name,N'—')),
   CASE WHEN ic.ChangeType='CREATE' THEN N'—' ELSE CONCAT(COALESCE(op.Name,p.Name,N'—'),N' · ',CONVERT(nvarchar(16),ic.OldArrival,120),N' → ',CONVERT(nvarchar(16),ic.OldDeparture,120)) END,
   CONCAT(COALESCE(np.Name,p.Name,N'—'),N' · ',CONVERT(nvarchar(16),ic.NewArrival,120),N' → ',CONVERT(nvarchar(16),ic.NewDeparture,120)),
   ic.Reason,u.Name,ic.CreatedAt FROM dbo.ItineraryChanges ic JOIN dbo.Stops s ON s.StopId=ic.StopId JOIN dbo.Users u ON u.UserId=ic.StaffId
   LEFT JOIN dbo.Ports op ON op.PortId=ic.OldPortId LEFT JOIN dbo.Ports np ON np.PortId=ic.NewPortId LEFT JOIN dbo.Ports p ON p.PortId=s.PortId
 ) h WHERE h.CruiseId IN(${cs}) ORDER BY h.CreatedAt DESC`:`SELECT CAST(NULL AS bigint) AS ChangeId,CAST(NULL AS int) AS CruiseId,CAST(NULL AS varchar(10)) AS ChangeType,CAST(NULL AS nvarchar(200)) AS Subject,CAST(NULL AS nvarchar(500)) AS OldSchedule,CAST(NULL AS nvarchar(500)) AS NewSchedule,CAST(NULL AS nvarchar(500)) AS Reason,CAST(NULL AS nvarchar(100)) AS Staff,CAST(NULL AS datetime2) AS CreatedAt WHERE 1=0`;
 const cols={cruises:`SELECT c.*,s.Name AS Ship FROM Cruises c JOIN Ships s ON s.ShipId=c.ShipId WHERE c.CruiseId IN(${cs})`,ships:'SELECT ShipId,Name,Capacity FROM Ships',ports:'SELECT PortId,Name FROM Ports',stops:`SELECT s.StopId,s.CruiseId,s.PortId,p.Name AS Port,s.Arrival,s.Departure FROM Stops s JOIN Ports p ON p.PortId=s.PortId WHERE s.CruiseId IN(${cs})`,activities:`SELECT a.*,COALESCE(z.Name,p.Name,N'—') AS Location FROM Activities a LEFT JOIN Zones z ON z.ZoneId=a.ZoneId LEFT JOIN Stops st ON st.StopId=a.StopId LEFT JOIN Ports p ON p.PortId=st.PortId WHERE a.CruiseId IN(${cs})${kind}`,registrations:registrationStats,notifications:`SELECT n.NotificationId,n.CruiseId,n.Message,n.CreatedAt,CAST(CASE WHEN nr.UserId IS NULL THEN 0 ELSE 1 END AS bit) AS IsRead FROM dbo.Notifications n LEFT JOIN dbo.NotificationReads nr ON nr.NotificationId=n.NotificationId AND nr.UserId=${u.UserId} WHERE n.CruiseId IN(${cs})`,changes:historyQuery,services:'SELECT ServiceId,Name,Price FROM Services',devices:"SELECT DeviceId,Name,Kind FROM Devices WHERE Kind='POS'",packageServices:'SELECT PackageId,ServiceId FROM PackageServices',
 bookings:bookingQuery(u)+(guests?'':' AND 1=0'),accounts:`SELECT AccountId,BookingId,Status FROM Accounts WHERE BookingId IN(${bs})${money?'':' AND 1=0'}`,
 identifiers:guest?`SELECT i.IdentifierId,i.BookingId,i.Code,i.Kind FROM dbo.Identifiers i JOIN dbo.Bookings b ON b.BookingId=i.BookingId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId WHERE p.UserId=${u.UserId} AND i.Active=1`:'SELECT IdentifierId,BookingId,Code,Kind FROM dbo.Identifiers WHERE 1=0',
 checkinDevices:u.roles.some(r=>['ACTIVITY','SHORE','ADMIN'].includes(r))?"SELECT DeviceId,Name,Kind FROM dbo.Devices WHERE Kind='CHECKIN'":'SELECT DeviceId,Name,Kind FROM dbo.Devices WHERE 1=0',
 checkinRegistrations:(guest||u.roles.some(r=>['ACTIVITY','SHORE','ADMIN'].includes(r)))?`SELECT r.RegistrationId,r.BookingId,r.ActivityId,a.CruiseId,r.Status,a.Name AS Activity,a.Kind,a.StartsAt,a.ReturnAt,p.UserId,u.Name AS Passenger,ci.CreatedAt AS CheckedInAt,ci.ReturnedAt,ci.DeviceId,d.Name AS Device,ci.StaffId,staff.Name AS Staff FROM dbo.Registrations r JOIN dbo.Activities a ON a.ActivityId=r.ActivityId JOIN dbo.Bookings b ON b.BookingId=r.BookingId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId JOIN dbo.Users u ON u.UserId=p.UserId LEFT JOIN dbo.CheckIns ci ON ci.RegistrationId=r.RegistrationId LEFT JOIN dbo.Devices d ON d.DeviceId=ci.DeviceId LEFT JOIN dbo.Users staff ON staff.UserId=ci.StaffId WHERE a.CruiseId IN(${cs})${guest?' AND p.UserId='+u.UserId:''}${kind}`:`SELECT RegistrationId,BookingId,ActivityId,Status,CAST(NULL AS nvarchar(150)) AS Activity,CAST(NULL AS varchar(20)) AS Kind,CAST(NULL AS datetime2) AS StartsAt,CAST(NULL AS datetime2) AS ReturnAt,CAST(NULL AS int) AS UserId,CAST(NULL AS nvarchar(100)) AS Passenger,CAST(NULL AS datetime2) AS CheckedInAt,CAST(NULL AS datetime2) AS ReturnedAt,CAST(NULL AS int) AS DeviceId,CAST(NULL AS nvarchar(100)) AS Device,CAST(NULL AS int) AS StaffId,CAST(NULL AS nvarchar(100)) AS Staff FROM dbo.Registrations WHERE 1=0`,
  transactions:`SELECT t.TransactionId,t.AccountId,t.Amount,t.Status,t.CreatedAt,t.RefundAmount,t.RefundedAt,COALESCE(s.Name,a.Name,N'Dịch vụ') AS Description FROM Transactions t JOIN Accounts ac ON ac.AccountId=t.AccountId LEFT JOIN Services s ON s.ServiceId=t.ServiceId LEFT JOIN Registrations r ON r.RegistrationId=t.RegistrationId LEFT JOIN Activities a ON a.ActivityId=r.ActivityId WHERE ac.BookingId IN(${bs})${money?'':' AND 1=0'}`};
 const out=await jsonQuery('SELECT '+Object.entries(cols).map(([k,sql])=>`JSON_QUERY((${sql} FOR JSON PATH)) AS [${k}]`).join(',')+' FOR JSON PATH,WITHOUT_ARRAY_WRAPPER');
 for(const k of Object.keys(cols))if(!Array.isArray(out[k]))out[k]=[];return out;
}
const server=http.createServer(async(req,res)=>{
 const send=(status,data)=>{res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(JSON.stringify(data));};
 try{
  const url=new URL(req.url,`http://localhost:${port}`);
  if(req.method==='POST'&&req.headers.origin&&![`http://localhost:${port}`,`http://127.0.0.1:${port}`].includes(req.headers.origin))fail(403,'Nguồn yêu cầu không hợp lệ.');
  if(url.pathname==='/api/login'&&req.method==='POST'){
   const b=await requestJson(req);
   const email=text(b.email,150).trim(),password=text(b.password,100),key=req.socket.remoteAddress,t=attempts.get(key);
   if(t&&Date.now()-t.time<60000&&t.count>=15)fail(429,'Thử lại sau một phút.');
   const u=(await jsonQuery(`SELECT UserId,PasswordHash FROM Users WHERE Email=${literal(email)} AND Active=1 FOR JSON PATH`))[0];
   if(!u||!verifyPassword(password,u.PasswordHash)){const a=t&&Date.now()-t.time<60000?t:{count:0,time:Date.now()};a.count++;attempts.set(key,a);fail(401,'Email hoặc mật khẩu không đúng.');}
   const granted=await jsonQuery(`SELECT r.Code FROM UserRoles ur JOIN Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=${u.UserId} FOR JSON PATH`);
   if(!granted.some(r=>Object.hasOwn(roles,r.Code)))fail(403,'Tài khoản chưa được cấp vai trò.');
   attempts.delete(key);sessions.delete(sessionId(req));const sid=randomBytes(32).toString('hex');sessions.set(sid,{userId:u.UserId,expires:Date.now()+ttl});
   res.setHeader('Set-Cookie',`${cookieName}=${sid}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${Math.floor(ttl/1000)}`);return send(200,{ok:true});
  }
  if(url.pathname==='/api/logout'&&req.method==='POST'){sessions.delete(sessionId(req));res.setHeader('Set-Cookie',`${cookieName}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`);return send(200,{ok:true});}
  if(url.pathname.startsWith('/api/')){
   const u=await getUser(req);if(!u)fail(401,'Vui lòng đăng nhập.');
   if(req.method==='GET'&&url.pathname==='/api/qr'){
    requireRoles(u,'PASSENGER');const bookingId=id(url.searchParams.get('booking'));
    const rows=await jsonQuery(`SELECT TOP(1) i.Code FROM dbo.Identifiers i JOIN dbo.Bookings b ON b.BookingId=i.BookingId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId WHERE i.BookingId=${bookingId} AND i.Active=1 AND ${u.roles.includes('ADMIN')?'1=1':`p.UserId=${u.UserId}`} ORDER BY i.IdentifierId FOR JSON PATH`);
    if(!rows.length)fail(404,'Booking không có mã định danh đang hoạt động.');
    const svg=await QRCode.toString(rows[0].Code,{type:'svg',margin:2});res.writeHead(200,{'Content-Type':'image/svg+xml; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});return res.end(svg);
   }
   if(req.method==='POST'&&url.pathname==='/api/checkin'){
    const b=await requestJson(req),activityId=id(b.activityId),deviceId=id(b.deviceId),code=text(b.code,100).trim();
    const kind=(await jsonQuery(`SELECT Kind FROM dbo.Activities WHERE ActivityId=${activityId} FOR JSON PATH`))[0]?.Kind;if(!kind)fail(404,'Hoạt động không tồn tại.');
    requireRoles(u,kind==='SHORE'?'SHORE':'ACTIVITY');
    await runProcedure(`EXEC dbo.usp_CheckIn @ActivityId=${activityId},@Code=${literal(code)},@DeviceId=${deviceId},@StaffId=${u.UserId};`);
    return send(200,{ok:true,message:'Check-in thành công.'});
   }
   const returnMatch=/^\/api\/checkin\/(\d+)\/return$/.exec(url.pathname);
   if(req.method==='POST'&&returnMatch){requireRoles(u,'SHORE');await requestJson(req);await runProcedure(`EXEC dbo.usp_ReturnToShip @RegistrationId=${id(returnMatch[1])},@StaffId=${u.UserId};`);return send(200,{ok:true,message:'Đã ghi nhận khách về tàu.'});}
   if(req.method==='POST'&&url.pathname==='/api/pos/quote'){
    requireRoles(u,'POS');const b=await requestJson(req),code=text(b.code,100).trim(),serviceId=id(b.serviceId),quantity=whole(b.quantity,1,100,'Số lượng');
    const quote=(await jsonQuery(`SELECT TOP(1) b.BookingId,b.PackageId,a.AccountId,a.Status AS AccountStatus,u.Name AS Passenger,pk.Name AS Package,s.ServiceId,s.Name AS Service,s.Price AS ListUnitPrice,CAST(CASE WHEN ps.ServiceId IS NULL THEN 0 ELSE 1 END AS bit) AS IncludedInPackage,CONVERT(decimal(18,2),CASE WHEN ps.ServiceId IS NULL THEN s.Price ELSE 0 END) AS UnitPrice,CONVERT(decimal(18,2),CASE WHEN ps.ServiceId IS NULL THEN s.Price*${quantity} ELSE 0 END) AS Total,CONVERT(decimal(18,2),COALESCE((SELECT SUM(CASE t.Status WHEN 'POSTED' THEN t.Amount WHEN 'REFUNDED' THEN t.Amount-COALESCE(t.RefundAmount,0) ELSE 0 END) FROM dbo.Transactions t WHERE t.AccountId=a.AccountId),0)) AS AccountBalance FROM dbo.Identifiers i JOIN dbo.Bookings b ON b.BookingId=i.BookingId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId JOIN dbo.Users u ON u.UserId=p.UserId JOIN dbo.Packages pk ON pk.PackageId=b.PackageId JOIN dbo.Accounts a ON a.BookingId=b.BookingId JOIN dbo.Services s ON s.ServiceId=${serviceId} LEFT JOIN dbo.PackageServices ps ON ps.PackageId=b.PackageId AND ps.ServiceId=s.ServiceId WHERE i.Code=${literal(code)} AND i.Active=1 FOR JSON PATH`))[0];
    if(!quote)fail(422,'Mã hành khách hoặc dịch vụ không hợp lệ.');
    quote.IncludedServices=await jsonQuery(`SELECT s.ServiceId,s.Name,s.Price FROM dbo.PackageServices ps JOIN dbo.Services s ON s.ServiceId=ps.ServiceId WHERE ps.PackageId=${quote.PackageId} ORDER BY s.Name FOR JSON PATH`);
    delete quote.PackageId;
    return send(200,quote);
   }
   if(req.method==='POST'&&url.pathname==='/api/itinerary/cruises'){
    requireRoles(u,'ITINERARY');const b=await requestJson(req),cruiseId=maybeId(b.cruiseId),shipId=id(b.shipId),name=text(b.name,150).trim(),startDate=dateOnly(b.startDate),endDate=dateOnly(b.endDate),status=text(b.status,20).trim().toUpperCase(),reason=text(b.reason,500).trim();
    if(endDate<startDate)fail(400,'Ngày kết thúc phải bằng hoặc sau ngày bắt đầu.');
    await runProcedure(`EXEC dbo.usp_SaveCruise @CruiseId=${cruiseId},@ShipId=${shipId},@Name=${literal(name)},@StartDate=${literal(startDate)},@EndDate=${literal(endDate)},@Status=${literal(status)},@Reason=${literal(reason)},@StaffId=${u.UserId};`);
    return send(200,{ok:true});
   }
   if(req.method==='POST'&&url.pathname==='/api/itinerary/stops'){
    requireRoles(u,'ITINERARY');const b=await requestJson(req),stopId=maybeId(b.stopId),cruiseId=id(b.cruiseId),portId=id(b.portId),arrival=dateTime(b.arrival),departure=dateTime(b.departure),reason=text(b.reason,500).trim();
    if(departure<=arrival)fail(400,'Giờ rời cảng phải sau giờ đến.');
    const sql=stopId===0
     ?`EXEC dbo.usp_AddStop @CruiseId=${cruiseId},@PortId=${portId},@Arrival=${literal(arrival)},@Departure=${literal(departure)},@Reason=${literal(reason)},@StaffId=${u.UserId};`
     :`EXEC dbo.usp_ChangeStop @StopId=${stopId},@PortId=${portId},@Arrival=${literal(arrival)},@Departure=${literal(departure)},@Reason=${literal(reason)},@StaffId=${u.UserId};`;
    await runProcedure(sql);return send(200,{ok:true});
   }
   if(req.method==='POST'&&url.pathname==='/api/pos/sync'){
    requireRoles(u,'POS');const b=await requestJson(req),clientId=text(b.clientId,36).trim(),code=text(b.code,100).trim(),serviceId=id(b.serviceId),quantity=whole(b.quantity,1,100,'Số lượng'),deviceId=id(b.deviceId);
    if(!/^[a-f\d]{8}(-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(clientId))fail(400,'UUID giao dịch không hợp lệ.');
    await runProcedure(`EXEC dbo.usp_SyncPOS @Code=${literal(code)},@ServiceId=${serviceId},@Quantity=${quantity},@DeviceId=${deviceId},@StaffId=${u.UserId},@ClientId=${literal(clientId)};`);
    const transaction=(await jsonQuery(`SELECT t.TransactionId,t.ClientId,t.AccountId,t.ServiceId,t.DeviceId,t.Quantity,t.Amount,t.Status,t.CreatedAt FROM dbo.Transactions t WHERE t.ClientId=CONVERT(uniqueidentifier,${literal(clientId)}) FOR JSON PATH`))[0];
    if(!transaction)throw Error('SQL Server chưa trả về giao dịch đã đồng bộ.');
    const receipt=(await jsonQuery(`SELECT r.ReceiptId,r.ClientId,r.DeviceId,d.Name AS DeviceName,r.StaffId,staff.Name AS StaffName,r.SyncedAt,t.TransactionId,t.AccountId,b.BookingId,guest.Name AS PassengerName,pk.Name AS Package,CONVERT(decimal(18,2),COALESCE((SELECT SUM(CASE tx.Status WHEN 'POSTED' THEN tx.Amount WHEN 'REFUNDED' THEN tx.Amount-COALESCE(tx.RefundAmount,0) ELSE 0 END) FROM dbo.Transactions tx WHERE tx.AccountId=a.AccountId),0)) AS AccountBalance,t.ServiceId,s.Name AS ServiceName,t.Quantity,t.Amount,t.Status FROM dbo.POSReceipts r JOIN dbo.Devices d ON d.DeviceId=r.DeviceId JOIN dbo.Users staff ON staff.UserId=r.StaffId JOIN dbo.Transactions t ON t.ClientId=r.ClientId JOIN dbo.Services s ON s.ServiceId=t.ServiceId JOIN dbo.Accounts a ON a.AccountId=t.AccountId JOIN dbo.Bookings b ON b.BookingId=a.BookingId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId JOIN dbo.Users guest ON guest.UserId=p.UserId JOIN dbo.Packages pk ON pk.PackageId=b.PackageId WHERE r.ClientId=CONVERT(uniqueidentifier,${literal(clientId)}) AND r.StaffId=${u.UserId} FOR JSON PATH`))[0];
    if(!receipt)throw Error('SQL Server chưa trả về biên nhận đã lưu.');
    return send(200,{ok:true,transaction,receipt});
   }
   if(req.method==='POST'&&url.pathname==='/api/passenger/disputes'){
    requireRoles(u,'PASSENGER');const b=await requestJson(req),transactionId=id(b.transactionId),reason=text(b.reason,500).trim();
    if(reason.length<10)fail(400,'Lý do tranh chấp phải có từ 10 đến 500 ký tự.');
    await runProcedure(`EXEC dbo.usp_SubmitPassengerDispute @TransactionId=${transactionId},@PassengerUserId=${u.UserId},@Reason=${literal(reason)};`);
    const dispute=(await jsonQuery(`SELECT TOP(1) d.DisputeId,d.TransactionId,d.Reason,d.Status,d.SubmittedAt,d.ResolvedAt,d.Resolution FROM dbo.Disputes d JOIN dbo.Transactions t ON t.TransactionId=d.TransactionId JOIN dbo.Accounts ac ON ac.AccountId=t.AccountId JOIN dbo.Bookings b ON b.BookingId=ac.BookingId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId WHERE d.TransactionId=${transactionId} AND d.SubmittedBy=${u.UserId} ORDER BY d.SubmittedAt DESC FOR JSON PATH`))[0];
    if(!dispute)throw Error('SQL Server chưa trả về tranh chấp đã ghi nhận.');
    return send(201,dispute);
   }
    if(req.method==='POST'&&url.pathname==='/api/finance/transactions'){
     requireRoles(u,'FINANCE');const b=await requestJson(req),transactionId=id(b.transactionId),status=text(b.status,20).trim().toUpperCase();
     if(!['VOID','REFUNDED'].includes(status))fail(400,'Thao tác tài chính không hợp lệ.');
     await runProcedure(`EXEC dbo.usp_FinanceTransaction @TransactionId=${transactionId},@StaffId=${u.UserId},@Status=${literal(status)};`);
     return send(200,{ok:true});
    }
    if(req.method==='POST'&&url.pathname==='/api/finance/reconcile'){
     requireRoles(u,'FINANCE');const b=await requestJson(req);
     await runProcedure(`EXEC dbo.usp_Reconcile @TransactionId=${id(b.transactionId)},@StaffId=${u.UserId};`);
     return send(200,{ok:true});
    }
    if(req.method==='POST'&&url.pathname==='/api/finance/settle'){
     requireRoles(u,'FINANCE');const b=await requestJson(req);
     await runProcedure(`EXEC dbo.usp_SettleAccount @AccountId=${id(b.accountId)},@ActorId=${u.UserId},@Method='MOCK';`);
     return send(200,{ok:true});
    }
    if(req.method==='POST'&&url.pathname==='/api/finance/disputes/resolve'){
     requireRoles(u,'FINANCE');const b=await requestJson(req),disputeId=id(b.disputeId),resolution=typeof b.resolution==='string'?b.resolution.trim():'';
     if(resolution.length>500)fail(400,'Phản hồi không được vượt quá 500 ký tự.');
     await runProcedure(`EXEC dbo.usp_ResolveDispute @DisputeId=${disputeId},@StaffId=${u.UserId},@Resolution=${literal(resolution)};`);
     return send(200,{ok:true});
    }
    if(req.method==='POST'&&url.pathname==='/api/notifications'){
     requireRoles(u,'ITINERARY','OPERATIONS');const b=await requestJson(req),cruiseId=id(b.cruiseId),message=text(b.message,500).trim();
     await runProcedure(`EXEC dbo.usp_Notify @CruiseId=${cruiseId},@Message=${literal(message)},@StaffId=${u.UserId};`);
     return send(201,{ok:true});
    }
    if(req.method==='POST'&&url.pathname==='/api/notifications/read'){
     const b=await requestJson(req);
     await runProcedure(`EXEC dbo.usp_ReadNotification @NotificationId=${id(b.notificationId)},@UserId=${u.UserId};`);
     return send(200,{ok:true});
    }
   if(req.method==='GET'&&url.pathname==='/api/pos/receipts'){
    requireRoles(u,'POS');return send(200,await jsonQuery(`SELECT TOP(50) r.ReceiptId,r.ClientId,r.DeviceId,d.Name AS DeviceName,r.StaffId,staff.Name AS StaffName,r.SyncedAt,t.TransactionId,t.AccountId,b.BookingId,guest.Name AS PassengerName,pk.Name AS Package,CONVERT(decimal(18,2),COALESCE((SELECT SUM(CASE tx.Status WHEN 'POSTED' THEN tx.Amount WHEN 'REFUNDED' THEN tx.Amount-COALESCE(tx.RefundAmount,0) ELSE 0 END) FROM dbo.Transactions tx WHERE tx.AccountId=a.AccountId),0)) AS AccountBalance,t.ServiceId,s.Name AS ServiceName,t.Quantity,t.Amount,t.Status FROM dbo.POSReceipts r JOIN dbo.Devices d ON d.DeviceId=r.DeviceId JOIN dbo.Users staff ON staff.UserId=r.StaffId JOIN dbo.Transactions t ON t.ClientId=r.ClientId JOIN dbo.Services s ON s.ServiceId=t.ServiceId JOIN dbo.Accounts a ON a.AccountId=t.AccountId JOIN dbo.Bookings b ON b.BookingId=a.BookingId JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId JOIN dbo.Users guest ON guest.UserId=p.UserId JOIN dbo.Packages pk ON pk.PackageId=b.PackageId WHERE r.StaffId=${u.UserId} ORDER BY r.SyncedAt DESC FOR JSON PATH`));
   }
   if(req.method==='POST'&&url.pathname.startsWith('/api/shore/')){
    requireRoles(u,'SHORE');const b=await requestJson(req),path=url.pathname;
    if(path==='/api/shore/providers'){const providerId=maybeId(b.providerId),name=text(b.name,100).trim(),contactName=b.contactName?text(b.contactName,100).trim():null,phone=b.phone?text(b.phone,30).trim():null,email=b.email?text(b.email,150).trim():null,active=b.active!==false;await runProcedure(`EXEC dbo.usp_SaveShoreProvider @ActorId=${u.UserId},@ProviderId=${providerId},@Name=${literal(name)},@ContactName=${literal(contactName)},@Phone=${literal(phone)},@Email=${literal(email)},@Active=${active?1:0};`);return send(providerId?200:201,{ok:true});}
    if(path==='/api/shore/vehicles'){const vehicleId=maybeId(b.vehicleId),providerId=id(b.providerId),name=text(b.name,100).trim(),plateNumber=b.plateNumber?text(b.plateNumber,30).trim():null,capacity=whole(b.capacity,1,1000,'Sức chứa xe'),active=b.active!==false;await runProcedure(`EXEC dbo.usp_SaveShoreVehicle @ActorId=${u.UserId},@VehicleId=${vehicleId},@ProviderId=${providerId},@Name=${literal(name)},@PlateNumber=${literal(plateNumber)},@Capacity=${capacity},@Active=${active?1:0};`);return send(vehicleId?200:201,{ok:true});}
    if(path==='/api/shore/guides'){const guideId=maybeId(b.guideId),providerId=id(b.providerId),name=text(b.name,100).trim(),phone=b.phone?text(b.phone,30).trim():null,active=b.active!==false;await runProcedure(`EXEC dbo.usp_SaveShoreGuide @ActorId=${u.UserId},@GuideId=${guideId},@ProviderId=${providerId},@Name=${literal(name)},@Phone=${literal(phone)},@Active=${active?1:0};`);return send(guideId?200:201,{ok:true});}
    if(path==='/api/shore/excursions'){const activityId=maybeId(b.activityId),cruiseId=id(b.cruiseId),stopId=id(b.stopId),providerId=id(b.providerId),name=text(b.name,150).trim(),gatherAt=dateTime(b.gatherAt),returnAt=dateTime(b.returnAt),capacity=whole(b.capacity,1,100000,'Sức chứa'),fee=amount(b.fee,'Phí'),status=text(b.status||'OPEN',20).trim().toUpperCase();if(returnAt<=gatherAt)fail(400,'Giờ về tàu phải sau giờ tập trung.');await runProcedure(`EXEC dbo.usp_SaveShoreExcursion @ActorId=${u.UserId},@ActivityId=${activityId},@CruiseId=${cruiseId},@StopId=${stopId},@ProviderId=${providerId},@Name=${literal(name)},@GatherAt=${literal(gatherAt)},@ReturnAt=${literal(returnAt)},@Capacity=${capacity},@Fee=${fee},@Status=${literal(status)};`);return send(activityId?200:201,{ok:true});}
    if(path==='/api/shore/groups'){const groupId=maybeId(b.groupId),activityId=id(b.activityId),name=text(b.name,100).trim(),vehicleId=maybeId(b.vehicleId),guideId=maybeId(b.guideId),capacity=whole(b.capacity,1,100000,'Sức chứa nhóm'),active=b.active!==false;await runProcedure(`EXEC dbo.usp_SaveExcursionGroup @ActorId=${u.UserId},@GroupId=${groupId},@ActivityId=${activityId},@Name=${literal(name)},@VehicleId=${vehicleId||null},@GuideId=${guideId||null},@Capacity=${capacity},@Active=${active?1:0};`);return send(groupId?200:201,{ok:true});}
    if(path==='/api/shore/assignments'){const registrationId=id(b.registrationId),groupId=maybeId(b.groupId);await runProcedure(`EXEC dbo.usp_AssignExcursionGuest @ActorId=${u.UserId},@RegistrationId=${registrationId},@GroupId=${groupId||null};`);return send(200,{ok:true});}
   }   if(req.method==='POST'&&url.pathname==='/api/activity/activities'){
    requireRoles(u,'ACTIVITY');const b=await requestJson(req),activityId=maybeId(b.activityId),cruiseId=id(b.cruiseId),zoneId=id(b.zoneId),name=text(b.name,150).trim(),startsAt=dateTime(b.startsAt),endsAt=dateTime(b.endsAt),capacity=whole(b.capacity,1,100000,'Sức chứa'),fee=amount(b.fee,'Phí tham gia'),status=text(b.status||'OPEN',20).trim().toUpperCase();
    if(endsAt<=startsAt)fail(400,'Thời gian kết thúc phải sau thời gian bắt đầu.');
    if(!['OPEN','DELAYED','COMPLETED'].includes(status))fail(400,'Trạng thái hoạt động không hợp lệ.');
    await runProcedure(`EXEC dbo.usp_SaveOnboardActivity @ActorId=${u.UserId},@ActivityId=${activityId},@CruiseId=${cruiseId},@ZoneId=${zoneId},@Name=${literal(name)},@StartsAt=${literal(startsAt)},@EndsAt=${literal(endsAt)},@Capacity=${capacity},@Fee=${fee},@Status=${literal(status)};`);
    return send(activityId===0?201:200,{ok:true});
   }
   const cancelActivityMatch=/^\/api\/activity\/activities\/(\d+)\/cancel$/.exec(url.pathname);
   if(req.method==='POST'&&cancelActivityMatch){
    requireRoles(u,'ACTIVITY');const activityId=id(cancelActivityMatch[1]),b=await requestJson(req),reason=text(b.reason,500).trim();
    if(reason.length<3)fail(400,'Lý do hủy phải có từ 3 đến 500 ký tự.');
    const result=JSON.parse(await runProcedure(`EXEC dbo.usp_CancelOnboardActivity @ActorId=${u.UserId},@ActivityId=${activityId},@Reason=${literal(reason)};`));
    return send(200,{ok:true,...result});
   }
   if(req.method==='POST'&&url.pathname==='/api/registrations'){
    requireRoles(u,'PASSENGER');const b=await requestJson(req),bookingId=id(b.bookingId),activityId=id(b.activityId);
    const allowed=await jsonQuery(bookingQuery(u,bookingId)+' FOR JSON PATH');
    if(!allowed.length)fail(403,'Không có quyền đăng ký cho booking này.');
    await runProcedure(`EXEC dbo.usp_Register @BookingId=${bookingId},@ActivityId=${activityId},@ActorId=${u.UserId};`);
    const rows=await jsonQuery(`SELECT r.RegistrationId,r.ActivityId,r.BookingId,r.Status,r.PriceAtRegistration,r.CreatedAt,CASE WHEN r.Status='WAITLIST' THEN (SELECT COUNT(*) FROM dbo.Registrations w WHERE w.ActivityId=r.ActivityId AND w.Status='WAITLIST' AND (w.CreatedAt<r.CreatedAt OR (w.CreatedAt=r.CreatedAt AND w.RegistrationId<=r.RegistrationId))) END AS WaitlistPosition FROM dbo.Registrations r WHERE r.BookingId=${bookingId} AND r.ActivityId=${activityId} FOR JSON PATH`);
    return send(201,rows[0]);
   }
   const cancelMatch=/^\/api\/registrations\/(\d+)\/cancel$/.exec(url.pathname);
   if(req.method==='POST'&&cancelMatch){
    requireRoles(u,'PASSENGER');
    const registrationId=id(cancelMatch[1]),body=await requestJson(req),reason=text(body.reason,500).trim();
    await runProcedure(`EXEC dbo.usp_CancelRegistration @RegistrationId=${registrationId},@ActorId=${u.UserId},@Reason=${literal(reason)};`);
    const rows=await jsonQuery(`SELECT RegistrationId,Status,CancelledAt,CancelledBy,CancelReason,RefundAmount FROM dbo.Registrations WHERE RegistrationId=${registrationId} FOR JSON PATH`);
    return send(200,rows[0]);
   }
   if(req.method==='POST'&&url.pathname==='/api/admin/users'){
    requireRoles(u,'ADMIN');const b=await requestJson(req),userId=maybeId(b.userId),name=text(b.name,100).trim(),email=text(b.email,150).trim().toLowerCase();
    if(typeof b.active!=='boolean')fail(400,'Trạng thái tài khoản không hợp lệ.');
    if(!Array.isArray(b.roles)||!b.roles.length||b.roles.length>Object.keys(roles).length||b.roles.some(r=>typeof r!=='string'||!Object.hasOwn(roles,r))||new Set(b.roles).size!==b.roles.length)fail(400,'Danh sách vai trò không hợp lệ.');
    let passwordHash=null;if(b.password!==undefined&&b.password!==''){const password=text(b.password,100);if(password.length<8)fail(400,'Mật khẩu phải có ít nhất 8 ký tự.');passwordHash=hashPassword(password);}
    if(userId===0&&!passwordHash)fail(400,'Người dùng mới phải có mật khẩu.');
    await runProcedure(`EXEC dbo.usp_AdminSaveUser @ActorId=${u.UserId},@UserId=${userId},@Name=${literal(name)},@Email=${literal(email)},@Active=${b.active?1:0},@RoleCodes=${literal(b.roles.join(','))},@PasswordHash=${literal(passwordHash)};`);
    const saved=(await jsonQuery(`SELECT u.UserId,u.Name,u.Email,u.Active,JSON_QUERY((SELECT r.Code FROM UserRoles ur JOIN Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=u.UserId FOR JSON PATH)) AS roles FROM Users u WHERE u.Email=${literal(email)} FOR JSON PATH`))[0];
    const currentSession=sessionId(req);for(const [sid,session] of sessions)if(session.userId===saved.UserId&&sid!==currentSession)sessions.delete(sid);
    return send(userId===0?201:200,saved);
   }
   if(req.method==='POST'&&url.pathname==='/api/admin/catalogs'){
    requireRoles(u,'ADMIN');const b=await requestJson(req),entity=text(b.entity,20).trim().toLowerCase(),catalogId=maybeId(b.catalogId),supported=['ship','zone','cabin','port','provider','service','package','device'];
    if(!supported.includes(entity))fail(400,'Danh mục không được hỗ trợ.');
    const name=entity==='cabin'?null:text(b.name,150).trim(),number=entity==='cabin'?text(b.number,20).trim():null,parentId=['zone','cabin'].includes(entity)?id(b.parentId):null,capacity=entity==='ship'?whole(b.capacity,1,100000,'Sức chứa'):null,price=entity==='service'?amount(b.price,'Giá dịch vụ'):null,kind=entity==='device'?text(b.kind,20).trim().toUpperCase():null;
    await runProcedure(`EXEC dbo.usp_AdminSaveCatalog @ActorId=${u.UserId},@Entity=${literal(entity)},@Id=${catalogId},@Name=${literal(name)},@ParentId=${literal(parentId)},@Number=${literal(number)},@Capacity=${literal(capacity)},@Price=${literal(price)},@Kind=${literal(kind)};`);
    return send(catalogId===0?201:200,{ok:true});
   }
   if(req.method==='POST'&&url.pathname==='/api/admin/bookings'){
    requireRoles(u,'ADMIN');const b=await requestJson(req),bookingId=maybeId(b.bookingId),cruiseId=id(b.cruiseId),userId=id(b.userId),cabinId=id(b.cabinId),packageId=id(b.packageId);
    await runProcedure(`EXEC dbo.usp_AdminSaveBooking @ActorId=${u.UserId},@BookingId=${bookingId},@CruiseId=${cruiseId},@UserId=${userId},@CabinId=${cabinId},@PackageId=${packageId};`);
    return send(bookingId===0?201:200,{ok:true});
   }
   if(req.method==='POST'&&url.pathname==='/api/admin/package-services'){
    requireRoles(u,'ADMIN');const b=await requestJson(req);if(typeof b.included!=='boolean')fail(400,'Trạng thái dịch vụ trong gói không hợp lệ.');
    await runProcedure(`EXEC dbo.usp_AdminPackageService @ActorId=${u.UserId},@PackageId=${id(b.packageId)},@ServiceId=${id(b.serviceId)},@Included=${b.included?1:0};`);return send(200,{ok:true});
   }
   if(req.method==='POST'&&url.pathname==='/api/admin/policy'){
    requireRoles(u,'ADMIN');const b=await requestJson(req),cancelHours=whole(b.cancelHours,0,8760,'Số giờ hủy'),refundPercent=whole(b.refundPercent,0,100,'Tỷ lệ hoàn phí');
    await runProcedure(`EXEC dbo.usp_AdminSavePolicy @ActorId=${u.UserId},@CancelHours=${cancelHours},@RefundPercent=${refundPercent};`);return send(200,{ok:true});
   }
   const identifierMatch=/^\/api\/admin\/identifiers\/(\d+)\/active$/.exec(url.pathname);
   if(req.method==='POST'&&identifierMatch){
    requireRoles(u,'ADMIN');const b=await requestJson(req);if(typeof b.active!=='boolean')fail(400,'Trạng thái mã định danh không hợp lệ.');
    await runProcedure(`EXEC dbo.usp_AdminSetIdentifierActive @ActorId=${u.UserId},@IdentifierId=${id(identifierMatch[1])},@Active=${b.active?1:0};`);return send(200,{ok:true});
   }
   if(req.method==='POST'&&url.pathname==='/api/feedback'){
    requireRoles(u,'PASSENGER');const b=await requestJson(req),kind=typeof b.kind==='string'?b.kind.toUpperCase():'';
    if(!['ACTIVITY','CRUISE'].includes(kind))fail(400,'Loại đánh giá không hợp lệ.');
    const rating=whole(b.rating,1,5,'Điểm đánh giá'),comment=b.comment===undefined||b.comment===null?'':(typeof b.comment==='string'&&b.comment.length<=500?b.comment:fail(400,'Nhận xét không được vượt quá 500 ký tự.'));
    const registrationId=kind==='ACTIVITY'?id(b.registrationId):0,bookingId=kind==='CRUISE'?id(b.bookingId):0;
    await runProcedure(`EXEC dbo.usp_SubmitFeedback @ActorId=${u.UserId},@Kind=${literal(kind)},@Rating=${rating},@Comment=${literal(comment)},@RegistrationId=${registrationId},@BookingId=${bookingId};`);
    return send(201,{ok:true});
   }
   if(req.method!=='GET')fail(405,'Phương thức không được hỗ trợ cho API này.');
   if(url.pathname==='/api/me')return send(200,u);
   if(url.pathname==='/api/passenger/finance'){
    requireRoles(u,'PASSENGER');const finance=await jsonQuery(passengerFinanceQuery(u));
    for(const key of ['accounts','transactions','invoices'])if(!Array.isArray(finance?.[key]))finance[key]=[];
    return send(200,finance);
   }
    if(url.pathname==='/api/finance/data'){
     requireRoles(u,'FINANCE');const finance=await jsonQuery(staffFinanceQuery());
     for(const key of ['accounts','transactions','disputes','invoices'])if(!Array.isArray(finance[key]))finance[key]=[];
     return send(200,finance);
    }
   if(url.pathname==='/api/feedback/data'){
    requireRoles(u,'PASSENGER','OPERATIONS','ACTIVITY','SHORE','ADMIN');
    const guest=u.roles.includes('PASSENGER')&&!u.roles.includes('ADMIN');
    const activityRows=guest?(
     `SELECT r.RegistrationId,r.BookingId,a.ActivityId,a.CruiseId,c.Name AS Cruise,a.Name,a.Kind,a.StartsAt,a.Status,r.Status AS RegistrationStatus,f.Rating AS MyRating,f.Comment AS MyComment,
      CAST(CASE WHEN r.Status='CONFIRMED' AND a.Status='COMPLETED' AND ci.RegistrationId IS NOT NULL AND f.FeedbackId IS NULL THEN 1 ELSE 0 END AS bit) AS CanReview,
      CASE WHEN f.FeedbackId IS NOT NULL THEN N'Bạn đã đánh giá hoạt động này.' WHEN r.Status<>'CONFIRMED' THEN N'Chỉ đăng ký đã xác nhận mới đủ điều kiện.' WHEN ci.RegistrationId IS NULL THEN N'Bạn cần check-in hoạt động.' WHEN a.Status<>'COMPLETED' THEN N'Hoạt động chưa được đánh dấu hoàn thành.' ELSE N'Đủ điều kiện đánh giá.' END AS EligibilityMessage,
      (SELECT CAST(AVG(CAST(f2.Rating AS decimal(10,2))) AS decimal(4,2)) FROM dbo.Feedback f2 JOIN dbo.Registrations r2 ON r2.RegistrationId=f2.RegistrationId WHERE r2.ActivityId=a.ActivityId) AS AverageRating,
      (SELECT COUNT(*) FROM dbo.Feedback f2 JOIN dbo.Registrations r2 ON r2.RegistrationId=f2.RegistrationId WHERE r2.ActivityId=a.ActivityId) AS RatingCount
      FROM dbo.Registrations r JOIN dbo.Activities a ON a.ActivityId=r.ActivityId JOIN dbo.Bookings b ON b.BookingId=r.BookingId JOIN dbo.Cruises c ON c.CruiseId=a.CruiseId
      LEFT JOIN dbo.CheckIns ci ON ci.RegistrationId=r.RegistrationId LEFT JOIN dbo.Feedback f ON f.RegistrationId=r.RegistrationId
      WHERE b.PassengerId IN(SELECT PassengerId FROM dbo.Passengers WHERE UserId=${u.UserId}) ORDER BY a.StartsAt DESC,a.ActivityId FOR JSON PATH`
    ):(
     `SELECT a.ActivityId,a.CruiseId,c.Name AS Cruise,a.Name,a.Kind,a.StartsAt,a.Status,CAST(AVG(CAST(f.Rating AS decimal(10,2))) AS decimal(4,2)) AS AverageRating,COUNT(f.FeedbackId) AS RatingCount
      FROM dbo.Activities a JOIN dbo.Cruises c ON c.CruiseId=a.CruiseId LEFT JOIN dbo.Registrations r ON r.ActivityId=a.ActivityId LEFT JOIN dbo.Feedback f ON f.RegistrationId=r.RegistrationId
      GROUP BY a.ActivityId,a.CruiseId,c.Name,a.Name,a.Kind,a.StartsAt,a.Status ORDER BY a.StartsAt DESC,a.ActivityId FOR JSON PATH`
    );
    const cruiseRows=guest?(
     `SELECT b.BookingId,b.CruiseId,c.Name,c.StartDate,c.EndDate,c.Status,f.Rating AS MyRating,f.Comment AS MyComment,
      CAST(CASE WHEN c.Status='CLOSED' AND f.FeedbackId IS NULL THEN 1 ELSE 0 END AS bit) AS CanReview,
      CASE WHEN f.FeedbackId IS NOT NULL THEN N'Bạn đã đánh giá chuyến đi này.' WHEN c.Status<>'CLOSED' THEN N'Chỉ đánh giá được sau khi chuyến kết thúc.' ELSE N'Đủ điều kiện đánh giá.' END AS EligibilityMessage,
      (SELECT CAST(AVG(CAST(f2.Rating AS decimal(10,2))) AS decimal(4,2)) FROM dbo.CruiseFeedback f2 WHERE f2.CruiseId=c.CruiseId) AS AverageRating,
      (SELECT COUNT(*) FROM dbo.CruiseFeedback f2 WHERE f2.CruiseId=c.CruiseId) AS RatingCount
      FROM dbo.Bookings b JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId
      LEFT JOIN dbo.CruiseFeedback f ON f.BookingId=b.BookingId WHERE p.UserId=${u.UserId} ORDER BY c.StartDate DESC,b.BookingId FOR JSON PATH`
    ):(
     `SELECT c.CruiseId,c.Name,c.StartDate,c.EndDate,c.Status,CAST(AVG(CAST(f.Rating AS decimal(10,2))) AS decimal(4,2)) AS AverageRating,COUNT(f.FeedbackId) AS RatingCount
      FROM dbo.Cruises c LEFT JOIN dbo.CruiseFeedback f ON f.CruiseId=c.CruiseId GROUP BY c.CruiseId,c.Name,c.StartDate,c.EndDate,c.Status ORDER BY c.StartDate DESC,c.CruiseId FOR JSON PATH`
    );
    const data=(await jsonQuery(`SELECT JSON_QUERY((${activityRows})) AS activities,JSON_QUERY((${cruiseRows})) AS cruises FOR JSON PATH,WITHOUT_ARRAY_WRAPPER`))[0]||{};
    for(const key of ['activities','cruises'])if(!Array.isArray(data[key]))data[key]=[];return send(200,data);
   }
   if(url.pathname==='/api/state')return send(200,await state(u));
   if(req.method==='GET'&&url.pathname==='/api/activity/data'){
    requireRoles(u,'ACTIVITY');const data=await jsonQuery(`SELECT
     JSON_QUERY((SELECT CruiseId,ShipId,Name,StartDate,EndDate,Status FROM dbo.Cruises ORDER BY StartDate,CruiseId FOR JSON PATH)) AS cruises,
     JSON_QUERY((SELECT z.ZoneId,z.ShipId,z.Name AS ZoneName,s.Name AS ShipName FROM dbo.Zones z JOIN dbo.Ships s ON s.ShipId=z.ShipId ORDER BY s.Name,z.Name FOR JSON PATH)) AS zones,
     JSON_QUERY((SELECT a.ActivityId,a.CruiseId,c.Name AS Cruise,a.ZoneId,z.Name AS Location,a.Name,a.StartsAt,a.EndsAt,a.Capacity,a.Fee,a.Status,
      (SELECT COUNT(*) FROM dbo.Registrations r WHERE r.ActivityId=a.ActivityId AND r.Status='CONFIRMED') AS Confirmed,
      (SELECT COUNT(*) FROM dbo.Registrations r WHERE r.ActivityId=a.ActivityId AND r.Status='WAITLIST') AS Waitlist,
      (SELECT COUNT(*) FROM dbo.Registrations r WHERE r.ActivityId=a.ActivityId AND r.Status='CANCELLED') AS Cancelled
      FROM dbo.Activities a JOIN dbo.Cruises c ON c.CruiseId=a.CruiseId LEFT JOIN dbo.Zones z ON z.ZoneId=a.ZoneId WHERE a.Kind='ONBOARD' ORDER BY a.StartsAt,a.ActivityId FOR JSON PATH)) AS activities,
     JSON_QUERY((SELECT CancelHours,RefundPercent FROM dbo.Policy WHERE PolicyId=1 FOR JSON PATH)) AS policy
    FOR JSON PATH,WITHOUT_ARRAY_WRAPPER`);
    for(const key of ['cruises','zones','activities','policy'])if(!Array.isArray(data[key]))data[key]=[];return send(200,data);
   }
   if(req.method==='GET'&&url.pathname==='/api/shore/data'){
    requireRoles(u,'SHORE');const data=await jsonQuery(`SELECT
     JSON_QUERY((SELECT CruiseId,ShipId,Name,StartDate,EndDate,Status FROM dbo.Cruises ORDER BY StartDate FOR JSON PATH)) AS cruises,
     JSON_QUERY((SELECT s.StopId,s.CruiseId,s.PortId,p.Name AS Port,s.Arrival,s.Departure FROM dbo.Stops s JOIN dbo.Ports p ON p.PortId=s.PortId ORDER BY s.Arrival FOR JSON PATH)) AS stops,
     JSON_QUERY((SELECT ProviderId,Name,ContactName,Phone,Email,Active FROM dbo.Providers ORDER BY Name FOR JSON PATH)) AS providers,
     JSON_QUERY((SELECT VehicleId,ProviderId,Name,PlateNumber,Capacity,Active FROM dbo.ShoreVehicles ORDER BY Name FOR JSON PATH)) AS vehicles,
     JSON_QUERY((SELECT GuideId,ProviderId,Name,Phone,Active FROM dbo.ShoreGuides ORDER BY Name FOR JSON PATH)) AS guides,
     JSON_QUERY((SELECT a.ActivityId,a.CruiseId,c.Name AS Cruise,a.StopId,p.Name AS Port,a.ProviderId,v.Name AS Provider,a.Name,a.StartsAt AS GatherAt,a.ReturnAt,a.Capacity,a.Fee,a.Status,(SELECT COUNT(*) FROM dbo.Registrations r WHERE r.ActivityId=a.ActivityId AND r.Status='CONFIRMED') AS Confirmed FROM dbo.Activities a JOIN dbo.Cruises c ON c.CruiseId=a.CruiseId JOIN dbo.Stops st ON st.StopId=a.StopId JOIN dbo.Ports p ON p.PortId=st.PortId JOIN dbo.Providers v ON v.ProviderId=a.ProviderId WHERE a.Kind='SHORE' ORDER BY a.StartsAt FOR JSON PATH)) AS activities,
     JSON_QUERY((SELECT g.GroupId,g.ActivityId,g.Name,g.VehicleId,g.GuideId,g.Capacity,g.Active,v.Name AS Vehicle,v.PlateNumber,d.Name AS Guide,(SELECT COUNT(*) FROM dbo.ExcursionGroupMembers m WHERE m.GroupId=g.GroupId) AS Assigned FROM dbo.ExcursionGroups g LEFT JOIN dbo.ShoreVehicles v ON v.VehicleId=g.VehicleId LEFT JOIN dbo.ShoreGuides d ON d.GuideId=g.GuideId ORDER BY g.Name FOR JSON PATH)) AS groups,
     JSON_QUERY((SELECT r.RegistrationId,r.ActivityId,r.BookingId,b.CruiseId,usr.Name AS Passenger,cb.Number AS Cabin,r.Status,m.GroupId FROM dbo.Registrations r JOIN dbo.Activities a ON a.ActivityId=r.ActivityId JOIN dbo.Bookings b ON b.BookingId=r.BookingId JOIN dbo.Passengers ps ON ps.PassengerId=b.PassengerId JOIN dbo.Users usr ON usr.UserId=ps.UserId JOIN dbo.Cabins cb ON cb.CabinId=b.CabinId LEFT JOIN dbo.ExcursionGroupMembers m ON m.RegistrationId=r.RegistrationId WHERE a.Kind='SHORE' AND r.Status='CONFIRMED' ORDER BY usr.Name FOR JSON PATH)) AS registrations
     FOR JSON PATH,WITHOUT_ARRAY_WRAPPER`);for(const k of ['cruises','stops','providers','vehicles','guides','activities','groups','registrations'])if(!Array.isArray(data[k]))data[k]=[];return send(200,data);
   }   if(url.pathname==='/api/admin/data'){
    requireRoles(u,'ADMIN');return send(200,await jsonQuery(`SELECT
     JSON_QUERY((SELECT u.UserId,u.Name,u.Email,u.Active,JSON_QUERY((SELECT r.Code FROM UserRoles ur JOIN Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=u.UserId FOR JSON PATH)) AS roles FROM Users u ORDER BY u.UserId FOR JSON PATH)) AS users,
     JSON_QUERY((SELECT RoleId,Code,Name FROM Roles ORDER BY RoleId FOR JSON PATH)) AS roles,
     JSON_QUERY((SELECT CruiseId,ShipId,Name,StartDate,EndDate,Status FROM Cruises ORDER BY CruiseId FOR JSON PATH)) AS cruises,
     JSON_QUERY((SELECT ShipId,Name,Capacity FROM Ships ORDER BY ShipId FOR JSON PATH)) AS ships,
     JSON_QUERY((SELECT ZoneId,ShipId,Name FROM Zones ORDER BY ZoneId FOR JSON PATH)) AS zones,
     JSON_QUERY((SELECT CabinId,ShipId,Number FROM Cabins ORDER BY CabinId FOR JSON PATH)) AS cabins,
     JSON_QUERY((SELECT PortId,Name FROM Ports ORDER BY PortId FOR JSON PATH)) AS ports,
     JSON_QUERY((SELECT ProviderId,Name FROM Providers ORDER BY ProviderId FOR JSON PATH)) AS providers,
     JSON_QUERY((SELECT ServiceId,Name,Price FROM Services ORDER BY ServiceId FOR JSON PATH)) AS services,
     JSON_QUERY((SELECT PackageId,Name FROM Packages ORDER BY PackageId FOR JSON PATH)) AS packages,
     JSON_QUERY((SELECT PackageId,ServiceId FROM PackageServices ORDER BY PackageId,ServiceId FOR JSON PATH)) AS packageServices,
     JSON_QUERY((SELECT DeviceId,Name,Kind FROM Devices ORDER BY DeviceId FOR JSON PATH)) AS devices,
     JSON_QUERY((SELECT p.PassengerId,u.UserId,u.Name,u.Active FROM Passengers p JOIN Users u ON u.UserId=p.UserId ORDER BY p.PassengerId FOR JSON PATH)) AS passengers,
     JSON_QUERY((SELECT b.BookingId,b.CruiseId,p.UserId,b.CabinId,b.PackageId,u.Name,c.Name AS Cruise,cb.Number AS Cabin,pk.Name AS Package FROM Bookings b JOIN Passengers p ON p.PassengerId=b.PassengerId JOIN Users u ON u.UserId=p.UserId JOIN Cruises c ON c.CruiseId=b.CruiseId JOIN Cabins cb ON cb.CabinId=b.CabinId JOIN Packages pk ON pk.PackageId=b.PackageId ORDER BY b.BookingId FOR JSON PATH)) AS bookings,
     JSON_QUERY((SELECT IdentifierId,BookingId,Code,Kind,Active FROM Identifiers ORDER BY IdentifierId FOR JSON PATH)) AS identifiers,
     JSON_QUERY((SELECT PolicyId,CancelHours,RefundPercent FROM Policy WHERE PolicyId=1 FOR JSON PATH)) AS policy
     FOR JSON PATH,WITHOUT_ARRAY_WRAPPER`));
   }
   if(url.pathname==='/api/admin/users'){requireRoles(u,'ADMIN');return send(200,await jsonQuery('SELECT u.UserId,u.Name,u.Email,u.Active,JSON_QUERY((SELECT r.Code FROM UserRoles ur JOIN Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=u.UserId FOR JSON PATH)) AS roles FROM Users u FOR JSON PATH'));}
   if(url.pathname.startsWith('/api/departments/')){const role=url.pathname.slice('/api/departments/'.length);if(!Object.hasOwn(roles,role))fail(404,'Bộ phận không tồn tại.');requireRoles(u,role);return send(200,{role,name:roles[role],message:'Quyền truy cập đã được kiểm tra tại backend.'});}
   if(/^\/api\/bookings\/[^/]+$/.test(url.pathname)){requireRoles(u,'PASSENGER','FINANCE');const rows=await jsonQuery(bookingQuery(u,url.pathname.split('/').pop())+' FOR JSON PATH');if(!rows.length)fail(403,'Không có quyền xem đặt chỗ này hoặc đặt chỗ không tồn tại.');return send(200,rows[0]);}
   fail(404,'API chưa được triển khai trong mốc hiện tại.');
  }
  if(req.method!=='GET')fail(405,'Method không hỗ trợ.');
  const file=path.resolve(root,'.'+(url.pathname==='/'?'/index.html':decodeURIComponent(url.pathname)));
  if(!file.startsWith(root))fail(403,'Không được phép truy cập.');
  const data=await readFile(file);res.writeHead(200,{'Content-Type':({'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.json':'application/json; charset=utf-8','.webmanifest':'application/manifest+json; charset=utf-8'})[path.extname(file)]||'application/octet-stream','Cache-Control':'no-cache','X-Content-Type-Options':'nosniff'});res.end(data);
 }catch(e){const status=e.status||(e.code==='ENOENT'?404:503);send(status,{error:status===503?'Chưa kết nối được database. Kiểm tra SQL Server và chạy npm run setup.':e.message});}
});
await query('SELECT TOP(1) PasswordHash,Active FROM Users;');
server.listen(port,'127.0.0.1',()=>console.log(`Aurora Cruise: http://localhost:${port}`));
setInterval(()=>{for(const [id,s] of sessions)if(s.expires<=Date.now())sessions.delete(id);for(const [key,t] of attempts)if(Date.now()-t.time>=60000)attempts.delete(key);},60000).unref();

