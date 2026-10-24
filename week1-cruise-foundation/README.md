# Aurora Cruise · mốc nền tảng và tổng quan

Mốc hiện tại: đăng nhập/đăng xuất, mật khẩu băm scrypt, phiên 8 giờ, 8 vai trò, Tổng quan theo booking/chuyến, quản lý chuyến/lịch cảng, đăng ký, hủy, quản trị hệ thống và toàn vẹn dữ liệu. SQL kiểm tra quyền, quan hệ chéo bảng, bảo vệ tài khoản đã chốt, đối chiếu hóa đơn/thanh toán và ghi audit có actor, chi tiết, mã liên kết. POS ngoại tuyến có giao diện/cache, hàng đợi localStorage theo tài khoản, UUID cố định, đồng bộ idempotent và biên nhận SQL. Hành khách xem chi phí tạm, giao dịch, khoản hoàn, hóa đơn và gửi tranh chấp trong phạm vi booking của mình; sau chuyến đi, có thể đánh giá các hoạt động đã hoàn thành và chuyến đi. Điểm trung bình và số lượt phản hồi được tổng hợp cho đội vận hành. Không phụ thuộc thư mục `cruise-sql` khi chạy.

## Chạy

Cần Node.js từ 18, SQL Server và sqlcmd trong PATH. Mở terminal ở thư mục này:

```powershell
npm run setup
npm start
```

Mở http://localhost:3001 hoặc nhấp đúp CHAY-WEB.cmd. Database riêng CruiseWeek1; không dùng CruiseCoursework của bản đầy đủ. Nếu dùng SQLEXPRESS, đặt $env:SQL_SERVER = '.\SQLEXPRESS' trước setup/start. Có thể đổi SQL_DATABASE và PORT; giữ cùng cấu hình khi setup/server/test. Không có dependency bên ngoài hoặc bước build.

## Tài khoản

Mật khẩu demo: Aurora123! Mỗi tài khoản được lưu hash với salt riêng.

Trong dữ liệu mẫu, gói Premium bao gồm hoạt động Đêm nhạc trên biển; gói Tiêu chuẩn giữ mức phí niêm yết. Mức giá được chốt khi tạo đăng ký. Khi một đăng ký đã xác nhận bị hủy hoặc sức chứa hoạt động được tăng, booking chờ đầu tiên được tự động xác nhận và phí mới được ghi vào tài khoản.

| Vai trò | Email |
|---|---|
| Hành khách | guest1@demo.local đến guest20@demo.local |
| Điều phối | itinerary@demo.local |
| Hoạt động | checkin@demo.local |
| Tour bờ | shore@demo.local |
| POS | pos@demo.local |
| Tài chính | finance@demo.local |
| Vận hành | operations@demo.local |
| Quản trị | admin@demo.local |

## Mốc đã triển khai và phần tiếp theo

Đã hoàn tất lát cắt Tổng quan, đăng nhập/phân quyền, lịch trình, quản lý hoạt động trên tàu, đăng ký/danh sách chờ, hủy/hoàn phí, quản trị hệ thống và chi phí hành khách. Hành khách xem tài khoản theo booking, số dư tạm tính, giao dịch, hoàn phí, hóa đơn/thanh toán và gửi tranh chấp; API và stored procedure cùng xác minh quyền sở hữu. Tranh chấp đang mở chặn chốt tài khoản. Toàn vẹn dữ liệu chặn cabin hoặc hoạt động sai chuyến, giao dịch sai account, chứng từ sai tổng; chốt account tạo Invoice, Payment và trạng thái SETTLED trong cùng transaction, đồng thời chặn sửa tài chính sau chốt. POS đồng bộ từng giao dịch lên SQL Server qua API, xác nhận giá tại database, dùng UUID duy nhất để retry an toàn và lưu biên nhận đồng bộ trong cùng transaction.

## Tour bờ

Vai trò Quản lý tour bờ tạo, sửa và tìm tour; quản lý thông tin nhà cung cấp, xe, hướng dẫn viên; đặt giờ tập trung và giờ về tàu trong thời gian dừng cảng; tạo nhóm theo xe/hướng dẫn viên và gán khách đã xác nhận vào nhóm với kiểm tra sức chứa, quyền truy cập và audit.

## Hoạt động trên tàu

Vai trò Quản lý hoạt động có thể tạo, sửa, tìm kiếm và lọc hoạt động theo chuyến hoặc trạng thái; cấu hình thời gian, khu vực, sức chứa và phí. Hủy hoạt động chưa bắt đầu sẽ hủy các đăng ký còn hiệu lực, hoàn theo chính sách hiện hành, ghi lý do và audit. Không thể giảm sức chứa thấp hơn số lượt đã xác nhận hoặc hủy sau khi đã check-in.

## SQL và kiểm tra

Setup chạy 01-schema → 03-seed → 04-auth → 05-itinerary → 06-registration → 07-cancellation → 08-admin → 09-integrity → 10-pos-sync → 11-pos-receipts → 12-passenger-finance → 13-onboard-activities → 14-shore-excursions → 15-feedback trên DB mới. Với DB CruiseWeek1 hiện có, setup giữ dữ liệu rồi chạy các migration để cập nhật nghiệp vụ. Seed không gọi usp_Register. Nếu dùng SSMS bật SQLCMD Mode. Sau khi chạy SQL bằng tay, chạy setup để cấp hash demo và cập nhật migration.

Chạy `npm run check`, `npm run test:auth`, `npm run test:integrity`, `npm run test:pos` và `npm run test:finance`. Test nghiệp vụ tự tạo database riêng rồi xóa sau khi chạy. Hướng dẫn: `docs/POS-OFFLINE.md`, `docs/PASSENGER-FINANCE.md`; chi tiết API/quyền: `docs/AUTH.md`.

## Code cần push

Push server.mjs, src, public, scripts, tests, database, docs, README.md, CHAY-WEB.cmd, package.json, package-lock.json và .gitignore. Không push .tmp, node_modules, .env hoặc log.

Các API chính: đăng nhập/đăng xuất, lịch trình, đăng ký/hủy và nhóm `/api/admin/*` cho dữ liệu quản trị, người dùng, danh mục, booking, gói dịch vụ, chính sách và mã định danh. Backend và SQL đều kiểm tra quyền; dữ liệu hành khách tiếp tục bị giới hạn theo chủ booking. Cookie HttpOnly và SameSite=Strict; restart server cần đăng nhập lại. Bản học phần chạy localhost.

